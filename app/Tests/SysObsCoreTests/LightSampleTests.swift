import XCTest
@testable import SysObsCore

final class LightSampleTests: XCTestCase {
    /// Two ticks of `sysobs light --since 1h --by cpu -n 2 --json`, cut from a real run (2026-10-22).
    static let fixture = """
    [
      {"ts": "2026-10-22T07:32:13.611Z", "load": [218.15, 104.67, 54.24], "cores": 16, "status": "ok", "boost": "",
       "processes": 1847, "cpu_pct_total": 802.1,
       "top": [{"pid": 64015, "ppid": 3638, "cpu_pct": 171.2, "rss_kb": 27974080, "elapsed_s": 481, "command": "/Applications/Ollama.app/Contents/Resources/llama-server --model x"},
               {"pid": 3553, "ppid": 1, "cpu_pct": 50.1, "rss_kb": 53920, "elapsed_s": 355892, "command": "/System/Library/PrivateFrameworks/XprotectFramework.framework/Versions/A/XPCServices/XprotectService.xpc/Contents/MacOS/XprotectService"}]},
      {"ts": "2026-10-22T07:37:13.842Z", "load": [316.14, 245.65, 135.3], "cores": 16, "status": "ok",
       "boost": "priority raised: load 316.14 > 2 x 16 cores", "processes": 1899, "cpu_pct_total": 883.8,
       "top": [{"pid": 64015, "ppid": 3638, "cpu_pct": 187.7, "rss_kb": 27974080, "elapsed_s": 781, "command": "/Applications/Ollama.app/Contents/Resources/llama-server --model x"},
               {"pid": 36940, "ppid": 36937, "cpu_pct": 49.3, "rss_kb": 25296, "elapsed_s": 294, "command": "/Applications/Xcode.app/Contents/Developer/usr/bin/git -C /Users/jsmith/Obsidian/notes log --all -p"}]}
    ]
    """

    func testParsesEveryTickOldestFirst() throws {
        let samples = LightSample.parse(Data(Self.fixture.utf8))
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].processes, 1847)
        XCTAssertEqual(samples[0].load, [218.15, 104.67, 54.24])
        XCTAssertEqual(samples[0].cores, 16)
        XCTAssertEqual(samples[0].top.map(\.pid), [64015, 3553])
        XCTAssertEqual(samples[0].top[1].elapsedS, 355892)
        XCTAssertEqual(samples[0].top[1].ppid, 1)
    }

    func testLatestIsTheNewestTick() throws {
        let latest = try XCTUnwrap(LightSample.latest(Data(Self.fixture.utf8)))
        XCTAssertEqual(latest.at, TimeFormat.parse("2026-10-22T07:37:13.842Z"))
        XCTAssertEqual(latest.cpuPctTotal, 883.8)
        XCTAssertEqual(latest.top.count, 2)
        XCTAssertEqual(latest.top[0].cpuPct, 187.7)
        XCTAssertEqual(latest.top[0].rssKB, 27_974_080)
    }

    func testMenuLines() throws {
        let latest = try XCTUnwrap(LightSample.latest(Data(Self.fixture.utf8)))
        XCTAssertEqual(latest.top[0].line(by: .cpu), "187.7%  llama-server --model x")
        XCTAssertEqual(latest.top[0].line(by: .rss), "26.7G  llama-server --model x")
        XCTAssertEqual(latest.top[1].line(by: .cpu, width: 30), "49.3%  git -C /Users/jsmith/Obsidian…")
    }

    func testBadInputIsEmpty() {
        XCTAssertEqual(LightSample.parse(Data()), [])
        XCTAssertEqual(LightSample.parse(Data("{}".utf8)), [])
        XCTAssertEqual(LightSample.parse(Data(#"[{"load": [1]}]"#.utf8)), [], "a tick without a stamp is not a sample")
        XCTAssertNil(LightSample.latest(Data("[]".utf8)))
    }

    func testArguments() {
        XCTAssertEqual(LightSample.arguments(by: .cpu, count: 5), ["light", "--since", "1h", "--by", "cpu", "-n", "5", "--json"])
        XCTAssertEqual(LightSample.arguments(by: .rss, count: 8, since: "30m"), ["light", "--since", "30m", "--by", "rss", "-n", "8", "--json"])
    }
}
