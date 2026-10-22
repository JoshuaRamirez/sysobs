import XCTest
@testable import SysObsCore

final class FormatTests: XCTestCase {
    func testBytesFollowsSysobsHuman() {
        XCTAssertEqual(Format.bytes(512), "512B")
        XCTAssertEqual(Format.bytes(1024), "1.0K")
        XCTAssertEqual(Format.bytes(28_645_457_920), "26.7G")
        XCTAssertEqual(Format.bytes(137_438_953_472), "128.0G")
        XCTAssertEqual(Format.bytes(17_592_186_044_416), "16.0T")
        XCTAssertEqual(Format.bytes(nil), "-")
    }

    func testPercentAndNumbers() {
        XCTAssertEqual(Format.percent(54.23), "54.2%")
        XCTAssertEqual(Format.percent(100), "100%")
        XCTAssertEqual(Format.percent(0), "0%")
        XCTAssertEqual(Format.percent(nil), "-")
        XCTAssertEqual(Format.number(316.14), "316.14")
        XCTAssertEqual(Format.number(54), "54")
        XCTAssertEqual(Format.number(0.5), "0.5")
        XCTAssertEqual(Format.load([218.15, 104.67, 54.24]), "218.15 104.67 54.24")
        XCTAssertEqual(Format.load([316.14, 245.65, 135.3]), "316.14 245.65 135.3")
    }

    func testShortCommandCutsThePathToItsName() {
        XCTAssertEqual(Format.shortCommand("/opt/homebrew/bin/Python -I /tmp/x2045/bin/scan.py"), "Python -I /tmp/x2045/bin/scan.py")
        XCTAssertEqual(Format.shortCommand("/System/Library/XprotectService"), "XprotectService")
        XCTAssertEqual(Format.shortCommand("sleep 2"), "sleep 2")
        XCTAssertEqual(Format.shortCommand(""), "")
        let long = "/Applications/Ollama.app/Contents/Resources/llama-server --model /Users/joshua/.ollama/models/blobs/sha256-dfd98d --port 62600"
        let cut = Format.shortCommand(long, width: 40)
        XCTAssertEqual(cut.count, 40)
        XCTAssertTrue(cut.hasPrefix("llama-server --model"))
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    func testBasename() {
        XCTAssertEqual(Format.basename("/bin/zsh"), "zsh")
        XCTAssertEqual(Format.basename("/Users/joshua/.local/share/claude/versions/2.1.304"), "2.1.304")
        XCTAssertEqual(Format.basename("codex"), "codex")
        XCTAssertEqual(Format.basename(""), "")
    }
}

final class TimeFormatTests: XCTestCase {
    func testParsesBothStampShapes() throws {
        let plain = try XCTUnwrap(TimeFormat.parse("2026-10-22T07:32:14Z"))
        let fraction = try XCTUnwrap(TimeFormat.parse("2026-10-22T07:37:13.842Z"))
        XCTAssertEqual(fraction.timeIntervalSince(plain), 299.842, accuracy: 0.001)
        XCTAssertNil(TimeFormat.parse("yesterday"))
        XCTAssertNil(TimeFormat.parse(""))
    }

    func testRelativeAndClock() throws {
        let at = try XCTUnwrap(TimeFormat.parse("2026-10-22T07:32:14Z"))
        XCTAssertEqual(TimeFormat.relative(at, now: at.addingTimeInterval(30)), "just now")
        XCTAssertEqual(TimeFormat.relative(at, now: at.addingTimeInterval(200)), "3 min ago")
        XCTAssertEqual(TimeFormat.relative(at, now: at.addingTimeInterval(7200)), "2 h ago")
        XCTAssertEqual(TimeFormat.relative(at, now: at.addingTimeInterval(3 * 86400)), "3 d ago")
        XCTAssertEqual(TimeFormat.relative(at, now: at.addingTimeInterval(-120)), "in 2 min")
        XCTAssertEqual(TimeFormat.clock(at, timeZone: TimeZone(identifier: "UTC")!), "07:32")
        XCTAssertEqual(TimeFormat.clock(at, timeZone: TimeZone(identifier: "America/Chicago")!), "02:32")
    }

    func testIntervalsAndDurations() {
        XCTAssertEqual(TimeFormat.interval(seconds: 30), "30 s")
        XCTAssertEqual(TimeFormat.interval(seconds: 90), "90 s")
        XCTAssertEqual(TimeFormat.interval(seconds: 300), "5 min")
        XCTAssertEqual(TimeFormat.duration(ms: 150), "150 ms")
        XCTAssertEqual(TimeFormat.duration(ms: 1982), "2.0 s")
        XCTAssertEqual(TimeFormat.duration(ms: 5802), "5.8 s")
        XCTAssertEqual(TimeFormat.duration(ms: 150_737), "2 min")
        XCTAssertEqual(TimeFormat.duration(ms: 7_200_000), "2 h")
    }
}
