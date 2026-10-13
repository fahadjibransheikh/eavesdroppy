import Foundation

let projectDir = ("~/code/eavesdroppy" as NSString).expandingTildeInPath
/// Set in activate(host:) to <containerDirectory>/sessions.
nonisolated(unsafe) var sessionsDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eavesdroppy-sessions")
/// Set in activate(host:) to the host's container directory: library.db lives here, and every pipeline command gets it as --container.
nonisolated(unsafe) var containerDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("eavesdroppy-container")

// MARK: log

/// Set by the droplet to forward to host.log. Callable from any thread.
nonisolated(unsafe) var logSink: (String) -> Void = { print($0) }

func log(_ msg: String) { logSink(msg) }

private let limitLock = NSLock()
nonisolated(unsafe) private var lastLogged: [String: Date] = [:]
/// For per-buffer callbacks: logs `msg` at most once per `every` seconds per key.
func logLimited(_ key: String, _ msg: String, every: TimeInterval = 5) {
    limitLock.lock()
    let now = Date()
    let ok = now.timeIntervalSince(lastLogged[key] ?? .distantPast) >= every
    if ok { lastLogged[key] = now }
    limitLock.unlock()
    if ok { log(msg) }
}

extension ISO8601DateFormatter {
    /// "2026-10-07T14:30:00-07:00" — local UTC offset, as the pipeline requires.
    static let local: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]; return f
    }()
}

// MARK: sessions

private let sessionFmt: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss-SSS"; return f
}()

private let nameLock = NSLock()
nonisolated(unsafe) private var nameCounter = 0

/// A new, unique session dir path (not created): timestamp to the millisecond plus a process-wide counter,
/// so a batch of files dropped in the same millisecond still gets distinct names.
func newSessionDir(_ date: Date = Date()) -> URL {
    nameLock.lock(); nameCounter += 1; let n = nameCounter; nameLock.unlock()
    return sessionsDir.appendingPathComponent(sessionFmt.string(from: date) + String(format: "-%04x", n & 0xffff))
}

/// True for a dir the pipeline can process: a recording (mic.wav) or an import (import.<ext>).
func hasAudio(_ dir: URL) -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: dir.appendingPathComponent("mic.wav").path) { return true }
    return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasPrefix("import.") }
}

// MARK: meta.json

private let extrasLock = NSLock()
nonisolated(unsafe) private var metaExtras: [String: Any] = [:]

/// The settings the pipeline reads from meta.json (echo_removal, template, retention_days), refreshed by the droplet
/// whenever a preference changes. writeMeta runs on background queues, so this is a locked snapshot, not the prefs.
func setMetaExtras(_ e: [String: Any]) { extrasLock.lock(); metaExtras = e; extrasLock.unlock() }

/// Atomic, so a crash mid-write never leaves a truncated meta.json. `offsets` is nil until a recording stops.
/// `extra` (typed-notes keys at stop) wins over the settings snapshot, which wins over nothing.
func writeMeta(dir: URL, title: String, start: Date, attendees: [String], source: String, offsets: [String: Double]? = nil,
               extra: [String: Any] = [:]) throws {
    extrasLock.lock(); var meta = metaExtras; extrasLock.unlock()
    meta.merge(["title": title, "start": ISO8601DateFormatter.local.string(from: start),
                "attendees": attendees, "source": source]) { _, new in new }
    if let offsets { meta["track_offsets"] = offsets }
    meta.merge(extra) { _, new in new }
    // data(withJSONObject:) raises an uncatchable NSException on NaN/inf or a non-JSON value; fail with a Swift error instead.
    guard JSONSerialization.isValidJSONObject(meta) else { throw SpawnError(description: "meta.json has a value JSON can't hold") }
    try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
}

/// Typed notes (D9). Atomic, so a crash mid-write leaves the previous text, never half a file. Empty text removes the file.
func writeNotes(_ text: String, in dir: URL) {
    let url = dir.appendingPathComponent("notes.txt")
    if text.isEmpty { try? FileManager.default.removeItem(at: url); return }
    do { try Data(text.utf8).write(to: url, options: .atomic) } catch { log("ERROR writing notes.txt: \(error)") }
}

func metaTitle(_ dir: URL) -> String? {
    guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return j["title"] as? String
}

