import Foundation
import Testing
@testable import Eavesdroppy

/// JSON written by tools/golden/logic_golden.py from the Python oracle. Ordered dicts are [[key, value]] arrays.
enum LogicFixture {
    /// JSONDecoder, not JSONSerialization: the latter parses some 17-digit doubles one ulp off.
    struct Node: Decodable {
        let v: Any
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if c.decodeNil() { v = NSNull() }
            else if let x = try? c.decode(Bool.self) { v = x }
            else if let x = try? c.decode(Int.self) { v = x }
            else if let x = try? c.decode(Double.self) { v = x }
            else if let x = try? c.decode(String.self) { v = x }
            else if let x = try? c.decode([Node].self) { v = x.map(\.v) }
            else { v = try c.decode([String: Node].self).mapValues(\.v) }
        }
    }
    static func json(_ name: String) throws -> [String: Any] {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/logic/\(name).json")
        return try JSONDecoder().decode(Node.self, from: Data(contentsOf: url)).v as! [String: Any]
    }
    static func d(_ x: Any?) -> Double { (x as! NSNumber).doubleValue }
    static func i(_ x: Any?) -> Int { (x as! NSNumber).intValue }
    static func s(_ x: Any?) -> String? { x as? String }
    static func b(_ x: Any?) -> Bool { (x as! NSNumber).boolValue }
    static func f(_ x: Any?) -> [Float] { (x as! [Any]).map { Float(d($0)) } }
    static func words(_ x: Any?) -> [Turns.Word] { (x as! [[Any]]).map { Turns.Word(text: $0[0] as! String, start: d($0[1]), end: d($0[2])) } }
    static func pairs(_ x: Any?) -> [(String, Any)] { (x as! [[Any]]).map { (($0[0] as? String) ?? String(i($0[0])), $0[1]) } }
}

@Suite struct TurnsTests {
    typealias F = LogicFixture

    @Test func buildTurnsMatchesPython() throws {
        let cases = try F.json("turns")["build"] as! [[String: Any]]
        #expect(cases.count > 300)
        for c in cases {
            let tracks = (c["tracks"] as! [[Any]]).map { (speaker: F.i($0[0]), words: F.words($0[1])) }
            let offsets = Dictionary(uniqueKeysWithValues: (c["offsets"] as! [[Any]]).map { (F.i($0[0]), F.d($0[1])) })
            let want = (c["expected"] as! [[String: Any]]).map { Turns.Turn(speaker: F.i($0["speaker"]), start: F.d($0["start"]), end: F.d($0["end"]), text: $0["text"] as! String) }
            #expect(Turns.build(tracks, offsets: offsets) == want, Comment(rawValue: c["name"] as! String))
        }
    }

    @Test func alignWordsMatchesPython() throws {
        let cases = try F.json("turns")["align"] as! [[String: Any]]
        #expect(cases.count > 300)
        for c in cases {
            let raw = (c["raw"] as! [[Any]]).map { (word: $0[0] as! String, start: F.d($0[1]), end: F.d($0[2])) }
            let want = F.words(c["expected"])
            #expect(Turns.align(raw, c["text"] as! String) == want, Comment(rawValue: c["name"] as! String))
        }
    }

    @Test func sequenceMatcherMatchesDifflibOnAmbiguousInput() {
        // difflib (autojunk=False) on a=[a b a b], b=[b a]: longest match is a[0:2]? no: leftmost-longest -> ("b a") at a[1:3]
        let ops = SequenceMatcher(["a", "b", "a", "b"], ["b", "a"]).opcodes().map { "\($0.tag) \($0.a0) \($0.a1) \($0.b0) \($0.b1)" }
        #expect(ops == ["delete 0 1 0 0", "equal 1 3 0 2", "delete 3 4 2 2"])
    }

    @Test func buildTurnsEdges() {
        #expect(Turns.build([]).isEmpty)
        #expect(Turns.build([(0, [])], offsets: [0: 5]).isEmpty)
        let w = Turns.Word(text: "hi", start: 0, end: 0)
        #expect(Turns.build([(7, [w])]) == [Turns.Turn(speaker: 7, start: 0, end: 0, text: "hi")])
    }
}
