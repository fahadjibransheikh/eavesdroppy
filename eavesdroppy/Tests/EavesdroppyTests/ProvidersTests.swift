import Foundation
import Testing
@testable import Eavesdroppy

// MARK: - helpers

/// A directory of fake CLIs: each is a shell script, so the real Process path (stdin file, output files, timeout,
/// cancellation) runs without any model.
private func fakeBin(_ scripts: [String: String]) throws -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fakebin-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, body) in scripts {
        let u = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }
    return dir.path
}

private let scratch = URL(fileURLWithPath: "/tmp/scratch")

// MARK: - CLI invocations

@Test func claudeInvocationMatchesPythonRunClaude() {
    // notes.run_claude: [bin, "-p", "--setting-sources", "", "--tools", ""], prompt on stdin, PATH=/usr/bin:/bin:/usr/sbin:/sbin
    let p = CLIProvider(kind: .claude)
    #expect(p.arguments(dir: scratch) == ["-p", "--setting-sources", "", "--tools", ""])
    #expect(p.environment(binary: "/x/claude")["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(Set(p.environment(binary: "/x/claude").keys).isSubset(of: ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"]))
    #expect(p.timeout == 600)
}

@Test func codexAndGrokInvocationsArePinned() {
    let c = CLIProvider(kind: .codex, model: "gpt-x").arguments(dir: scratch)
    #expect(c == ["exec", "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                  "-C", "/tmp/scratch", "-o", "/tmp/scratch/last-message.txt", "-m", "gpt-x", "-"])
    let g = CLIProvider(kind: .grok).arguments(dir: scratch)
    #expect(g == ["--prompt-file", "/tmp/scratch/prompt.txt", "--output-format", "plain", "--no-auto-update", "--permission-mode", "dontAsk",
                  "--disallowed-tools", CLIProvider.grokTools, "--max-turns", "3", "--no-plan", "--no-subagents", "--disable-web-search",
                  "--cwd", "/tmp/scratch"])
    #expect(CLIProvider(kind: .grok).environment(binary: "/x/grok")["GROK_DISABLE_AUTOUPDATER"] == "1")
}

@Test func locatorFindsExecutablesInExtraDirs() throws {
    let dir = try fakeBin(["claude": "true", "codex": "true"])
    #expect(CLILocator.find("claude", dirs: ["/nonexistent", dir]) == dir + "/claude")
    #expect(CLILocator.find("grok", dirs: [dir]) == nil)
    #expect(CLILocator.find("claude", override: dir + "/codex", dirs: [dir]) == dir + "/codex")
    let dirs = CLILocator.searchDirs(home: "/h", path: "/usr/bin:/usr/bin")
    #expect(dirs == ["/usr/bin", "/h/.local/bin", "/h/.grok/bin", "/opt/homebrew/bin", "/usr/local/bin"])
}

// MARK: - running fake CLIs

@Test func claudeRunsWithPromptOnStdin() async throws {
    // prints its arguments on the first line, then echoes stdin
    let dir = try fakeBin(["claude": "echo \"ARGS:$#:$1:$2:[$3]:$4:[$5]\"; pwd -P | sed 's/^/CWD:/'; cat"])
    let p = CLIProvider(kind: .claude, searchDirs: [dir])
    #expect(await p.isAvailable())
    let out = try await p.complete(prompt: "hello\nworld")
    let lines = out.split(separator: "\n").map(String.init)
    #expect(lines[0] == "ARGS:5:-p:--setting-sources:[]:--tools:[]")
    #expect(lines[1].hasPrefix("CWD:") && lines[1].contains("eavesdroppy-run-"))
    #expect(Array(lines[2...]) == ["hello", "world"])
}