/// The pipeline's last "ERROR: ..." stderr line from the session's process.log, without the prefix.
func lastErrorLine(_ dir: URL) -> String? {
    guard let s = try? String(contentsOf: dir.appendingPathComponent("process.log"), encoding: .utf8) else { return nil }
    return errorText(fromStderr: s)
}

func errorText(fromStderr s: String) -> String? {
    guard let last = s.split(whereSeparator: \.isNewline).last, last.hasPrefix("ERROR: ") else { return nil }
    return String(last.dropFirst(7))
}

/// Blocking (large files): call off the main thread. Copies `src` into `dir` as import.<ext> and writes meta.json.
func importFile(_ src: URL, into dir: URL, title: String) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    do {
        let ext = src.pathExtension.lowercased()
        try fm.copyItem(at: src, to: dir.appendingPathComponent("import." + (ext.isEmpty ? "audio" : ext)))
        let created = (try? src.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        try writeMeta(dir: dir, title: title, start: created, attendees: [], source: "import")
    } catch { try? fm.removeItem(at: dir); throw error }
}

// MARK: migration from the old "meetings" droplet

/// Moves every session and raw dir of the old droplet's container into `new` one at a time (a rename on the same volume),
/// so sessions already in the new container never block it. A name that is taken gets "-2", "-3"... Returns one log line
/// per move or failure. Blocking disk work: call off the main thread.
func migrateContainer(from old: URL, to new: URL) -> [String] {
    let fm = FileManager.default
    var lines: [String] = []
    for name in ["sessions", "raw"] {
        let src = old.appendingPathComponent(name), dst = new.appendingPathComponent(name)
        guard let items = try? fm.contentsOfDirectory(atPath: src.path), !items.isEmpty else { continue }
        do { try fm.createDirectory(at: dst, withIntermediateDirectories: true) }
        catch { lines.append("ERROR migrating \(src.path): cannot create \(dst.path): \(error)"); continue }
        for item in items.sorted() {
            var target = dst.appendingPathComponent(item), n = 1
            while fm.fileExists(atPath: target.path), n < 1000 { n += 1; target = dst.appendingPathComponent("\(item)-\(n)") }
            do {
                try fm.moveItem(at: src.appendingPathComponent(item), to: target)
                lines.append("migrated \(name)/\(item)" + (target.lastPathComponent == item ? "" : " as \(target.lastPathComponent) (name was taken)"))
            } catch { lines.append("ERROR migrating \(name)/\(item): \(error)") }
        }
    }
    return lines
}

/// True if the old "meetings" droplet's bundle is still installed beside this droplet's folder (its Container alone, left
/// behind after migration, does not count). `droplets` is the folder that holds one folder per droplet.
func oldMeetingsDropletInstalled(droplets: URL) -> Bool {
    let dir = droplets.appendingPathComponent("meetings")
    return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".droplet") }
}

// MARK: pipeline hand-off

enum Outcome { case ok(folder: String, warnings: [String], meetingID: Int?), failed(String) }

struct SpawnError: Error, CustomStringConvertible { let description: String }

private let procLock = NSLock()
nonisolated(unsafe) private var epoch = 0             // bumped by cancelPipeline(); jobs and callbacks from an older one are stale
nonisolated(unsafe) private var nativeJobs: [UUID: () -> Void] = [:]  // cancel hooks of the in-process jobs (Tasks) now running

func currentEpoch() -> Int { procLock.lock(); defer { procLock.unlock() }; return epoch }

/// An in-process job (a native command or a meeting) registers how to cancel it while it runs.
func registerNativeJob(_ cancel: @escaping () -> Void) -> UUID {
    let id = UUID(); procLock.lock(); nativeJobs[id] = cancel; procLock.unlock(); return id
}
func unregisterNativeJob(_ id: UUID) { procLock.lock(); nativeJobs[id] = nil; procLock.unlock() }

#if EAVESDROPPY_PERSONAL
nonisolated(unsafe) private var children = Set<pid_t>()  // live Python process-group leaders; added only after a successful spawn
#endif

