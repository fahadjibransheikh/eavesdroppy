import Foundation

// The Swift side of the pipeline CLI contract (research/build-plan.md, "Pipeline CLI contract"): runs one subcommand
// off the main thread in its own process group, appends --container, parses the last stdout JSON line on exit 0 or the
// last stderr `ERROR:` line otherwise. Foundation only, so a fake script can drive it in tests.

struct PipelineError: Error, CustomStringConvertible, Equatable { let description: String }

/// One running command (a Pipeline.run). `cancel()` cancels its in-process Task or, in the personal build's Python fallback, SIGTERMs its process group.
final class PipelineCall: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var _cancelled = false, _timedOut = false
    private var hook: (() -> Void)?   // cancels the in-process Task of a native command

    var cancelled: Bool { lock.withLock { _cancelled } }
    var timedOut: Bool { lock.withLock { _timedOut } }

    func cancel() { lock.lock(); _cancelled = true; let p = pid, h = hook; lock.unlock(); if p > 0 { killpg(p, SIGTERM) }; h?() }
    func timeout() { lock.lock(); _timedOut = true; let p = pid, h = hook; lock.unlock(); if p > 0 { killpg(p, SIGTERM) }; h?() }
    /// Escalation when SIGTERM was ignored. `pid` is zeroed on detach, so a recycled pid is never signalled.
    func kill() { lock.lock(); let p = pid; lock.unlock(); if p > 0 { killpg(p, SIGKILL) } }
    func attach(_ p: pid_t) { lock.lock(); pid = p; let c = _cancelled; lock.unlock(); if c { killpg(p, SIGTERM) } }
    func detach() { lock.lock(); pid = 0; hook = nil; lock.unlock() }
    /// A native command registers how to stop its Task; a cancel that came first stops it at once.
    func attach(cancel: @escaping () -> Void) { lock.lock(); hook = cancel; let c = _cancelled; lock.unlock(); if c { cancel() } }
}

enum Pipeline {
    #if EAVESDROPPY_PERSONAL
    /// The Python fallback ("Use Python pipeline", off by default): everything goes through process_meeting.py as before.
    /// The Store build has no Python path. Interpreter and script: tests point these at a fake.
    nonisolated(unsafe) static var usePython = false
    nonisolated(unsafe) static var executable = projectDir + "/.venv/bin/python"
    nonisolated(unsafe) static var script = projectDir + "/process_meeting.py"
    #endif

    /// Short library writes (rename, check off, delete...) run in order on their own queue, so an edit never waits
    /// behind a 20-minute meeting job (the `pipeline` queue). SQLite locking is the Python side's job (WAL + busy_timeout).
    static let edits = DispatchQueue(label: "eavesdroppy.edits", qos: .userInitiated)
    /// Everything slow (ask, regenerate, imports, Linear): concurrent, so Ask never blocks a rename.
    static let slow = DispatchQueue(label: "eavesdroppy.slow", qos: .userInitiated, attributes: .concurrent)

    /// ask/regenerate call Claude (600 s); import-drive can touch hundreds of meetings (also 600 s); the rest 120 s.
    static func timeout(for command: String?) -> TimeInterval { ["ask", "regenerate", "import-drive"].contains(command ?? "") ? 600 : 120 }

    /// `--container X` goes before a bare `--` (after it argparse reads everything as a positional), else at the end.
    static func withContainer(_ args: [String], _ container: String) -> [String] { withOption(args, "--container", container) }

    static func withOption(_ args: [String], _ name: String, _ value: String) -> [String] {
        guard let i = args.firstIndex(of: "--") else { return args + [name, value] }
        return Array(args[..<i]) + [name, value] + Array(args[i...])
    }

    /// Blocking: call off the main thread. `args` is the subcommand and its arguments, without --container and --out-root.
    /// `outRoot` is passed explicitly to every command (default: the Output folder setting); `stdin` is set-user-notes' text.
    static func run(_ args: [String], env: [String: String] = [:], timeout: TimeInterval? = nil, call: PipelineCall = PipelineCall(),
                    container: URL = containerDir, epoch ep: Int = currentEpoch(), outRoot: URL? = nil, stdin: String? = nil) -> Result<[String: Any], PipelineError> {
        let out = outRoot ?? URL(fileURLWithPath: outputRoot())
        #if EAVESDROPPY_PERSONAL
        if usePython { return runPython(args, env: env, timeout: timeout, call: call, container: container, epoch: ep, outRoot: out, stdin: stdin) }
        #endif
        return runNative(args, env: env, timeout: timeout, call: call, container: container, epoch: ep, outRoot: out, stdin: stdin)
    }

