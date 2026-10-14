import Foundation
import Testing
@testable import Eavesdroppy

// In-person meetings (meta.json "setting": "in_person"): no echo stage, no assumed "Me", no silent-call warning, and a
// Setting line in the notes.md / transcript.md header. The Setting text and the header are checked against library.py
// (Fixtures/logic/setting.json); the processor runs on fake engines.

private final class Lines: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.withLock { v.append(s) } }
    var all: [String] { lock.withLock { v } }
}

@Suite struct InPersonTests {
    typealias F = LogicFixture

    @Test func settingTextAndHeaderMatchPython() throws {
        let j = try F.json("setting")
        for c in j["texts"] as! [[String: Any]] {
            let meta = c["meta"] as! [String: Any]
            #expect(StoreMirror.settingText(meta) == c["expected"] as? String, "\(meta)")
        }
        let headers = j["headers"] as! [[String: Any]]
        #expect(headers.count == 8)
        for h in headers {
            let m = StoreMirror.Meeting(id: 1, title: h["title"] as! String, start: h["start"] as! String, duration: F.d(h["duration"]),
                                        attendees: h["attendees"] as! [String], notesMD: "", folder: nil, audioPath: nil, turns: [],
                                        setting: h["setting"] as? String, rawDir: nil)
            #expect(try StoreMirror.header(m) == h["expected"] as! String)
        }
    }

    @Test func headerReadsTheRawArchiveAndKeepsTheLineWhenItIsGone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inperson-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data(#"{"setting":"call","call_apps":["Zoom","Chrome"]}"#.utf8).write(to: dir.appendingPathComponent("raw/meta.json"))
        var m = StoreMirror.Meeting(id: 1, title: "Sync", start: "2026-10-13T19:22:30+05:00", duration: 60, attendees: [], notesMD: "## Summary\n\nx",
                                    folder: nil, audioPath: nil, turns: [], rawDir: dir.path + "/raw")
        #expect(try StoreMirror.header(m).hasSuffix("- **Setting:** Call (Zoom, Chrome)"))
        // the meeting is written, then the raw audio expires (raw_dir cleared): a re-render keeps the line
        let first = try StoreMirror.write(m, outRoot: dir.path + "/out")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("raw"))
        m.rawDir = nil; m.folder = first.folder
        _ = try StoreMirror.write(m, outRoot: dir.path + "/out")
        #expect(try String(contentsOfFile: first.folder + "/notes.md", encoding: .utf8).contains("- **Setting:** Call (Zoom, Chrome)"))
        // a meeting that never had the field gains none
        m.folder = nil; m.title = "Other"
        let other = try StoreMirror.write(m, outRoot: dir.path + "/out2")
        #expect(try !String(contentsOfFile: other.folder + "/notes.md", encoding: .utf8).contains("Setting"))
    }

    @Test func inPersonProcessingSkipsEchoAssumesNoMeAndSaysSo() async throws {
        let s = try Scratch(meta: ["setting": "in_person"]); defer { s.remove() }
        try ProcessorAudio.writeMonoFloat([Float](repeating: 0, count: 48_000 * 3), rate: 48_000, to: s.session.appendingPathComponent("system.wav"))  // nothing played
        let lines = Lines()
        var p = s.params(); p.log = { lines.add($0) }
        let r = try await Processor.process(p)
        #expect(r.warnings.isEmpty, "no 'Call audio was silent' in person: \(r.warnings)")
        #expect(lines.all.contains { $0.hasPrefix("Echo: skipped") }, "\(lines.all)")
        #expect(!lines.all.contains { $0.hasPrefix("Echo: bleed") })
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        let sp = try db.rows("SELECT label, kind FROM speakers")
        #expect(sp.count == 1)
        #expect(sp[0].text(0) == "Speaker 1" && sp[0].text(1) == "new", "\(sp)")   // the mic cluster is not "Me" by assumption
        let notes = try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8), transcript = try String(contentsOfFile: r.folder + "/transcript.md", encoding: .utf8)
        #expect(notes.contains("- **Attendees:** Alice Jones\n- **Setting:** In person\n"), Comment(rawValue: notes))
        #expect(transcript.contains("- **Setting:** In person\n\n---"))
        #expect(!notes.contains("**Me:**"))
    }

    @Test func aCallKeepsTheOldBehaviourAndNamesTheApps() async throws {
        let s = try Scratch(meta: ["setting": "call", "call_apps": ["Zoom"]]); defer { s.remove() }
        let lines = Lines()
        var p = s.params(); p.log = { lines.add($0) }
        let r = try await Processor.process(p)
        #expect(!lines.all.contains { $0.hasPrefix("Echo: skipped") })
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { db.close() }
        #expect(Set(try db.rows("SELECT label FROM speakers").compactMap { $0.text(0) }) == ["Me", "Speaker 1"])
        #expect(try String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8).contains("- **Setting:** Call (Zoom)\n"))
    }

    @Test func recordingsWithoutTheFieldHaveNoSettingLine() async throws {
        let s = try Scratch(); defer { s.remove() }
        let r = try await Processor.process(s.params())
        #expect(try !String(contentsOfFile: r.folder + "/notes.md", encoding: .utf8).contains("Setting"))
    }
}