/// Deactivation: invalidates every queued job, cancels every running in-process job (they stop at their next checkpoint and
/// leave the raw session to retry) and, in the personal build, SIGTERMs the Python fallback's whole process groups.
func cancelPipeline() {
    procLock.lock(); epoch += 1
    let jobs = Array(nativeJobs.values)
    #if EAVESDROPPY_PERSONAL
    let pids = children
    #endif
    procLock.unlock()
    for cancel in jobs { cancel() }
    #if EAVESDROPPY_PERSONAL
    for pid in pids { killpg(pid, SIGTERM) }
    #endif
}

#if EAVESDROPPY_PERSONAL
/// Starts `exe` as the leader of its own process group (Foundation.Process can't), stdout -> the returned
/// handle, stderr -> `stderrPath`. Fails if `ep` is stale. The pid is tracked only once the spawn succeeded.
func launch(_ exe: String, _ args: [String], cwd: String, env: [String: String], stderrPath: String, stdinPath: String = "/dev/null", epoch ep: Int) throws -> (pid: pid_t, out: FileHandle) {
    let out = Pipe()
    func closeBoth() { try? out.fileHandleForWriting.close(); try? out.fileHandleForReading.close() }
    procLock.lock(); defer { procLock.unlock() }
    guard ep == epoch else { closeBoth(); throw SpawnError(description: "cancelled") }

    var fa: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&fa); defer { posix_spawn_file_actions_destroy(&fa) }
    posix_spawn_file_actions_addopen(&fa, 0, stdinPath, O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&fa, out.fileHandleForWriting.fileDescriptor, 1)
    posix_spawn_file_actions_addopen(&fa, 2, stderrPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    posix_spawn_file_actions_addchdir_np(&fa, cwd)
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
    // New group (pgid = child pid) so killpg reaches grandchildren; CLOEXEC_DEFAULT keeps Droppy's fds out of the child.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
    posix_spawnattr_setpgroup(&attr, 0)

    let argv = ([exe] + args).map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, exe, &fa, &attr, argv, envp)
    guard rc == 0 else { closeBoth(); throw SpawnError(description: "posix_spawn \(exe): \(String(cString: strerror(rc)))") }
    children.insert(pid)
    try? out.fileHandleForWriting.close()  // the child holds the only write end now, so reads see EOF when it exits
    return (pid, out.fileHandleForReading)
}

/// Waits for `pid`, forgets it, and returns (exit code, or nil if killed by a signal; signal number).
func reap(_ pid: pid_t) -> (code: Int32?, signal: Int32)? {
    var status: Int32 = 0
    var r: pid_t
    repeat { r = waitpid(pid, &status, 0) } while r < 0 && errno == EINTR
    procLock.lock(); children.remove(pid); procLock.unlock()
    guard r == pid else { return nil }
    return status & 0x7f == 0 ? ((status >> 8) & 0xff, 0) : (nil, status & 0x7f)
}
#endif

