import Foundation
import Testing
@testable import Eavesdroppy

// The crash gate (research/swift-port-plan.md, Risks): a forced crash in the middle of a job must leave the raw session to retry.
// The parent test starts a second copy of this test process (the swiftpm test helper, same arguments, another filter) that runs the
// real `processSession` with EAVESDROPPY_DEBUG_CRASH set, so Processor.crash() abort()s it. Then the parent plays the next
// activation: classifySessions (what refreshFailed does) and processSession again.

private func processed(_ s: Scratch) async throws -> Processor.Result { try await Processor.process(s.params()) }
private func db(_ s: Scratch) throws -> StoreDB { try StoreDB(path: s.container.appendingPathComponent("library.db")) }

private let childKey = "EAVESDROPPY_CRASH_GATE_CHILD"   // "<scratch root>|<stage>"

/// Child half: only does anything when the parent set the variable, so a plain `swift test` skips it.
@Suite struct CrashGateChild {
    @Test(.enabled(if: ProcessInfo.processInfo.environment[childKey] != nil)) func runsTheJobAndAborts() throws {
        let parts = ProcessInfo.processInfo.environment[childKey]!.split(separator: "|").map(String.init)
        let root = URL(fileURLWithPath: parts[0])
        containerDir = root.appendingPathComponent("container")
        sessionsDir = containerDir.appendingPathComponent("sessions")
        setOutputFolderSetting(root.appendingPathComponent("out").path)
        NativeSeams.engines = Scratch.fakeEngines(FakeTranscriber())
        NativeSeams.resolution = { .provider(FixedProvider()) }
        setenv("EAVESDROPPY_DEBUG_CRASH", parts[1], 1)
        let outcome = processSession(sessionsDir.appendingPathComponent("20261013-120000-000-0001"), epoch: currentEpoch())
        Issue.record("the job should have aborted at \(parts[1]), but returned \(outcome)")   // not reached on a DEBUG build
    }
}

