import XCTest
@testable import SysObsCore

final class ProcessEventTests: XCTestCase {
    /// Lines of a real `spool/procwatch-20261022T03.ndjson`, plus a torn last line.
    static let spool = """
    {"ts":"2026-10-22T02:59:59.814Z","event":"start","pid":97234,"ppid":82943,"uid":501,"exe":"/Applications/iTerm.app/Contents/Resources/utilities/cc-status","argv":"/Users/joshua/.config/iterm2/cc-status","parent_exe":"/Users/joshua/.local/share/claude/versions/2.1.304","parent_argv":"/Users/joshua/.local/bin/claude","started_at":"2026-10-22T02:59:59.602Z","lifetime_ms":"","source":"procwatch-1000ms"}
    {"ts":"2026-10-22T02:59:59.814Z","event":"exit","pid":97036,"ppid":82943,"uid":501,"exe":"/Applications/iTerm.app/Contents/Resources/utilities/cc-status","argv":"/Users/joshua/.config/iterm2/cc-status","parent_exe":"/Users/joshua/.local/share/claude/versions/2.1.304","parent_argv":"/Users/joshua/.local/bin/claude","started_at":"2026-10-22T02:59:58.610Z","lifetime_ms":1204,"source":"procwatch-1000ms"}
    {"ts":"2026-10-22T03:00:00.822Z","event":"start","pid":97336,"ppid":54693,"uid":501,"exe":"/bin/sleep","argv":"sleep 2","parent_exe":"/bin/zsh","parent_argv":"/bin/zsh -c sleep 2","started_at":"2026-10-22T03:00:00.430Z","lifetime_ms":"","source":"procwatch-1000ms"}
    {"ts":"2026-10-22T03:59:58.411Z","event":"exit","pid":99001,"ppid":1,"uid":0,"exe":"","argv":"","parent_exe":"","parent_argv":"","started_at":"2026-10-22T03:59:48.411Z","lifetime_ms":10000,"source":"procwatch-1000ms"}
    {"ts":"2026-10-22T03:59:59.900Z","event":"exit","pid":97336,"ppid":54693,"uid":501,"exe":"/bin/sl
    """

    /// `sysobs events --since 1h -n 2 --json --no-ingest`, cut from a real run.
    static let eventsJSON = """
    {"events": [
      {"event_id": "e_a177cb200169bab6", "ts": "2026-10-22T07:32:35.811Z", "event": "exit", "pid": "17018", "ppid": "17007", "uid": "501",
       "command_id": "c_07ac5237643243ab", "argv_id": "g_aa2acc4a0a239a9d", "parent_command_id": "c_c282af84b66d4689",
       "started_at": "2026-10-22T07:30:05.074Z", "lifetime_ms": "150737", "source": "procwatch-1000ms",
       "command": "it2", "parent": "cc-status", "argv": "/Applications/iTerm.app/Contents/Resources/utilities/it2 set-status"},
      {"event_id": "e_1888cbf3eb579958", "ts": "2026-10-22T07:32:36.000Z", "event": "start", "pid": "39034", "ppid": "35651", "uid": "501",
       "command_id": "c_243752d1f889e6d0", "argv_id": "g_5a3889e53dab089d", "parent_command_id": "",
       "started_at": "2026-10-22T07:32:34.376Z", "lifetime_ms": "", "source": "procwatch-1000ms",
       "command": "bash", "parent": "", "argv": "bash --noprofile --norc -c set -euo pipefail"}
    ], "ingested": 0}
    """

    func testSpoolLinesParseAndTheTornOneIsSkipped() throws {
        let events = ProcessEvent.parse(spool: Self.spool)
        XCTAssertEqual(events.count, 4, "the torn last line is not an event")
        XCTAssertEqual(events[0].kind, .start)
        XCTAssertEqual(events[0].pid, 97234)
        XCTAssertEqual(events[0].ppid, 82943)
        XCTAssertEqual(events[0].command, "cc-status")
        XCTAssertEqual(events[0].parent, "2.1.304")
        XCTAssertNil(events[0].lifetimeMs, "a start has no lifetime")
        XCTAssertEqual(events[1].kind, .exit)
        XCTAssertEqual(events[1].lifetimeMs, 1204)
        XCTAssertEqual(events[2].command, "sleep")
        XCTAssertEqual(events[2].argv, "sleep 2")
        XCTAssertEqual(events[3].command, "")
        XCTAssertEqual(events[3].name, "", "nothing known about the process stays empty, never invented")
    }

