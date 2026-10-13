import Foundation

// The voiceprint maths rename-speaker needs, from speakers.py (_unit, _blob, _vec, add_person, update_print), in float32 like numpy.
// Another area ports the full speaker maths later and may replace this.

enum StoreVoiceprint {
    /// speakers._blob: normalised, float32 bytes.
    static func blob(_ v: [Float]) -> Data { Voiceprints.unit(v).withUnsafeBufferPointer { Data(buffer: $0) } }

    /// speakers._vec: float32 array from a stored blob.
    static func vec(_ d: Data) throws -> [Float] {
        guard d.count % 4 == 0 else { throw StoreCrash(kind: "ValueError", message: "buffer size must be a multiple of element size") }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// speakers.add_person: a person with an optional first voiceprint (n = 1).
    @discardableResult static func addPerson(_ db: StoreDB, name: String, embedding: [Float]?, isMe: Bool = false) throws -> Int {
        try db.run("INSERT INTO people(name, email, is_me, voiceprint, n, updated) VALUES (?,?,?,?,?,?)",
                   [name, nil, isMe ? 1 : 0, embedding.map(blob), embedding == nil ? 0 : 1, StoreClock.now()])
        return db.lastInsertID
    }

    /// speakers.update_print: the running mean is `Voiceprints.updatePrint` (one implementation); this loads the row and writes it back.
    /// Callers must not pass embeddings from a bleed-contaminated mic track.
    static func update(_ db: StoreDB, personID: Int, embedding: [Float], weight: Int = 1) throws {
        guard let row = try db.rows("SELECT voiceprint, n FROM people WHERE id = ?", [personID]).first else {
            throw StoreCrash(kind: "KeyError", message: "'no person \(personID)'")
        }
        let n = row.int(1) ?? 0
        var person = Voiceprints.Person(id: personID, name: "", voiceprint: try row.data(0).map(vec), n: n)
        if let old = person.voiceprint, n > 0, old.count != embedding.count {  // numpy raises on mismatched shapes; updatePrint would silently replace
            throw StoreCrash(kind: "ValueError", message: "operands could not be broadcast together with shapes (\(old.count),) (\(embedding.count),) ")
        }
        Voiceprints.updatePrint(&person, embedding, weight: weight)
        // the stored print is updatePrint's, already normalised the way _blob would
        let bytes = (person.voiceprint ?? embedding).withUnsafeBufferPointer { Data(buffer: $0) }
        try db.run("UPDATE people SET voiceprint = ?, n = ?, updated = ? WHERE id = ?", [bytes, person.n, StoreClock.now(), personID])
    }
}
