import Foundation

/// D24: where notes and Ask answers come from. One prompt in, the model's text out. Providers hold no meeting data;
/// the prompt carries everything, and the transcript inside it is untrusted (tools stay off wherever a CLI allows).
protocol NotesProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Cheap and side-effect free: is it installed / configured? Never prompts, never spends tokens.
    func isAvailable() async -> Bool
    /// The reply text, trimmed. Throws `NotesProviderError`; honours Task cancellation (a CLI is terminated).
    func complete(prompt: String) async throws -> String
    /// One line for Settings: why it is or isn't usable. Optional; the default is empty.
    func availabilityDetail() async -> String
}

extension NotesProvider {
    func availabilityDetail() async -> String { "" }
}

enum NotesProviderError: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case notConfigured(String)
    case couldNotRun(String, String)
    case timedOut(String, Int)
    case failed(String, Int, String)
    case empty(String)
    case http(String, Int, String)
    case unreadable(String)
    case cancelled

    /// The wording matches notes.run_claude's reason strings, because the UI shows them verbatim ("Summary failed: …").
    var errorDescription: String? {
        switch self {
        case .notInstalled(let n): return "\(n) is not installed"
        case .notConfigured(let m): return m
        case .couldNotRun(let n, let why): return "could not run \(n): \(why)"
        case .timedOut(let n, let s): return "\(n) timed out after \(s) s"
        case .failed(let n, let code, let detail): return "\(n) exited \(code): \(detail)"
        case .empty(let n): return "\(n) returned an empty reply"
        case .http(let n, let code, let detail): return "\(n) returned HTTP \(code): \(detail)"
        case .unreadable(let n): return "\(n) sent a reply that could not be read"
        case .cancelled: return "cancelled"
        }
    }
}

// MARK: - Finding CLIs

enum CLILocator {
    /// Droppy's own process has a minimal PATH, so the usual install places are searched as well (D24).
    static func searchDirs(home: String = NSHomeDirectory(), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> [String] {
        var dirs = path.split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "\(home)/.grok/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// First executable file named `name`. `override` (an absolute path, e.g. from EAVESDROPPY_CLAUDE_BIN) wins when it runs.
    static func find(_ name: String, override: String? = nil, dirs: [String] = searchDirs()) -> String? {
        let fm = FileManager.default
        if let o = override, !o.isEmpty, fm.isExecutableFile(atPath: o) { return o }
        return dirs.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Running a CLI

/// Runs one child process to completion with a timeout. The prompt goes in as a file on stdin, and stdout/stderr go to
/// files, so there are no pipes to fill, no SIGPIPE to ignore and no reader threads. Cancellation terminates the child.
enum ProcessRunner {
    struct Output { let status: Int32; let stdout: String; let stderr: String; var extra: String? = nil }

    /// `arguments` receives the throwaway directory (also the child's cwd) so a CLI can be handed an output file inside it.
    /// `readExtra` runs before the directory is removed (Codex's `-o` file lives there).
    static func run(name: String, executable: String, arguments: (URL) -> [String], stdin: String?, environment: [String: String],
                    timeout: TimeInterval, readExtra: ((URL) -> String?)? = nil) async throws -> Output {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("eavesdroppy-run-\(UUID().uuidString)")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw NotesProviderError.couldNotRun(name, error.localizedDescription) }
        defer { try? fm.removeItem(at: dir) }

        let inURL = dir.appendingPathComponent(".stdin"), outURL = dir.appendingPathComponent(".stdout"), errURL = dir.appendingPathComponent(".stderr")
        guard fm.createFile(atPath: inURL.path, contents: Data((stdin ?? "").utf8)), fm.createFile(atPath: outURL.path, contents: nil),
              fm.createFile(atPath: errURL.path, contents: nil),
              let inH = try? FileHandle(forReadingFrom: inURL), let outH = try? FileHandle(forWritingTo: outURL),
              let errH = try? FileHandle(forWritingTo: errURL)
        else { throw NotesProviderError.couldNotRun(name, "could not create scratch files") }
        defer { try? inH.close(); try? outH.close(); try? errH.close() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments(dir)
        p.environment = environment
        p.currentDirectoryURL = dir  // no tools anywhere near the user's files: transcripts and notes are untrusted input
        p.standardInput = inH; p.standardOutput = outH; p.standardError = errH

        let state = RunState()
        let exited: AsyncStream<Void> = AsyncStream { c in p.terminationHandler = { _ in c.yield(); c.finish() } }
        try Task.checkCancellation()
        do { try p.run() } catch { throw NotesProviderError.couldNotRun(name, error.localizedDescription) }

        await withTaskCancellationHandler {
            let killer = Task {  // timeout: SIGTERM, then SIGKILL if it ignores that
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                state.markTimedOut(); p.terminate()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            for await _ in exited { break }
            killer.cancel()
        } onCancel: {
            state.markCancelled(); if p.isRunning { p.terminate() }
        }

        if state.cancelled || Task.isCancelled { throw NotesProviderError.cancelled }
        if state.timedOut { throw NotesProviderError.timedOut(name, Int(timeout)) }
        func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }
        return Output(status: p.terminationStatus, stdout: read(outURL), stderr: read(errURL), extra: readExtra?(dir))
    }

    /// What a failed run says, trimmed like Python's `(stderr or out)[:300]`.
    static func failureDetail(_ o: Output) -> String {
        let s = o.stderr.pyStripped.isEmpty ? o.stdout.pyStripped : o.stderr.pyStripped
        return String(s.prefix(300))
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _timedOut = false, _cancelled = false
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return _timedOut }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func markTimedOut() { lock.lock(); _timedOut = true; lock.unlock() }
        func markCancelled() { lock.lock(); _cancelled = true; lock.unlock() }
    }
}