/// Everything here touches process-wide state (the session/container globals, the epoch, the job registry), so it runs one test at a time.
@Suite(.serialized) struct PipelineGlobals {
    /// Runs the child with the same helper arguments but its own filter; returns how it ended.
    private func runChild(root: URL, stage: String) throws -> (signal: Int32?, status: Int32, output: String) {
        var args = Array(CommandLine.arguments.dropFirst())
        while let i = args.firstIndex(of: "--filter") { args.removeSubrange(i...(i + 1)) }
        args += ["--filter", "CrashGateChild"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging([childKey: "\(root.path)|\(stage)"]) { _, n in n }
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationReason == .uncaughtSignal ? p.terminationStatus : nil, p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(arguments: ["after-asr", "after-add-meeting", "after-rename"])
    func aCrashMidJobKeepsTheRawSessionAndTheNextActivationFinishesIt(stage: String) async throws {
        #if DEBUG
        let s = try Scratch(); defer { s.remove() }
        let r = try runChild(root: s.root, stage: stage)
        #expect(r.signal == SIGABRT, "child ended with signal \(String(describing: r.signal)), status \(r.status)\n\(r.output.suffix(2000))")

        // 1. what the crash left behind
        let fm = FileManager.default
        for f in ["mic.wav", "system.wav", "meta.json"] { #expect(fm.fileExists(atPath: s.session.appendingPathComponent(f).path), "session keeps \(f)") }
        #expect(markerCount(s.session.appendingPathComponent(".processing")) == 1, "one start that did not end cleanly")
        let rawDir = s.container.appendingPathComponent("raw/20261013-120000-000-0001")
        let db0 = try StoreDB(path: s.container.appendingPathComponent("library.db"))
        let orphans = try db0.rows("SELECT folder, pending_folder FROM meetings"); db0.close()
        switch stage {
        case "after-asr": #expect(orphans.isEmpty, "no row yet"); #expect(!fm.fileExists(atPath: rawDir.path), "raw audio is archived after the engines")
        case "after-add-meeting":
            #expect(orphans.count == 1 && orphans[0].v[0] == .null, "a row with no folder is the orphan"); #expect(fm.fileExists(atPath: rawDir.appendingPathComponent("mic.flac").path))
        default:
            #expect(orphans.count == 1 && orphans[0].v[0] == .null && orphans[0].text(1) != nil, "folder renamed into place but never recorded")
            #expect(fm.fileExists(atPath: orphans[0].text(1) ?? "/nonexistent"))
        }

        // 2. the next activation resumes it (one start used, one left)
        let c = classifySessions([s.session], clearMarkers: true)
        #expect(c.resume == [s.session]); #expect(c.failed.isEmpty)

        // 3. ... and the retry finishes: one meeting, no "(2)", the session removed, the marker gone
        containerDir = s.container; sessionsDir = s.container.appendingPathComponent("sessions")
        setOutputFolderSetting(s.out.path)
        NativeSeams.engines = Scratch.fakeEngines(FakeTranscriber()); NativeSeams.resolution = { .provider(FixedProvider()) }
        let outcome = processSession(s.session, epoch: currentEpoch())
        guard case .ok(let folder, let warnings, let id) = outcome else { Issue.record("retry failed: \(outcome)"); return }
        #expect(warnings.isEmpty, "\(warnings)"); #expect(id != nil)
        #expect(!folder.hasSuffix(")"), "the killed run's folder was reused: \(folder)")
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(try db.rows("SELECT COUNT(*) FROM meetings")[0].int(0) == 1, "the orphan was replaced, not duplicated")
        #expect(try db.rows("SELECT folder, pending_folder FROM meetings")[0].text(0) == folder)
        #expect(try fm.contentsOfDirectory(atPath: s.out.path).filter { !$0.hasPrefix(".") }.count == 1, "one meeting folder in the output")
        #expect(!fm.fileExists(atPath: s.session.path), "the session is removed once the meeting is complete")
        #expect(fm.fileExists(atPath: rawDir.appendingPathComponent("mic.flac").path), "the raw audio stays")
        #else
        Issue.record("the crash hook is compiled into DEBUG builds only")
        #endif
    }

    @Test func aSessionThatKeepsCrashingIsOnlyResumedOnce() throws {
        let s = try Scratch(); defer { s.remove() }
        let marker = s.session.appendingPathComponent(".processing")
        try Data("1".utf8).write(to: marker)
        #expect(classifySessions([s.session], clearMarkers: true).resume == [s.session], "first interrupted start: resume")
        try Data("2".utf8).write(to: marker)
        let c = classifySessions([s.session], clearMarkers: true)
        #expect(c.resume.isEmpty); #expect(c.failed == [s.session], "shown as Failed for a manual retry")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(lastErrorLine(s.session)?.hasPrefix("Processing was interrupted 2 times") == true)
        // a clean cancel (deactivation) does not count: processSession writes the previous count back
        try Data("0".utf8).write(to: marker)
        #expect(classifySessions([s.session], clearMarkers: true).resume == [s.session])
    }

    @Test func deactivatingCancelsTheJobAndKeepsTheSession() async throws {
        let s = try Scratch(); defer { s.remove() }
        containerDir = s.container; sessionsDir = s.container.appendingPathComponent("sessions")
        setOutputFolderSetting(s.out.path)
        NativeSeams.engines = Scratch.fakeEngines(SlowTranscriber()); NativeSeams.resolution = { .provider(FixedProvider()) }
        let ep = currentEpoch()
        async let outcome: Outcome = Task.detached { processSession(s.session, epoch: ep) }.value
        try await Task.sleep(nanoseconds: 600_000_000)
        cancelPipeline()
        let o = await outcome
        guard case .failed(let why) = o else { Issue.record("expected a cancel: \(o)"); return }
        #expect(why == "cancelled")
        #expect(FileManager.default.fileExists(atPath: s.session.appendingPathComponent("mic.wav").path))
        #expect(markerCount(s.session.appendingPathComponent(".processing")) == 0, "a cancel is not a crash: the budget is untouched")
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(try db.rows("SELECT COUNT(*) FROM meetings")[0].int(0) == 0)
        #expect(classifySessions([s.session], clearMarkers: true).resume == [s.session], "and the next activation resumes it")
    }

    @Test func pipelineRunRoutesToTheNativeHandlersAndFeedsStdin() async throws {
        let s = try Scratch(); defer { s.remove() }
        let r = try await processed(s)
        let call = PipelineCall()
        let ran = Pipeline.runNative(["set-user-notes", String(r.meetingID)], env: [:], timeout: nil, call: call, container: s.container, epoch: currentEpoch(),
                                     outRoot: s.out, stdin: "typed during the call")
        guard case .success(let j) = ran else { Issue.record("\(ran)"); return }
        #expect(j["ok"] as? Bool == true)
        let d = try db(s); defer { d.close() }
        #expect(try d.rows("SELECT user_notes FROM meetings")[0].text(0) == "typed during the call")
        let empty = Pipeline.runNative(["set-user-notes", String(r.meetingID)], env: [:], timeout: nil, call: PipelineCall(), container: s.container, epoch: currentEpoch(), outRoot: s.out, stdin: nil)
        guard case .failure(let e) = empty else { Issue.record("expected a failure"); return }
        #expect(e.description == "no text on stdin (use --clear to empty the notes)")
        let unknown = Pipeline.runNative(["frobnicate"], env: [:], timeout: nil, call: PipelineCall(), container: s.container, epoch: currentEpoch(), outRoot: s.out, stdin: nil)
        guard case .failure(let u) = unknown else { Issue.record("expected a failure"); return }
        #expect(u.description == "bad arguments: unknown command frobnicate")
        let stale = Pipeline.runNative(["delete", "1"], env: [:], timeout: nil, call: PipelineCall(), container: s.container, epoch: currentEpoch() - 1, outRoot: s.out, stdin: nil)
        guard case .failure(let c) = stale else { Issue.record("expected a failure"); return }
        #expect(c.description == "cancelled")
    }
}