    /// In-process (D22): the command runs on a detached Task; this thread (already off main) waits for it.
    static func runNative(_ args: [String], env: [String: String], timeout: TimeInterval?, call: PipelineCall, container: URL, epoch ep: Int,
                          outRoot: URL, stdin: String?, context: NativeCommands.Context? = nil) -> Result<[String: Any], PipelineError> {
        let name = args.first ?? "pipeline"
        guard NativeCommands.handles(name) else { return .failure(PipelineError(description: "bad arguments: unknown command \(name)")) }
        guard ep == currentEpoch() else { return .failure(PipelineError(description: "cancelled")) }
        let limit = timeout ?? Self.timeout(for: args.first)
        let heavy = ["process", "enroll", "import-drive"].contains(name)
        var ctx = context ?? NativeCommands.Context(container: container, engines: NativeSeams.engines, resolution: NativeSeams.resolution)
        ctx.container = container; ctx.outRoot = outRoot; ctx.stdin = stdin; ctx.env = env
        let box = LockedBox<Swift.Result<Data, Error>?>(nil), timedOut = LockedBox(false), done = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: heavy ? .utility : .userInitiated) { [ctx] in
            do { box.value = .success(try await NativeCommands.run(args, ctx)) } catch { box.value = .failure(error) }
            done.signal()
        }
        call.attach(cancel: { task.cancel() })
        let job = registerNativeJob { task.cancel() }
        let timer = DispatchWorkItem { timedOut.value = true; task.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timer)
        done.wait()
        timer.cancel(); unregisterNativeJob(job); call.detach()
        switch box.value {
        case .success(let data)?:
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(PipelineError(description: "\(name): no JSON result")) }
            return .success(obj)
        case .failure(let e)?:
            if e is CancellationError {
                if timedOut.value { return .failure(PipelineError(description: "\(name) timed out after \(Int(limit)) s")) }
                return .failure(PipelineError(description: "cancelled"))
            }
            return .failure(PipelineError(description: (e as? StoreError)?.description ?? (e as? LocalizedError)?.errorDescription ?? "\(e)"))
        case nil: return .failure(PipelineError(description: "\(name) ended without a result"))
        }
    }

    #if EAVESDROPPY_PERSONAL
    static func runPython(_ args: [String], env: [String: String], timeout: TimeInterval?, call: PipelineCall, container: URL, epoch ep: Int,
                          outRoot: URL, stdin: String?) -> Result<[String: Any], PipelineError> {
        let limit = timeout ?? Self.timeout(for: args.first)
        let errPath = NSTemporaryDirectory() + "eavesdroppy-cmd-\(UUID().uuidString).err"
        var inPath = "/dev/null"
        if let stdin {  // set-user-notes reads its text from stdin
            inPath = NSTemporaryDirectory() + "eavesdroppy-cmd-\(UUID().uuidString).in"
            do { try Data(stdin.utf8).write(to: URL(fileURLWithPath: inPath)) } catch { return .failure(PipelineError(description: "\(error)")) }
        }
        defer { try? FileManager.default.removeItem(atPath: errPath); if stdin != nil { try? FileManager.default.removeItem(atPath: inPath) } }
        let pid: pid_t, out: FileHandle
        do {
            let full = withOption(withContainer(args, container.path), "--out-root", outRoot.path)
            (pid, out) = try launch(executable, [script] + full, cwd: projectDir, env: pipelineEnv(env), stderrPath: errPath, stdinPath: inPath, epoch: ep)
        } catch { return .failure(PipelineError(description: "\(error)")) }
        call.attach(pid)

        let collected = Collected(), readDone = DispatchGroup()
        readDone.enter()
        DispatchQueue.global(qos: .utility).async {
            while let d = try? out.read(upToCount: 65536), !d.isEmpty { collected.append(d) }
            try? out.close(); readDone.leave()
        }
        let timer = DispatchWorkItem {
            call.timeout()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { call.kill() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: timer)
        let exit = reap(pid)
        timer.cancel(); call.detach()
        _ = readDone.wait(timeout: .now() + 2)

        let name = args.first ?? "pipeline"
        let stderr = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
        guard let exit else { return .failure(PipelineError(description: "waitpid failed")) }
        guard exit.code == 0 else {
            if call.cancelled { return .failure(PipelineError(description: "cancelled")) }
            if call.timedOut { return .failure(PipelineError(description: "\(name) timed out after \(Int(limit)) s")) }
            if exit.code == nil { return .failure(PipelineError(description: "\(name) killed by signal \(exit.signal)")) }
            return .failure(PipelineError(description: errorText(fromStderr: stderr) ?? "\(name) failed (exit \(exit.code ?? -1))"))
        }
        let last = collected.text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any] else {
            return .failure(PipelineError(description: "\(name): no JSON result line (got \(last.isEmpty ? "nothing" : String(last.prefix(80))))"))
        }
        return .success(obj)
    }

    #endif

    /// Runs on `serial ? edits : slow`, delivers on the main queue. Dropped silently if the droplet deactivated meanwhile.
    static func submit(_ args: [String], serial: Bool = false, env: [String: String] = [:], stdin: String? = nil, call: PipelineCall = PipelineCall(),
                       done: @escaping (Result<[String: Any], PipelineError>) -> Void) {
        let ep = currentEpoch(), container = containerDir
        (serial ? edits : slow).async {
            guard currentEpoch() == ep else { return }
            let r = run(args, env: env, call: call, container: container, epoch: ep, stdin: stdin)
            DispatchQueue.main.async { if currentEpoch() == ep { done(r) } }
        }
    }
}
