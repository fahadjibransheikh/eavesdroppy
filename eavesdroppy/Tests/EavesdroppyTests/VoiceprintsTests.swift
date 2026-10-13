import Foundation
import Testing
@testable import Eavesdroppy

@Suite struct VoiceprintsTests {
    typealias F = LogicFixture
    typealias V = Voiceprints

    // Cosines are float32 dot products (BLAS in numpy, vDSP here), so scores differ by ~1e-7 before rounding to 4
    // places; 2e-4 covers a one-unit flip in the 4th decimal. The generator rejects scenarios with a score within
    // 2e-3 of a threshold, so decisions (kind, person, label) are compared exactly.
    let scoreTol = 2e-4
    // Voiceprint vectors after running-mean updates: a few float32 ulps from summation order.
    let vecTol: Float = 1e-5

    func person(_ x: Any) -> V.Person {
        let p = x as! [String: Any]
        return V.Person(id: F.i(p["id"]), name: p["name"] as! String, email: p["email"] as? String, isMe: F.b(p["is_me"]),
                        voiceprint: p["voiceprint"] is NSNull ? nil : F.f(p["voiceprint"]), n: F.i(p["n"]))
    }
    func people(_ x: Any?) -> [V.Person] { (x as! [Any]).map(person) }
    func diar(_ x: Any) -> V.Diarization {
        let d = x as! [String: Any]
        return V.Diarization(segments: (d["segments"] as! [[Any]]).map { V.Segment(start: F.d($0[0]), end: F.d($0[1]), cluster: $0[2] as! String) },
                             embeddings: (d["embeddings"] as! [[Any]]).map { V.ClusterEmbedding(cluster: $0[0] as! String, vector: F.f($0[1])) })
    }
    func rec(_ x: Any) -> V.Rec {
        let r = x as! [String: Any]
        return V.Rec(track: r["track"] as! String, clusterID: r["cluster_id"] as? String, label: r["label"] as! String,
                     personID: r["person_id"] as? Int, score: F.d(r["score"]), kind: V.Kind(rawValue: r["kind"] as! String)!,
                     embedding: F.b(r["has_embedding"]) ? [] : nil, speechS: F.d(r["speech_s"]), namedBy: r["named_by"] as? String)
    }
    func close(_ a: [Float]?, _ b: [Float]?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= vecTol }
    }
    func same(_ got: [V.Rec], _ want: [V.Rec], _ name: String) {
        #expect(got.count == want.count, Comment(rawValue: name))
        for (g, w) in zip(got, want) {
            #expect(g.track == w.track && g.clusterID == w.clusterID && g.label == w.label && g.personID == w.personID && g.kind == w.kind
                    && g.speechS == w.speechS && g.namedBy == w.namedBy && (g.embedding != nil) == (w.embedding != nil)
                    && abs(g.score - w.score) <= scoreTol, Comment(rawValue: "\(name): \(g) vs \(w)"))
        }
    }

    @Test func matchMatchesPython() throws {
        let cases = try F.json("voiceprints")["match"] as! [[String: Any]]
        #expect(cases.count > 100)
        for (n, c) in cases.enumerated() {
            let want = c["expected"] as! [String: Any]
            let got = V.match(F.f(c["query"]), people(c["people"]), includeMe: F.b(c["include_me"]))
            #expect(got.personID == want["person_id"] as? Int && got.kind.rawValue == want["kind"] as! String && abs(got.score - F.d(want["score"])) <= scoreTol, "match \(n): \(got) vs \(want)")
        }
    }

    @Test func updatePrintMatchesPython() throws {
        for (n, c) in (try F.json("voiceprints")["update"] as! [[String: Any]]).enumerated() {
            var p = person(c["start"]!)
            for (k, s) in (c["steps"] as! [[String: Any]]).enumerated() {
                V.updatePrint(&p, F.f(s["embedding"]), weight: F.i(s["weight"]))
                let want = person(s["after"]!)
                #expect(p.n == want.n && close(p.voiceprint, want.voiceprint), "update \(n) step \(k)")
            }
        }
    }

    @Test func assignSpeakersMatchesPython() throws {
        let cases = try F.json("voiceprints")["assign"] as! [[String: Any]]
        #expect(cases.count > 100)
        var kinds = Set<V.Kind>()
        for c in cases {
            let name = c["name"] as! String
            let tracks = Dictionary(uniqueKeysWithValues: (c["tracks"] as! [[Any]]).map { ($0[0] as! String, diar($0[1])) })
            var ppl = people(c["people"])
            let bleed = F.b(c["bleed"])
            let got = V.assignSpeakers(tracks, people: &ppl, source: c["source"] as! String, bleed: bleed, update: F.b(c["update"]))
            same(got, (c["recs"] as! [Any]).map(rec), name)
            kinds.formUnion(got.map(\.kind))
            let learn = V.learnable(got, bleed: bleed), want = c["learnable"] as! [[Any]]
            #expect(learn.count == want.count && zip(learn, want).allSatisfy { $0.personID == F.i($1[0]) && close($0.embedding, F.f($1[1])) }, Comment(rawValue: "\(name): learnable"))
            let after = people(c["people_after"])
            #expect(ppl.count == after.count && zip(ppl, after).allSatisfy { $0.id == $1.id && $0.n == $1.n && close($0.voiceprint, $1.voiceprint) }, Comment(rawValue: "\(name): people after"))
        }
        #expect(kinds.isSuperset(of: [.me, .assumed, .auto, .suggest, .new]))
    }

    @Test func meNeverLearnsFromBleedingMic() {
        let r = V.Rec(track: "mic", clusterID: "S1", label: "Me", personID: 1, score: 0.9, kind: .me, embedding: [1], speechS: 1)
        #expect(V.learnable([r], bleed: true).isEmpty)
        #expect(V.learnable([r], bleed: false).count == 1)
        var sys = r; sys.track = "system"
        #expect(V.learnable([sys], bleed: true).count == 1)
        var weak = r; weak.score = 0.7
        #expect(V.learnable([weak], bleed: false).isEmpty)  // "me" learns only at >= autoThr
    }

    @Test func wordsToSpeakersMatchesPython() throws {
        for (n, c) in (try F.json("voiceprints")["words_to_speakers"] as! [[String: Any]]).enumerated() {
            let segs = (c["segments"] as! [[Any]]).map { V.Segment(start: F.d($0[0]), end: F.d($0[1]), cluster: $0[2] as! String) }
            let want = (c["expected"] as! [Any]).map { $0 as? String }
            #expect(V.wordsToSpeakers(F.words(c["words"]), segs) == want, "words \(n)")
        }
    }

    @Test func namingPromptMatchesPython() throws {
        for c in try F.json("voiceprints")["prompts"] as! [[String: Any]] {
            let snippets = Dictionary(uniqueKeysWithValues: F.pairs(c["snippets"]).map { ($0.0, $0.1 as! [String]) })
            let got = V.buildNamingPrompt((c["clusters"] as! [Any]).map(rec), attendees: c["attendees"] as! [String], snippets: snippets)
            #expect(got == c["expected"] as! String, Comment(rawValue: c["name"] as! String))
        }
    }

    @Test func parseNamingReplyMatchesPython() throws {
        for c in try F.json("voiceprints")["parse_reply"] as! [[String: Any]] {
            let got = V.parseNamingReply(c["text"] as! String, allowed: c["allowed"] as? [String]).map { [$0.key, $0.name] }
            #expect(got == (c["expected"] as! [[String]]), Comment(rawValue: c["name"] as! String))
        }
    }

    @Test func applyNamesMatchesPython() throws {
        for c in try F.json("voiceprints")["apply_names"] as! [[String: Any]] {
            let names = F.pairs(c["names"]).map { (key: $0.0, name: $0.1 as! String) }
            same(V.applyNames((c["clusters"] as! [Any]).map(rec), names), (c["expected"] as! [Any]).map(rec), "apply_names")
        }
    }

    @Test func assembleMatchesPython() throws {
        let cases = try F.json("voiceprints")["assemble"] as! [[String: Any]]
        #expect(cases.count > 50)
        var prompts = 0
        for c in cases {
            let name = c["name"] as! String
            let words = (c["words_by_track"] as! [[Any]]).map { (track: $0[0] as! String, words: F.words($0[1])) }
            let diars = Dictionary(uniqueKeysWithValues: (c["diar_by_track"] as! [[Any]]).compactMap { p in p[1] is NSNull ? nil : (p[0] as! String, diar(p[1])) })
            let offsets = Dictionary(uniqueKeysWithValues: F.pairs(c["offsets"]).map { ($0.0, F.d($0.1)) })
            let labels = Dictionary(uniqueKeysWithValues: F.pairs(c["labels"]).map { ($0.0, $0.1 as! String) })
            var a = Turns.assemble(wordsByTrack: words, diarByTrack: diars, people: people(c["people"]), attendees: c["attendees"] as! [String],
                                   source: c["source"] as! String, bleed: F.b(c["bleed"]), offsets: offsets, labels: labels,
                                   participants: c["participants"] as! [String], autoNaming: F.b(c["auto_naming"]), userName: c["user_name"] as! String)
            let want = c["expected"] as! [String: Any]
            #expect(a.prompt == (want["prompt"] as? String ?? ""), Comment(rawValue: "\(name): prompt"))
            if let cands = want["candidates"] as? [String] { #expect(a.candidates == cands, Comment(rawValue: "\(name): candidates")) }
            let turns = (want["turns"] as! [[String: Any]]).map { Turns.Turn(speaker: F.i($0["speaker"]), start: F.d($0["start"]), end: F.d($0["end"]), text: $0["text"] as! String) }
            #expect(a.turns == turns, Comment(rawValue: "\(name): turns"))
            if !a.prompt.isEmpty, let reply = c["reply"] as? String {
                prompts += 1
                a.recs = Turns.applyNaming(a.recs, reply: reply, allowed: a.candidates)
            }
            same(a.recs, (want["recs"] as! [Any]).map(rec), name)
        }
        #expect(prompts > 3)
    }

    @Test func jsonDumpsMatchesPythonEnsureAscii() {
        let want = "[\"a\\\"b\", \"\\u00fc\", \"\\ud83d\\ude00\", \"\\u007f\", \"x\\ny\"]"
        #expect(V.jsonDumps(["a\"b", "ü", "😀", "\u{7f}", "x\ny"]) == want)
        #expect(V.jsonDumps([]) == "[]")
    }
}
