import AppKit
import ApplicationServices
import Foundation

// D18: best-effort participant names from a call app's Accessibility tree. Names are candidates for speaker naming,
// never ground truth, so everything here errs toward collecting less. Two steps: `AXReader` snapshots a window tree
// under hard limits (depth, node count, time), `ParticipantNames` picks name-like labels out of a snapshot (pure, so
// it is tested on synthetic trees). Never on the main thread, never blocks audio.

/// One accessibility element, reduced to the labels that can carry a name.
struct AXSnap {
    var role = "", title = "", desc = "", value = "", id = ""
    var children: [AXSnap] = []

    /// Every label this element has, in the order they are most likely to be the name.
    var labels: [String] { [value, title, desc].filter { !$0.isEmpty } }
}

enum ParticipantNames {
    /// Words that make a label a control or a status rather than a person.
    private static let banned: Set<String> = [
        "you", "me", "mute", "unmute", "muted", "unmuted", "participants", "participant", "attendees", "people", "chat", "share",
        "share screen", "more", "leave", "end", "end meeting", "leave meeting", "video", "start video", "stop video", "audio",
        "security", "record", "recording", "reactions", "apps", "whiteboards", "whiteboard", "invite", "host", "co-host", "guest",
        "presenter", "organizer", "raise hand", "lower hand", "meeting", "call", "search", "close", "waiting room", "in the meeting",
        "contact info", "details", "mic", "microphone", "camera", "pin", "spotlight", "speaker", "view", "gallery", "settings",
    ]
    private static let statusWords: Set<String> = ["muted", "unmuted", "host", "co-host", "organizer", "presenter", "presenting", "guest",
                                                  "you", "me", "video", "camera", "raised", "speaking", "attendee", "on", "off", "hand"]
    private static let controlFragments = ["mute", "video", "microphone", "camera", "participant", "button", "screen", "invite", "meeting"]

    /// A person-like label from raw AX text, or nil: "Priya Nair, Muted, Host" -> "Priya Nair", "Sam (Guest)" -> "Sam".
    /// Labels marking the user themselves ("(You)", "(Me)") return nil: the user is not a candidate for naming others.
    static func normalize(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 80 else { return nil }
        let lower = s.lowercased()
        if lower.contains("(you)") || lower.contains("(me)") || lower.hasSuffix(", you") || lower.hasSuffix(", me") || lower.contains("(host, me)") { return nil }
        if let comma = s.firstIndex(of: ",") {
            let rest = s[s.index(after: comma)...].lowercased().split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
            if !rest.isEmpty, rest.allSatisfy({ statusWords.contains($0) || $0 == "and" }) { s = String(s[..<comma]) }
        }
        while let r = s.range(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = s.lowercased()
        guard !s.isEmpty, s.count <= 50, !banned.contains(l), let first = s.unicodeScalars.first, CharacterSet.letters.contains(first),
              !s.contains(where: \.isNumber), !s.contains("@"), !s.contains("/"), !s.contains(":") else { return nil }
        let words = s.split(separator: " ")
        guard words.count <= 5, !controlFragments.contains(where: { l.contains($0) }) else { return nil }
        return s
    }

    private static func nameLike(_ n: AXSnap) -> [String] {
        n.labels.compactMap(normalize)
    }

    /// "(You)" / "(Me)" on any label of this element: the row or tile is the user, so nothing inside it is a candidate.
    private static func isSelf(_ n: AXSnap) -> Bool {
        n.labels.contains { l in let x = l.lowercased(); return x.contains("(you)") || x.contains("(me)") || x.hasSuffix(", you") || x.hasSuffix(", me") }
    }

    private static func isContainer(_ n: AXSnap) -> Bool {
        let t = (n.title + " " + n.desc + " " + n.id).lowercased()
        return t.contains("participant") || t.contains("attendee")
    }

    private static func mentionsMute(_ n: AXSnap) -> Bool {
        let t = (n.title + " " + n.desc + " " + n.value + " " + n.id).lowercased()
        return t.contains("mute") || t.contains("microphone")
    }

    private static func subtree(_ n: AXSnap, depth: Int, _ body: (AXSnap) -> Void) {
        body(n)
        if depth > 0 { for c in n.children { subtree(c, depth: depth - 1, body) } }
    }

    /// Rule A: everything name-like inside a list, table or panel labelled "participants" (Zoom's panel, Meet's and
    /// Teams' rosters). Rule B: a tile (group/row/cell) that holds a mute indicator and a short static text, the way
    /// video tiles label themselves when no roster is open. Buttons and their labels are never names.
    static func extract(_ roots: [AXSnap]) -> [String] {
        var found: [String] = []
        func add(_ s: String) { if !found.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { found.append(s) } }

        func collect(_ n: AXSnap, inRoster: Bool) {
            if n.role == "AXButton" || n.role == "AXMenuButton" || n.role == "AXPopUpButton" || n.role == "AXCheckBox" || n.role == "AXImage" { return }
            if isSelf(n) { return }
            let roster = inRoster || isContainer(n)
            if roster, ["AXStaticText", "AXRow", "AXCell", "AXGroup", "AXListItem", "AXOutlineRow", "AXTextField", "AXLink"].contains(n.role) {
                nameLike(n).forEach(add)
            }
            if !roster, ["AXGroup", "AXCell", "AXRow", "AXLayoutItem"].contains(n.role) {
                var mute = false
                var texts: [String] = []
                subtree(n, depth: 3) { d in
                    if mentionsMute(d) { mute = true }
                    if d.role == "AXStaticText" { texts += nameLike(d) }
                }
                if mute, !texts.isEmpty, texts.count <= 2 { texts.forEach(add) }
            }
            for c in n.children { collect(c, inRoster: roster) }
        }
        roots.forEach { collect($0, inRoster: false) }
        return found
    }
}

enum AXReader {
    static let maxDepth = 25, maxNodes = 5000, budget: TimeInterval = 0.2
    private static let attrs = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                                kAXIdentifierAttribute, kAXChildrenAttribute] as CFArray

