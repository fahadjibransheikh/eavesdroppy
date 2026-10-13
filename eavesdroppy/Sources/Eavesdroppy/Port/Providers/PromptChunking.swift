import Foundation

/// Apple Intelligence's on-device model has a small context window (about 4,096 tokens for input and output together),
/// so a long transcript goes through summarise-then-merge. This file is the model-free part: finding the transcript in a
/// built prompt, cutting it into chunks, and putting a digest back. Citations ride along as plain text.
enum PromptChunking {
    struct Split: Equatable {
        var head: String   // everything up to and including the opening fence line
        var body: String   // the fenced lines
        var tail: String   // from the closing fence line to the end
    }

    /// Finds the fenced transcript (notes) or excerpts (Ask) in a prompt built by NotesPrompt. nil when there is none,
    /// in which case the caller sends the prompt as it is. The closing fence is unique because untrusted text has every
    /// closing tag defused; the opening fence is the first one after the transcript marker line (or the first one at all).
    static func split(_ prompt: String) -> Split? {
        for tag in ["transcript", "excerpts"] {
            let open = "\n<\(tag)>\n", close = "\n</\(tag)>"
            guard let closeR = prompt.range(of: close, options: .backwards) else { continue }
            let searchFrom = prompt.range(of: "Transcript (each line is")?.upperBound ?? prompt.startIndex
            guard let openR = prompt.range(of: open, range: searchFrom..<closeR.lowerBound) ?? prompt.range(of: open, range: prompt.startIndex..<closeR.lowerBound)
            else { continue }
            return Split(head: String(prompt[..<openR.upperBound]), body: String(prompt[openR.upperBound..<closeR.lowerBound]),
                         tail: String(prompt[closeR.lowerBound...]).dropFirstNewline)
        }
        return nil
    }

    static func join(_ s: Split) -> String { s.head + s.body + "\n" + s.tail }

    /// A deliberately pessimistic token estimate (the on-device tokenizer isn't available to a pure function):
    /// ASCII about 3 characters a token, everything else (CJK, emoji) about one token a scalar.
    static func estimateTokens(_ s: String) -> Int {
        var ascii = 0, other = 0
        for u in s.unicodeScalars { if u.isASCII { ascii += 1 } else { other += 1 } }
        return (ascii + 2) / 3 + other
    }

    /// Groups whole lines into chunks of at most `budget` estimated tokens. A single line over budget is cut
    /// mid-line (a monologue has to go somewhere); every other boundary falls between lines, so no `[T12 03:41]`
    /// prefix is split from its text.
    static func chunks(of text: String, budget: Int) -> [String] {
        var out: [String] = [], cur: [String] = [], used = 0
        func flush() { if !cur.isEmpty { out.append(cur.joined(separator: "\n")); cur = []; used = 0 } }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            for piece in cut(line, budget: budget) {
                let t = estimateTokens(piece) + 1
                if used + t > budget { flush() }
                cur.append(piece); used += t
            }
        }
        flush()
        return out
    }

    private static func cut(_ line: String, budget: Int) -> [String] {
        if estimateTokens(line) <= budget { return [line] }
        var pieces: [String] = [], cur = String.UnicodeScalarView()
        for u in line.unicodeScalars {
            cur.append(u)
            if estimateTokens(String(cur)) >= budget - 1 { pieces.append(String(cur)); cur = String.UnicodeScalarView() }
        }
        if !cur.isEmpty { pieces.append(String(cur)) }
        return pieces
    }
}

private extension String {
    var dropFirstNewline: String { hasPrefix("\n") ? String(dropFirst()) : self }
}