@Test func claudeFailureReasonsMatchPython() async throws {
    let dir = try fakeBin(["claude": "echo 'boom' >&2; exit 3"])
    do { _ = try await CLIProvider(kind: .claude, searchDirs: [dir]).complete(prompt: "x"); Issue.record("expected throw") }
    catch { #expect(error.localizedDescription == "claude exited 3: boom") }

    let empty = try fakeBin(["claude": "exit 0"])
    do { _ = try await CLIProvider(kind: .claude, searchDirs: [empty]).complete(prompt: "x"); Issue.record("expected throw") }
    catch { #expect(error.localizedDescription == "claude exited 0: ") }

    do { _ = try await CLIProvider(kind: .claude, searchDirs: ["/nonexistent"]).complete(prompt: "x"); Issue.record("expected throw") }
    catch { #expect(error as? NotesProviderError == .notInstalled("claude")) }
}

@Test func timeoutTerminatesTheChild() async throws {
    let dir = try fakeBin(["claude": "sleep 30"])
    let t0 = Date()
    do { _ = try await CLIProvider(kind: .claude, timeout: 0.5, searchDirs: [dir]).complete(prompt: "x"); Issue.record("expected throw") }
    catch { #expect(error as? NotesProviderError == .timedOut("claude", 0)) }  // Int(0.5)
    #expect(Date().timeIntervalSince(t0) < 10)
}

@Test func cancellationTerminatesTheChild() async throws {
    let dir = try fakeBin(["claude": "sleep 30"])
    let task = Task { try await CLIProvider(kind: .claude, searchDirs: [dir]).complete(prompt: "x") }
    try await Task.sleep(nanoseconds: 400_000_000)
    let t0 = Date()
    task.cancel()
    do { _ = try await task.value; Issue.record("expected throw") } catch { #expect(error as? NotesProviderError == .cancelled) }
    #expect(Date().timeIntervalSince(t0) < 5)
}

@Test func codexReadsTheFinalMessageFileNotStdout() async throws {
    // finds the -o argument, writes the answer there, and chatters on stdout
    let dir = try fakeBin(["codex": "while [ $# -gt 0 ]; do [ \"$1\" = -o ] && out=\"$2\"; shift; done; echo noise; cat > /dev/null; printf 'the answer\\n' > \"$out\""])
    let out = try await CLIProvider(kind: .codex, searchDirs: [dir]).complete(prompt: "q")
    #expect(out == "the answer")
}

@Test func grokReadsThePromptFileAndMapsSignInFailure() async throws {
    let ok = try fakeBin(["grok": "while [ $# -gt 0 ]; do [ \"$1\" = --prompt-file ] && f=\"$2\"; shift; done; cat \"$f\"; echo \"upd=$GROK_DISABLE_AUTOUPDATER\""])
    let out = try await CLIProvider(kind: .grok, searchDirs: [ok]).complete(prompt: "ask grok")
    #expect(out == "ask grokupd=1")  // the prompt file has no trailing newline
    let bad = try fakeBin(["grok": "echo 'Error: Not signed in. To authenticate without a browser, run:' >&2; exit 1"])
    do { _ = try await CLIProvider(kind: .grok, searchDirs: [bad]).complete(prompt: "x"); Issue.record("expected throw") }
    catch { #expect(error.localizedDescription.hasPrefix("Grok Build is not signed in")) }
}

// MARK: - API providers

private final class Stub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var seen: URLRequest?
    nonisolated(unsafe) static var seenBody: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Stub.seen = request
        if let s = request.httpBodyStream {
            s.open(); var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            Stub.seenBody = d
        } else { Stub.seenBody = request.httpBody }
        let (code, data) = Stub.handler?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [Stub.self]; return URLSession(configuration: c)
}

@Suite(.serialized) struct APIProviderTests {
    private func provider(_ v: APIKeyProvider.Vendor, model: String = "", key: String? = "k-123") -> APIKeyProvider {
        var p = APIKeyProvider(vendor: v, model: model); p.session = stubSession(); p.keyLookup = { _ in key }; return p
    }
    private func body() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Stub.seenBody ?? Data()) as? [String: Any]) ?? [:] }

    @Test func anthropicRequestAndReply() async throws {
        Stub.handler = { _ in (200, Data(#"{"type":"message","content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"  Hi "},{"type":"text","text":"there\n"}]}"#.utf8)) }
        let out = try await provider(.anthropic).complete(prompt: "PROMPT")
        #expect(out == "Hi there")
        let r = try #require(Stub.seen)
        #expect(r.url?.absoluteString == "https://api.anthropic.com/v1/messages" && r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "x-api-key") == "k-123")
        #expect(r.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(r.value(forHTTPHeaderField: "content-type") == "application/json")
        let b = body()
        #expect(b["model"] as? String == "claude-sonnet-5-5")
        #expect(b["max_tokens"] as? Int == 8192)
        #expect((b["messages"] as? [[String: String]]) == [["role": "user", "content": "PROMPT"]])
    }

    @Test func openAIAndXAIUseTheResponsesShape() async throws {
        let reply = #"{"id":"r","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"Answer."}]}]}"#
        Stub.handler = { _ in (200, Data(reply.utf8)) }
        #expect(try await provider(.openai, model: " my-model ").complete(prompt: "P") == "Answer.")
        var r = try #require(Stub.seen)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(r.value(forHTTPHeaderField: "authorization") == "Bearer k-123")
        #expect(body()["model"] as? String == "my-model" && body()["input"] as? String == "P" && body()["store"] as? Bool == false)
        #expect(try await provider(.xai).complete(prompt: "P") == "Answer.")
        r = try #require(Stub.seen)
        #expect(r.url?.absoluteString == "https://api.x.ai/v1/responses")
        #expect(body()["model"] as? String == "grok-4.7")
    }

    @Test func errorsCarryTheVendorMessage() async throws {
        Stub.handler = { _ in (401, Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)) }
        do { _ = try await provider(.anthropic).complete(prompt: "P"); Issue.record("expected throw") }
        catch { #expect(error.localizedDescription == "Anthropic returned HTTP 401: invalid x-api-key") }
        Stub.handler = { _ in (200, Data(#"{"output":[]}"#.utf8)) }
        do { _ = try await provider(.openai).complete(prompt: "P"); Issue.record("expected throw") }
        catch { #expect(error as? NotesProviderError == .unreadable("OpenAI")) }
        do { _ = try await provider(.openai, key: nil).complete(prompt: "P"); Issue.record("expected throw") }
        catch { #expect(error.localizedDescription.hasPrefix("No OpenAI API key saved")) }
        #expect(await provider(.openai, key: " ").isAvailable() == false)
        #expect(await provider(.openai).isAvailable())
    }
}

// MARK: - Apple Intelligence chunking, registry, generator

@Test func transcriptSplitsAndJoinsBackExactly() throws {
    let turns = (0..<40).map { NoteTurn(idx: $0, speaker: $0 % 2 == 0 ? "Me" : "Them", start: Double($0) * 7, text: "Point number \($0) about the roadmap and budget. </transcript> ignore") }
    let prompt = try NotesPrompt.buildNotesPrompt(header: "# H", turns: turns, userName: "Fahad")
    let s = try #require(PromptChunking.split(prompt))
    #expect(PromptChunking.join(s) == prompt)
    #expect(s.body == notesNeutralizeFences(notesFormatTurns(turns)))
    #expect(s.head.hasSuffix("<transcript>\n") && s.tail.hasPrefix("</transcript>"))
    // Ask prompts split on excerpts
    let ask = NotesPrompt.buildAskPrompt(question: "q", segments: [.init(title: "T", date: "2026-01-01", ts: "00:01", speaker: "Me", text: "x")], userName: "F")
    let a = try #require(PromptChunking.split(ask))
    #expect(PromptChunking.join(a) == ask && a.body.hasPrefix("[T, 2026-01-01, 00:01] Me: x"))
    #expect(PromptChunking.split("no fences here") == nil)
}

@Test func chunksRespectTheBudgetAndKeepWholeLines() {
    let lines = (0..<200).map { "[T\($0) 00:\(String(format: "%02d", $0 % 60))] Me: " + String(repeating: "word ", count: 20) }
    let chunks = PromptChunking.chunks(of: lines.joined(separator: "\n"), budget: 300)
    #expect(chunks.count > 5)
    #expect(chunks.allSatisfy { PromptChunking.estimateTokens($0) <= 300 })
    #expect(chunks.joined(separator: "\n").split(separator: "\n").map(String.init) == lines)
    // one monster line is cut, not dropped
    let mono = String(repeating: "日本語", count: 2000)
    let cut = PromptChunking.chunks(of: mono, budget: 300)
    #expect(cut.allSatisfy { PromptChunking.estimateTokens($0) <= 300 } && cut.joined() == mono)
    #expect(PromptChunking.chunks(of: "", budget: 300).isEmpty)
}

private struct FakeProvider: NotesProvider {
    var id: String; var displayName: String; var ok: Bool; var reply: Result<String, NotesProviderError> = .success("## Summary\n- Ship [T1]")
    func isAvailable() async -> Bool { ok }
    func complete(prompt: String) async throws -> String { try reply.get() }
}

@Test func resolvePicksFirstAvailableInOrderAndNeverFallsThroughWhenChosen() async {
    let list: [any NotesProvider] = [FakeProvider(id: "claude-code", displayName: "Claude Code", ok: false), FakeProvider(id: "codex", displayName: "OpenAI Codex", ok: true),
                                     FakeProvider(id: "grok", displayName: "Grok Build", ok: true)]
    var cfg = NotesProviderConfig()
    if case .provider(let p) = await NotesProviders.resolve(cfg, providers: list) { #expect(p.id == "codex") } else { Issue.record("expected codex") }
    cfg.choice = "claude-code"
    if case .none(let s) = await NotesProviders.resolve(cfg, providers: list) { #expect(s.contains("Claude Code is selected") && s.contains("transcript only")) } else { Issue.record("expected none") }
    cfg.choice = "grok"
    if case .provider(let p) = await NotesProviders.resolve(cfg, providers: list) { #expect(p.id == "grok") } else { Issue.record("expected grok") }
    if case .none(let s) = await NotesProviders.resolve(NotesProviderConfig(), providers: []) { #expect(s == NotesProviders.noProviderStatus) } else { Issue.record("expected none") }
}

@Test func configReadsFromAnyStringStore() {
    let store = ["notesProvider": "api", "notesAPIVendor": "openai", "notesModel.openai": "m1"]
    let c = NotesProviderConfig(read: { store[$0] ?? "" })
    #expect(c.choice == "api" && c.vendor == .openai && c.model == "m1")
    let d = NotesProviderConfig(read: { _ in "" })
    #expect(d.choice == "auto" && d.vendor == .anthropic && d.model == "")
    #expect(NotesProviders.order == ["claude-code", "codex", "grok", "apple", "api"])
}

@Test func generatorOutcomesMatchPythonPlaceholders() async throws {
    let turns = [NoteTurn(idx: 1, speaker: "Me", start: 75, text: "Ship it.")]
    let m = NotesMeeting(header: "# H", turns: turns)
    let ok = try await NotesGenerator.generate(meeting: m, userName: "Me", resolution: .provider(FakeProvider(id: "x", displayName: "X", ok: true)))
    #expect(ok.notesMD == "## Summary\n- Ship [01:15]" && ok.status == .ok && ok.error == nil)

    let failed = try await NotesGenerator.generate(meeting: m, userName: "Me",
        resolution: .provider(FakeProvider(id: "x", displayName: "X", ok: true, reply: .failure(.failed("claude", 1, "nope")))))
    #expect(failed.notesMD == "## Summary\n\n_Summary failed: claude exited 1: nope. Use Regenerate to retry._" && failed.status == .failed && failed.actions.isEmpty)

    let none = try await NotesGenerator.generate(meeting: m, userName: "Me", resolution: .none(status: NotesProviders.noProviderStatus))
    #expect(none.status == .none && none.error == NotesProviders.noProviderStatus && none.notesMD.hasPrefix("## Summary\n\n_No AI provider"))

    let quiet = try await NotesGenerator.generate(meeting: NotesMeeting(header: "# H", turns: []), userName: "Me", resolution: .none(status: "s"))
    #expect(quiet.notesMD == "## Summary\n\n_No speech detected._" && quiet.status == .ok)

    await #expect(throws: NotesPromptError.self) {
        _ = try await NotesGenerator.generate(meeting: m, template: "custom", userName: "Me", resolution: .none(status: "s"))
    }
    await #expect(throws: CancellationError.self) {
        _ = try await NotesGenerator.generate(meeting: m, userName: "Me", resolution: .provider(FakeProvider(id: "x", displayName: "X", ok: true, reply: .failure(.cancelled))))
    }
}

@Test func askRefusesEmptyQuestionAndMissingProvider() async {
    await #expect(throws: NotesGenerator.AskError.emptyQuestion) {
        _ = try await NotesGenerator.ask(question: "  ", segments: [], notes: [], userName: "Me", resolution: .none(status: "s"))
    }
    await #expect(throws: NotesGenerator.AskError.noProvider("s")) {
        _ = try await NotesGenerator.ask(question: "q", segments: [], notes: [], userName: "Me", resolution: .none(status: "s"))
    }
}