    func testEventsJSONParses() {
        let events = ProcessEvent.parse(eventsJSON: Data(Self.eventsJSON.utf8))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].kind, .exit)
        XCTAssertEqual(events[0].pid, 17018)
        XCTAssertEqual(events[0].command, "it2")
        XCTAssertEqual(events[0].parent, "cc-status")
        XCTAssertEqual(events[0].lifetimeMs, 150737)
        XCTAssertEqual(events[1].kind, .start)
        XCTAssertEqual(events[1].parent, "")
        XCTAssertNil(events[1].lifetimeMs)
        XCTAssertEqual(ProcessEvent.parse(eventsJSON: Data("[]".utf8)), [])
        XCTAssertEqual(ProcessEvent.parse(eventsJSON: Data()), [])
    }

    func testMenuLines() throws {
        let utc = TimeZone(identifier: "UTC")!
        let events = ProcessEvent.parse(spool: Self.spool)
        XCTAssertEqual(events[0].line(timeZone: utc), "02:59  started  cc-status ← 2.1.304")
        XCTAssertEqual(events[1].line(timeZone: utc), "02:59  exited  cc-status ← 2.1.304 · 1.2 s")
        XCTAssertEqual(events[2].line(timeZone: utc), "03:00  started  sleep ← zsh")
        let stored = ProcessEvent.parse(eventsJSON: Data(Self.eventsJSON.utf8))
        XCTAssertEqual(stored[0].line(timeZone: utc), "07:32  exited  it2 ← cc-status · 2 min")
        XCTAssertEqual(stored[1].line(timeZone: utc), "07:32  started  bash")
    }

    func testRecentKeepsTheWindowAndTheNewestN() throws {
        let events = ProcessEvent.parse(spool: Self.spool)
        let now = try XCTUnwrap(TimeFormat.parse("2026-10-22T04:00:00Z"))
        let lastHour = ProcessEvent.recent(events, now: now)
        XCTAssertEqual(lastHour.map(\.pid), [97336, 99001], "02:59 is more than an hour before 04:00")
        let two = ProcessEvent.recent(events, now: now, window: 7200, limit: 2)
        XCTAssertEqual(two.map(\.pid), [97336, 99001], "the newest two, oldest first")
        let all = ProcessEvent.recent(events.reversed(), now: now, window: 7200, limit: 10)
        XCTAssertEqual(all.map(\.pid), [97036, 97234, 97336, 99001], "sorted by time; the two with one stamp keep their input order")
        XCTAssertEqual(ProcessEvent.recent(events, now: now.addingTimeInterval(86400)), [])
    }

    func testArguments() {
        XCTAssertEqual(ProcessEvent.arguments(limit: 10), ["events", "--since", "1h", "-n", "10", "--json", "--no-ingest"])
    }

    func testSpoolFolderNewestFilesAndTails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sysobs-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = try XCTUnwrap(TimeFormat.parse("2026-10-22T04:00:00Z"))
        XCTAssertNil(Spool.recentEvents(in: dir, now: now), "no spool files: nil, so the caller falls back to sysobs events")
        XCTAssertNil(Spool.recentEvents(in: dir.appendingPathComponent("missing"), now: now))

        // three hourly files plus offsets.json; only the newest two are read, and only their tails
        let lines = Self.spool.split(separator: "\n").map(String.init)
        var old = ""
        for i in 0..<3000 { old += #"{"ts":"2026-10-22T01:00:00.000Z","event":"start","pid":\#(i),"exe":"/bin/old","argv":"old"}"# + "\n" }
        try old.write(to: dir.appendingPathComponent("procwatch-20261022T01.ndjson"), atomically: true, encoding: .utf8)
        try (lines[0] + "\n" + lines[1] + "\n").write(to: dir.appendingPathComponent("procwatch-20261022T02.ndjson"), atomically: true, encoding: .utf8)
        try (old + lines[2] + "\n" + lines[3] + "\n" + lines[4]).write(to: dir.appendingPathComponent("procwatch-20261022T03.ndjson"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("offsets.json"), atomically: true, encoding: .utf8)

        XCTAssertEqual(Spool.files(in: dir).map(\.lastPathComponent),
                       ["procwatch-20261022T01.ndjson", "procwatch-20261022T02.ndjson", "procwatch-20261022T03.ndjson"])
        // a tail that starts inside lines[2]: the fragment of lines[2] is dropped, lines[3] and the torn line remain
        let tail = Spool.tail(of: dir.appendingPathComponent("procwatch-20261022T03.ndjson"), tailBytes: lines[4].utf8.count + lines[3].utf8.count + 20)
        XCTAssertTrue(tail.hasPrefix(#"{"ts":"2026-10-22T03:59:58.411Z""#), "the tail begins after the first newline: the fragment of the line before is dropped")
        XCTAssertFalse(tail.contains(#""argv":"sleep 2""#), "lines[2] is before the cut")
        XCTAssertTrue(tail.contains(#""pid":99001"#))
        let recent = try XCTUnwrap(Spool.recentEvents(in: dir, now: now, limit: 10))
        XCTAssertEqual(recent.map(\.pid), [97336, 99001])
        let wide = try XCTUnwrap(Spool.recentEvents(in: dir, now: now.addingTimeInterval(-3000), limit: 3))
        XCTAssertEqual(wide.map(\.pid), [97036, 97336, 99001], "the hour before is read too, the newest three kept")
    }
}
