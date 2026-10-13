import Foundation
import Testing
@testable import Eavesdroppy

/// Regression: `delete` (and expire-audio) with the Drive mount missing. The database row is already gone when the files are
/// removed, so an unreachable Drive must be a warning ("failed": the file may still be there), never a failed command.
/// The mount below does not exist on any Mac; nothing is created under CloudStorage.
@Suite struct DriveOfflineTests {
    static let mount = PyPath.home + "/Library/CloudStorage/GoogleDrive-eavesdroppy-test-absent@example.invalid"
    static let outRoot = mount + "/My Drive/Meetings"

    @Test func deleteWithTheDriveOfflineWarnsAndSucceeds() throws {
        let s = try Scratch(); defer { s.remove() }
        precondition(!FileManager.default.fileExists(atPath: Self.mount))
        let db = try StoreDB(path: s.container.appendingPathComponent("library.db"))
        let folder = Self.outRoot + "/2020-05-01 1000 – Ghost"
        let id = try StoreLibrary.addMeeting(db, NewMeeting(title: "Ghost", start: "2020-05-01T10:00:00+05:00", folder: folder, audioPath: folder + "/a.m4a"))
        db.close()
        var warnings: [String] = []
        let out = try StoreCommands.run(["delete", String(id), "--out-root", Self.outRoot], container: s.container, outRoot: nil) { warnings.append($0) }
        #expect(String(decoding: out, as: UTF8.self) == #"{"ok":true}"#)
        let after = try StoreDB(path: s.container.appendingPathComponent("library.db")); defer { after.close() }
        #expect(try after.rows("SELECT COUNT(*) FROM meetings")[0].int(0) == 0)
        #expect(warnings.count == 2, "\(warnings)")
        #expect(warnings.allSatisfy { $0.hasPrefix("Could not delete \(Self.outRoot)") && $0.contains(": Drive folder not available: \(Self.outRoot)") }, "\(warnings)")
        #expect(!FileManager.default.fileExists(atPath: Self.mount), "nothing was created under CloudStorage")
    }

    @Test func removePathReportsFailedNotAbsentForAnUnreachableDrive() throws {
        var warnings: [String] = []
        let r = try StoreMirror.removePath(Self.outRoot + "/x/a.m4a", roots: [Self.outRoot]) { warnings.append($0) }
        #expect(r == "failed"); #expect(warnings.count == 1)
        let gone = try StoreMirror.removePath(NSTemporaryDirectory() + "no-such-\(UUID().uuidString)", roots: [NSTemporaryDirectory()]) { _ in }
        #expect(gone == "absent", "an ordinary missing file is still absent")
    }
}