    static var trusted: Bool { AXIsProcessTrusted() }  // never AXIsProcessTrustedWithOptions(prompt): the user opts in from Settings

    /// Snapshots the windows of `pid` whose title passes `windowFilter`, within the limits. Returns what it got when
    /// a limit hit. The messaging timeout is set on this app's elements only, never process-wide.
    static func snapshot(pid: pid_t, windowFilter: (String) -> Bool) -> [AXSnap] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(budget))
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success, let windows = raw as? [AXUIElement] else { return [] }
        let deadline = Date().addingTimeInterval(budget)
        var nodes = 0
        var out: [AXSnap] = []
        for w in windows.prefix(20) where Date() < deadline {
            AXUIElementSetMessagingTimeout(w, Float(budget))
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
            guard windowFilter((title as? String) ?? "") else { continue }
            out.append(walk(w, depth: 0, nodes: &nodes, deadline: deadline))
        }
        return out
    }

    private static func walk(_ el: AXUIElement, depth: Int, nodes: inout Int, deadline: Date) -> AXSnap {
        nodes += 1
        var snap = AXSnap()
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let list = values as? [Any], list.count == 6 else { return snap }
        func str(_ i: Int) -> String { (list[i] as? String) ?? "" }
        snap.role = str(0); snap.title = str(1); snap.desc = str(2); snap.value = str(3); snap.id = str(4)
        guard depth < maxDepth, let kids = list[5] as? [AXUIElement] else { return snap }
        for k in kids {
            if nodes >= maxNodes || Date() >= deadline { break }
            snap.children.append(walk(k, depth: depth + 1, nodes: &nodes, deadline: deadline))
        }
        return snap
    }

    private static let callWindow = try! NSRegularExpression(pattern: "meet|zoom|teams|webex|huddle|call|participants", options: .caseInsensitive)

    static func isCallWindow(_ title: String) -> Bool {
        callWindow.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }

    /// Names found right now in every running call app. Off the main thread.
    static func scan() -> [String] {
        guard trusted else { return [] }
        var names: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, !app.isTerminated, CallApps.participantApps.contains(id) else { continue }
            let native = id == "us.zoom.xos" || id.hasPrefix("com.microsoft.teams")
            let snaps = snapshot(pid: app.processIdentifier) { native || isCallWindow($0) }
            for n in ParticipantNames.extract(snaps) where !names.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { names.append(n) }
        }
        return names
    }
}
