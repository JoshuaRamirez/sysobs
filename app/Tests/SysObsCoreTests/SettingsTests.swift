import XCTest
@testable import SysObsCore

final class SettingsTests: XCTestCase {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sysobs-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDefaults() throws {
        let s = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(s, .default)
        XCTAssertEqual(s.refreshSeconds, 30)
        XCTAssertEqual(s.topCount, 5)
    }

    func testDefaultsWhenMissingOrUnreadable() throws {
        let dir = try tempDir()
        XCTAssertEqual(Settings.load(from: dir.appendingPathComponent("nope/menu-bar.json")), .default)
        let p = dir.appendingPathComponent("menu-bar.json")
        try "not json".write(to: p, atomically: true, encoding: .utf8)
        XCTAssertEqual(Settings.load(from: p), .default)
    }

    func testOutOfRangeValuesAreClamped() throws {
        let low = try JSONDecoder().decode(Settings.self, from: Data(#"{"refresh_seconds":1,"top_count":0}"#.utf8))
        XCTAssertEqual(low.refreshSeconds, 5)
        XCTAssertEqual(low.topCount, 1)
        let high = try JSONDecoder().decode(Settings.self, from: Data(#"{"refresh_seconds":99999,"top_count":500}"#.utf8))
        XCTAssertEqual(high.refreshSeconds, 3600)
        XCTAssertEqual(high.topCount, 20)
        XCTAssertEqual(Settings(refreshSeconds: 0, topCount: 100), Settings(refreshSeconds: 5, topCount: 20))
    }

    func testSaveRoundTripUsesSnakeCaseKeys() throws {
        let dir = try tempDir()
        let p = dir.appendingPathComponent("sub/menu-bar.json")
        let s = Settings(refreshSeconds: 60, topCount: 8)
        try s.save(to: p)
        XCTAssertEqual(Settings.load(from: p), s)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: p)) as? [String: Any])
        XCTAssertEqual(obj["refresh_seconds"] as? Int, 60)
        XCTAssertEqual(obj["top_count"] as? Int, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.appendingPathExtension("tmp").path))
    }
}

final class PathsTests: XCTestCase {
    func testStoreRootResolution() {
        XCTAssertEqual(Paths.storeRoot(environment: [:]), Paths.home.appendingPathComponent(".local/state/sysobs"))
        XCTAssertEqual(Paths.storeRoot(environment: ["SYSOBS_HOME": "/Volumes/big/sysobs"]).path, "/Volumes/big/sysobs")
        XCTAssertEqual(Paths.storeRoot(environment: ["SYSOBS_HOME": "~/obs"]).path, Paths.home.appendingPathComponent("obs").path)
        XCTAssertEqual(Paths.storeRoot(environment: ["XDG_STATE_HOME": "/tmp/state"]).path, "/tmp/state/sysobs")
        XCTAssertEqual(Paths.storeRoot(environment: ["SYSOBS_HOME": "", "XDG_STATE_HOME": "/tmp/state"]).path, "/tmp/state/sysobs",
                       "an empty SYSOBS_HOME is unset")
        XCTAssertEqual(Paths.snapshotTable(in: URL(fileURLWithPath: "/s")).path, "/s/tables/snapshot.csv")
        XCTAssertEqual(Paths.hostSampleTable(in: URL(fileURLWithPath: "/s")).path, "/s/tables/host_sample.csv")
        XCTAssertEqual(Paths.spool(in: URL(fileURLWithPath: "/s")).path, "/s/spool")
    }

    func testFirstExecutablePrefersTheRepoThenTheInstalledCommand() {
        let repo = Paths.home.appendingPathComponent("Developer/sysobs/bin/sysobs")
        let installed = Paths.home.appendingPathComponent(".local/bin/sysobs")
        XCTAssertEqual(Paths.sysobsCandidates, [repo, installed])
        XCTAssertEqual(Paths.firstExecutable(isExecutable: { _ in true }), repo)
        XCTAssertEqual(Paths.firstExecutable(isExecutable: { $0 == installed }), installed)
        XCTAssertNil(Paths.firstExecutable(isExecutable: { _ in false }))
    }

    func testSearchPathPutsHomebrewFirstWithoutRepeats() {
        XCTAssertEqual(Paths.searchPath(from: nil), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(Paths.searchPath(from: "/usr/bin:/opt/homebrew/bin:/bin"), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
    }
}
