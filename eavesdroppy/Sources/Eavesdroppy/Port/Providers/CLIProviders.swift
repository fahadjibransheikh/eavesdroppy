import Foundation

/// The three agent CLIs. Each runs headless, with tools off or read-only wherever the CLI allows, in a throwaway
/// directory, with a minimal environment (the transcript inside the prompt is untrusted input).
///
/// Verified: Claude Code (the same invocation notes.run_claude uses today, run live on this Mac).
/// NOT verified: Codex (not installed here; flags from the docs page) and Grok Build (flags from `grok --help` and its
/// docs; this Mac is not signed in to Grok, so no reply was ever produced).
struct CLIProvider: NotesProvider {
    enum Kind: String, CaseIterable { case claude = "claude-code", codex, grok }

    let kind: Kind
    var timeout: TimeInterval = 600          // CLAUDE_TIMEOUT in notes.py
    /// Empty = the CLI's own default model.
    var model: String = ""
    /// Overridable for tests; defaults to the usual install places.
    var searchDirs: [String] = CLILocator.searchDirs()
    var home: String = NSHomeDirectory()

    var id: String { kind.rawValue }
    var displayName: String {
        switch kind { case .claude: return "Claude Code"; case .codex: return "OpenAI Codex"; case .grok: return "Grok Build" }
    }
    private var binaryName: String { kind == .claude ? "claude" : kind.rawValue }
    private var toolName: String { binaryName }  // as the reason strings name it: "claude exited 1: …"

    var path: String? {
        CLILocator.find(binaryName, override: kind == .claude ? ProcessInfo.processInfo.environment["EAVESDROPPY_CLAUDE_BIN"] : nil, dirs: searchDirs)
    }

    func isAvailable() async -> Bool { path != nil }

    func availabilityDetail() async -> String {
        if let p = path { return p.replacingOccurrences(of: home, with: "~") }
        return ProviderSettingsModel.notFound
    }

    // MARK: Invocations (pure, so tests can pin them)

    /// Arguments after the executable. `dir` is the scratch directory (also the cwd); `outFile` is where Codex writes its final message.
    func arguments(dir: URL) -> [String] {
        switch kind {
        case .claude:
            // notes.run_claude: no tools, no settings; the prompt arrives on stdin.
            return ["-p", "--setting-sources", "", "--tools", ""] + (model.isEmpty ? [] : ["--model", model])
        case .codex:
            // https://developers.openai.com/codex/noninteractive: read-only sandbox is the exec default, stated anyway;
            // `-` reads the prompt from stdin; -o writes the final message to a file.
            return ["exec", "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                    "-C", dir.path, "-o", Self.codexOutput(dir).path] + (model.isEmpty ? [] : ["-m", model]) + ["-"]
        case .grok:
            // `grok --help` 1.0.34: --prompt-file for a long transcript, plain text out, every built-in tool removed, no
            // permission prompts (dontAsk denies), no update check. Tool ids are from the Grok docs (14-headless-mode.md).
            return ["--prompt-file", Self.grokPrompt(dir).path, "--output-format", "plain", "--no-auto-update", "--permission-mode", "dontAsk",
                    "--disallowed-tools", Self.grokTools, "--max-turns", "3", "--no-plan", "--no-subagents", "--disable-web-search",
                    "--cwd", dir.path] + (model.isEmpty ? [] : ["--model", model])
        }
    }

    static let grokTools = "run_terminal_cmd,read_file,write_file,search_replace,list_dir,grep,web_search,web_fetch,todo_write,ask_user_question,Agent"
    static func codexOutput(_ dir: URL) -> URL { dir.appendingPathComponent("last-message.txt") }
    static func grokPrompt(_ dir: URL) -> URL { dir.appendingPathComponent("prompt.txt") }

    func environment(binary: String) -> [String: String] {
        let src = ProcessInfo.processInfo.environment
        var env = ["HOME", "USER", "LOGNAME", "TMPDIR"].reduce(into: [String: String]()) { if let v = src[$1] { $0[$1] = v } }
        switch kind {
        case .claude:
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"  // as notes.run_claude
        case .codex:
            // An npm-installed codex is a node script: its dir and the usual node homes must be on PATH.
            env["PATH"] = ([URL(fileURLWithPath: binary).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
                           + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
            if let k = src["OPENAI_API_KEY"] { env["OPENAI_API_KEY"] = k }
            if let h = src["CODEX_HOME"] { env["CODEX_HOME"] = h }
        case .grok:
            env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            env["GROK_DISABLE_AUTOUPDATER"] = "1"
            if let k = src["XAI_API_KEY"] { env["XAI_API_KEY"] = k }
            if let h = src["GROK_HOME"] { env["GROK_HOME"] = h }
        }
        return env
    }

    // MARK: Run

    func complete(prompt: String) async throws -> String {
        guard let bin = path else { throw NotesProviderError.notInstalled(toolName) }
        let out = try await ProcessRunner.run(
            name: toolName, executable: bin,
            arguments: { dir in
                // Grok takes its prompt as a file in the scratch directory (a transcript can outgrow argv).
                if kind == .grok { try? prompt.write(to: Self.grokPrompt(dir), atomically: true, encoding: .utf8) }
                return arguments(dir: dir)
            },
            stdin: kind == .grok ? nil : prompt, environment: environment(binary: bin), timeout: timeout,
            readExtra: kind == .codex ? { try? String(contentsOf: Self.codexOutput($0), encoding: .utf8) } : nil)
        return try Self.reply(kind: kind, name: toolName, output: out)
    }

    /// Turns a finished run into text or the reason it failed.
    static func reply(kind: Kind, name: String, output o: ProcessRunner.Output) throws -> String {
        // Codex: the -o file holds the final message alone; stdout also carries it, but only the file is guaranteed to be just the answer.
        let text = (o.extra ?? o.stdout).pyStripped
        if o.status != 0 || text.isEmpty {
            if kind == .grok, o.status != 0, ProcessRunner.failureDetail(o).contains("Not signed in") {
                throw NotesProviderError.notConfigured("Grok Build is not signed in. Run `grok login` in Terminal, or set XAI_API_KEY.")
            }
            throw NotesProviderError.failed(name, Int(o.status), ProcessRunner.failureDetail(o))
        }
        return text
    }
}