#if EAVESDROPPY_PERSONAL
/// The Python fallback shells out to `claude -p`, which needs USER/LOGNAME — keep env minimal but complete.
func pipelineEnv(_ extra: [String: String] = [:]) -> [String: String] {
    let host = ProcessInfo.processInfo.environment
    var env = ["HOME": host["HOME"] ?? NSHomeDirectory(), "USER": host["USER"] ?? NSUserName(),
               "LOGNAME": host["LOGNAME"] ?? NSUserName(), "TMPDIR": host["TMPDIR"] ?? NSTemporaryDirectory(),
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    for k in ["EAVESDROPPY_OUT_ROOT", "EAVESDROPPY_CLAUDE_BIN"] { if let v = host[k] { env[k] = v } }  // test seams
    return env.merging(extra) { _, new in new }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

private struct PipelineResult: Decodable { let folder: String; let warnings: [String]?; let meeting_id: Int? }
#endif

// MARK: output folder (D26)

private let outLock = NSLock()
nonisolated(unsafe) private var outputSetting = ""

/// Mirrors the Output folder preference (empty = automatic). Set by Prefs on every change.
func setOutputFolderSetting(_ path: String) { outLock.lock(); outputSetting = path; outLock.unlock() }

/// Where meeting folders are written: the Output folder setting; empty means this Mac's existing Drive folder if its mount is
/// there, else ~/Documents/Eavesdroppy. Blocking (a stat on the Drive mount can stall): call off the main thread.
func outputRoot() -> String {
    outLock.lock(); let set = outputSetting; outLock.unlock()
    let t = set.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? automaticOutputRoot() : PyPath.abspath(PyPath.expanduser(t))
}

/// This Mac's existing Drive meetings folder if its mount is there, else ~/Documents/Eavesdroppy. Blocking, like outputRoot().
func automaticOutputRoot() -> String { NSHomeDirectory() + "/Documents/Eavesdroppy" }

// MARK: processing

/// A meeting takes minutes (transcribe, diarize, echo, notes), so there is no short timeout; but a job that
/// hangs (a wedged model or provider call) must not block the serial queue, and every meeting behind it, forever.
let processWatchdog: TimeInterval = 3 * 3600

func watchdogReason(_ limit: TimeInterval) -> String {
    let span = limit >= 3600 && limit.truncatingRemainder(dividingBy: 3600) == 0 ? "\(Int(limit / 3600)) hours" : "\(Int(limit)) s"
    return "Processing took over \(span) and was stopped"
}

/// The `.processing` marker holds how many starts of this session have not ended cleanly (success, or a failure with an
/// ERROR line). A crash leaves it behind; activation resumes a session whose count is below `maxAutoAttempts`, so one
/// session that crashes the process cannot crash Droppy on every launch.
let maxAutoAttempts = 2

func markerCount(_ marker: URL) -> Int? {
    guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
    return Int(((try? String(contentsOf: marker, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1   // a legacy empty marker: one start
}

/// What activation does with the sessions dir: sessions whose `.processing` marker says an earlier run was interrupted (Droppy quit,
/// or crashed) and has starts left are `resume`d; one that used them up has its marker cleared and an ERROR line added, so it
/// shows as Failed for the user to retry; the rest with audio are `failed`. Sessions in `skip` or `active` are left alone.
func classifySessions(_ dirs: [URL], skip: Set<URL> = [], active: URL? = nil, clearMarkers: Bool) -> (failed: [URL], resume: [URL]) {
    let fm = FileManager.default
    var resume: [URL] = []
    if clearMarkers {
        for d in dirs where !skip.contains(d) {
            let marker = d.appendingPathComponent(".processing")
            guard let starts = markerCount(marker) else { continue }
            if starts < maxAutoAttempts && hasAudio(d) { resume.append(d); continue }  // the marker keeps the count for the next start
            try? fm.removeItem(at: marker)
            if hasAudio(d) {
                if !fm.fileExists(atPath: d.appendingPathComponent("process.log").path) { fm.createFile(atPath: d.appendingPathComponent("process.log").path, contents: nil) }
                if let h = try? FileHandle(forWritingTo: d.appendingPathComponent("process.log")) {
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: Data("\nERROR: Processing was interrupted \(starts) times (Droppy quit or crashed); use Retry to try again\n".utf8)); try? h.close()
                }
            }
        }
    }
    let failed = dirs.filter {
        $0 != active && !skip.contains($0) && hasAudio($0) && !fm.fileExists(atPath: $0.appendingPathComponent(".processing").path)
    }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    return (failed, resume.sorted { $0.lastPathComponent < $1.lastPathComponent })
}

/// Test seams for the in-process job: the engines and the provider it uses.
enum NativeSeams {
    nonisolated(unsafe) static var engines = Processor.Engines()
    nonisolated(unsafe) static var resolution: () async -> NotesProviders.Resolution = { await NotesProviders.resolve(NativeConfig.provider) }
}

/// Blocking. Processes a session dir; on success deletes it (the m4a in the output folder and <container>/raw are the archive).
/// After `limit` (the 3 h watchdog) the job is stopped and fails with a readable reason. A cancel (deactivation) or a crash keeps
/// the session and its raw audio; the next activation resumes it.
/// What the pipeline is doing now, from the line it just logged ("stage transcription done at +12.3 s" means the next
/// stage is speaker finding). nil for any other line. The stage list is Processor.run's `mark(...)` calls, in order.
func processingStage(afterLog line: String) -> String? {
    guard line.hasPrefix("stage "), let end = line.range(of: " done at") else { return nil }
    switch line[line.index(line.startIndex, offsetBy: 6)..<end.lowerBound] {
    case "track prep": return "Cleaning up audio"
    case "echo": return "Transcribing"
    case "transcription": return "Finding speakers"
    case "diarization": return "Naming speakers"
    case "naming", "mix", "raw archive": return "Writing notes"
    default: return nil
    }
}

/// `stage` is told what the native pipeline is doing as it goes (from a background thread); the Python fallback is silent.
func processSession(_ dir: URL, epoch ep: Int, timeout limit: TimeInterval = processWatchdog, stage: @escaping (String) -> Void = { _ in }) -> Outcome {
    let fm = FileManager.default
    let marker = dir.appendingPathComponent(".processing")
    if !fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path) {  // an old session, or a crash before meta.json existed
        let hasSys = fm.fileExists(atPath: dir.appendingPathComponent("system.wav").path)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        try? writeMeta(dir: dir, title: "Recovered recording", start: f.date(from: String(dir.lastPathComponent.prefix(15))) ?? Date(),
                       attendees: [], source: "record", offsets: hasSys ? ["mic": 0, "system": 0] : ["mic": 0])
    }
    let attempt = (markerCount(marker) ?? 0) + 1
    try? Data("\(attempt)".utf8).write(to: marker)

    let logPath = dir.appendingPathComponent("process.log")
    func fail(_ why: String, logged: Bool = false) -> Outcome {
        try? fm.removeItem(at: marker)
        log("pipeline FAILED \(dir.lastPathComponent): \(why)")
        if !logged, let h = try? FileHandle(forWritingTo: logPath) {  // so the Failed row can show it after a relaunch
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data("\nERROR: \(why)\n".utf8)); try? h.close()
        }
        return .failed(why)
    }
    #if EAVESDROPPY_PERSONAL
    if Pipeline.usePython { return processSessionPython(dir, epoch: ep, limit: limit, logPath: logPath, fail: fail) }
    #endif
    return processSessionNative(dir, epoch: ep, limit: limit, attempt: attempt, marker: marker, logPath: logPath, stage: stage, fail: fail)
}

private final class NativeBox: @unchecked Sendable {
    private let lock = NSLock(); private var r: Result<Processor.Result, Error>?; private var _timedOut = false
    var result: Result<Processor.Result, Error>? { get { lock.withLock { r } } set { lock.withLock { r = newValue } } }
    var timedOut: Bool { get { lock.withLock { _timedOut } } set { lock.withLock { _timedOut = newValue } } }
}

/// The meeting job, in-process (D22): a detached Task at .utility priority, cancelled by cancelPipeline().
private func processSessionNative(_ dir: URL, epoch ep: Int, limit: TimeInterval, attempt: Int, marker: URL, logPath: URL,
                                  stage: @escaping (String) -> Void, fail: (String, Bool) -> Outcome) -> Outcome {
    let fm = FileManager.default
    fm.createFile(atPath: logPath.path, contents: nil)   // a fresh log per attempt, as the Python's stderr redirect was
    let logHandle = try? FileHandle(forWritingTo: logPath)
    let logLock = NSLock()
    func plog(_ s: String) {
        logLock.withLock { try? logHandle?.write(contentsOf: Data((s + "\n").utf8)) }
        if let st = processingStage(afterLog: s) { stage(st) }
    }
    defer { try? logHandle?.close() }
    if ep != currentEpoch() { try? Data("\(attempt - 1)".utf8).write(to: marker); return .failed("cancelled") }
    log("pipeline started \(dir.lastPathComponent) (attempt \(attempt))")
    stage("Preparing audio")
    let box = NativeBox(), done = DispatchSemaphore(value: 0)
    let outRoot = outputRoot()
    let task = Task.detached(priority: .utility) {
        do {
            var p = Processor.Params(session: dir, container: containerDir, outRoot: outRoot, userName: nil, resolution: await NativeSeams.resolution())
            p.engines = NativeSeams.engines
            p.log = plog
            box.result = .success(try await Processor.process(p))
        } catch { box.result = .failure(error) }
        done.signal()
    }
    let job = registerNativeJob { task.cancel() }
    let watchdog = DispatchWorkItem { box.timedOut = true; task.cancel() }
    DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: watchdog)
    done.wait()
    watchdog.cancel(); unregisterNativeJob(job)

    switch box.result {
    case .success(let r):
        for w in r.warnings { plog("WARNING: \(w)") }
        try? fm.removeItem(at: marker)
        try? fm.removeItem(at: dir)  // the m4a in the output folder is the archive
        log("pipeline ok -> \(r.folder) warnings=\(r.warnings)")
        return .ok(folder: r.folder, warnings: r.warnings, meetingID: r.meetingID)
    case .failure(let e) where e is CancellationError:
        if box.timedOut { return fail(watchdogReason(limit), false) }
        // Deactivated (or the job went stale): not a failure of the meeting. The session and the marker stay, so the next
        // activation resumes it; this start does not count against the crash budget.
        try? Data("\(attempt - 1)".utf8).write(to: marker)
        log("pipeline cancelled \(dir.lastPathComponent)")
        return .failed("cancelled")
    case .failure(let e):
        let why = (e as? StoreError)?.description ?? (e as? StoreCrash)?.description ?? (e as? LocalizedError)?.errorDescription ?? "\(e)"
        plog("ERROR: \(PyText.words(why).joined(separator: " ").prefix(500))")
        return fail(why, true)
    case nil: return fail("the job ended without a result", false)
    }
}

#if EAVESDROPPY_PERSONAL
/// The Python fallback ("Use Python pipeline"): process_meeting.py on a session dir; on exit 0 deletes the session dir.
/// Contract: exit 0 -> last stdout line is {"folder": ..., "warnings": [...]}; nonzero -> last stderr line "ERROR: ...".
private func processSessionPython(_ dir: URL, epoch ep: Int, limit: TimeInterval, logPath: URL, fail: (String, Bool) -> Outcome) -> Outcome {
    let fm = FileManager.default
    let env = pipelineEnv()
    let pid: pid_t, outH: FileHandle
    do {
        (pid, outH) = try launch(Pipeline.executable, [Pipeline.script, dir.path, "--container", containerDir.path, "--out-root", outputRoot()],
                                 cwd: projectDir, env: env, stderrPath: logPath.path, epoch: ep)
    } catch { return fail("could not launch: \(error)", false) }
    log("pipeline started \(dir.lastPathComponent) (python)")

    // stdout is read concurrently so a chatty child can't fill the pipe and block; stderr goes to the log file.
    let collected = Collected(), readDone = DispatchGroup()
    readDone.enter()
    DispatchQueue.global(qos: .utility).async {
        while let d = try? outH.read(upToCount: 65536), !d.isEmpty { collected.append(d) }  // read(upToCount:) throws instead of raising
        try? outH.close(); readDone.leave()
    }
    let call = PipelineCall()
    call.attach(pid)
    let watchdog = DispatchWorkItem {
        call.timeout()  // SIGTERM to the process group, then SIGKILL if it is ignored
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { call.kill() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: watchdog)
    let exit = reap(pid)
    watchdog.cancel(); call.detach()
    _ = readDone.wait(timeout: .now() + 2)  // a straggler grandchild holding the pipe must not hang us

    let stderr = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
    guard let exit else { return fail("waitpid failed", false) }
    guard exit.code == 0 else {
        if call.timedOut { return fail(watchdogReason(limit), false) }
        if exit.code == nil { return fail("killed by signal \(exit.signal)", false) }
        if let e = errorText(fromStderr: stderr) { return fail(e, true) }
        return fail("exit \(exit.code ?? -1) (see process.log)", false)
    }
    let last = collected.text.split(whereSeparator: \.isNewline).last.map(String.init)
    var folder: String?, warnings: [String] = [], meetingID: Int?
    if let last, let r = try? JSONDecoder().decode(PipelineResult.self, from: Data(last.utf8)) { folder = r.folder; warnings = r.warnings ?? []; meetingID = r.meeting_id }
    else { folder = last }  // tolerate the pre-JSON contract: a bare path
    guard let folder, fm.fileExists(atPath: folder) else { return fail("exit 0 but no meeting folder in the result line: \(last ?? "<empty>")", false) }
    if !stderr.isEmpty { log("pipeline stderr (exit 0): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
    try? fm.removeItem(at: dir.appendingPathComponent(".processing"))
    try? fm.removeItem(at: dir)  // the m4a in the output folder is the archive
    log("pipeline ok -> \(folder) warnings=\(warnings)")
    return .ok(folder: folder, warnings: warnings, meetingID: meetingID)
}
#endif
