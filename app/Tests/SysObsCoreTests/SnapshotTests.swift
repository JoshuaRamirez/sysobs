import XCTest
@testable import SysObsCore

/// Fixtures cut from a real store (2026-10-22): the `snapshot` and `host_sample` tables and `sysobs show --json`.
enum StoreFixtures {
    static let snapshotHeader = "snapshot_id,host_id,started_at,finished_at,duration_ms,tool_version,schema_version,euid,privileged,files_mode,note"
    static let snapshotRows = """
    s_20261022T073214Z,h_3ee3f7790b430774,2026-10-22T07:32:14Z,2026-10-22T07:32:20Z,5802,0.3.0,1,501,0,none,substrate
    s_20261022T073714Z,h_3ee3f7790b430774,2026-10-22T07:37:14Z,2026-10-22T07:37:20Z,6420,0.3.0,1,501,0,none,"a note, with a comma"

    """
    static let hostHeader = "snapshot_id,uptime_s,load1,load5,load15,cpu_user_pct,cpu_sys_pct,cpu_idle_pct,procs_total,procs_running,procs_sleeping,threads_total,mem_total_bytes,mem_used_bytes,mem_unused_bytes,mem_wired_bytes,mem_compressed_bytes,mem_active_bytes,mem_inactive_bytes,mem_free_bytes,mem_speculative_bytes,mem_purgeable_bytes,page_size,pageins,pageouts,swapins,swapouts,swap_total_bytes,swap_used_bytes,swap_free_bytes,net_pkts_in,net_pkts_out,net_bytes_in,net_bytes_out,disk_reads,disk_writes,disk_bytes_read,disk_bytes_written"
    static let hostRow = "s_20261022T073714Z,356470,316.14,245.65,135.3,54.8,23.56,21.63,1854,171,1683,8983,137438953472,136365211648,246415360,37326143488,8495136768,45009698816,44904448000,307347456,91176960,156844032,16384,895727938,540984,3047167,3562583,4294967296,3306223042,988744253,201807786,187637982,454192791552,432717955072,1060436231,166879640,17592186044416,6318970634240"

    static let showJSON = """
    {
      "snapshot": {"snapshot_id": "s_20261022T073214Z", "host_id": "h_3ee3f7790b430774", "started_at": "2026-10-22T07:32:14Z",
                   "finished_at": "2026-10-22T07:32:20Z", "duration_ms": "5802", "tool_version": "0.3.0", "schema_version": "1",
                   "euid": "501", "privileged": "0", "files_mode": "none", "note": "substrate"},
      "host": {"hostname": "Mac.lan", "ncpu": "16"},
      "host_sample": {"snapshot_id": "s_20261022T073214Z", "uptime_s": "356170", "load1": "218.15", "load5": "104.67", "load15": "54.24",
                      "cpu_user_pct": "54.23", "cpu_sys_pct": "21.69", "cpu_idle_pct": "24.6", "procs_total": "1847", "threads_total": "9028",
                      "mem_total_bytes": "137438953472", "mem_used_bytes": "135291469824", "mem_wired_bytes": "36939186176",
                      "mem_compressed_bytes": "8480997376", "mem_free_bytes": "236388352",
                      "swap_total_bytes": "4294967296", "swap_used_bytes": "3314611650", "swap_free_bytes": "980355645"},
      "collectors": [], "row_counts": {}, "volumes": []
    }
    """
}

final class CSVTests: XCTestCase {
    func testFieldsHandleQuotesAndEscapedQuotes() {
        XCTAssertEqual(CSV.fields("a,b,c"), ["a", "b", "c"])
        XCTAssertEqual(CSV.fields("a,\"b, with comma\",c"), ["a", "b, with comma", "c"])
        XCTAssertEqual(CSV.fields("a,\"say \"\"hi\"\"\",c"), ["a", "say \"hi\"", "c"])
        XCTAssertEqual(CSV.fields("a,,c\r"), ["a", "", "c"])
        XCTAssertEqual(CSV.fields(""), [""])
    }

    func testLastRowTakesTheLastCompleteLine() throws {
        let row = try XCTUnwrap(CSV.lastRow(header: StoreFixtures.snapshotHeader, tail: StoreFixtures.snapshotRows, tailBeginsMidLine: false))
        XCTAssertEqual(row["snapshot_id"], "s_20261022T073714Z")
        XCTAssertEqual(row["note"], "a note, with a comma")
        XCTAssertEqual(row["duration_ms"], "6420")
    }

    func testLastRowDropsATornLastLineAndAMidLineFragment() throws {
        let torn = StoreFixtures.snapshotRows + "s_20261022T074214Z,h_3ee3f7790b430774,2026-10-22T07:42:14Z,2026-10-22T07:4"
        let row = try XCTUnwrap(CSV.lastRow(header: StoreFixtures.snapshotHeader, tail: torn, tailBeginsMidLine: false))
        XCTAssertEqual(row["snapshot_id"], "s_20261022T073714Z", "the line still being written is not a row")
        let fragment = "4,none,substrate\n" + StoreFixtures.snapshotRows
        let row2 = try XCTUnwrap(CSV.lastRow(header: StoreFixtures.snapshotHeader, tail: fragment, tailBeginsMidLine: true))
        XCTAssertEqual(row2["snapshot_id"], "s_20261022T073714Z")
    }

    func testLastRowSkipsAColumnShiftedRow() throws {
        let shifted = StoreFixtures.snapshotRows + "h_3ee3f7790b430774,2026-10-22T07:42:14Z,2026-10-22T07:42:20Z,5000,0.3.0,1,501,0,none,x\n"
        let row = try XCTUnwrap(CSV.lastRow(header: StoreFixtures.snapshotHeader, tail: shifted, tailBeginsMidLine: false))
        XCTAssertEqual(row["snapshot_id"], "s_20261022T073714Z", "a row one column short is a defect, not the latest snapshot")
        XCTAssertNil(CSV.lastRow(header: StoreFixtures.snapshotHeader, tail: "", tailBeginsMidLine: false))
        XCTAssertNil(CSV.lastRow(header: StoreFixtures.snapshotHeader, tail: StoreFixtures.snapshotHeader + "\n", tailBeginsMidLine: false),
                     "a header alone is an empty table")
    }

    func testLastRowOfFileReadsOnlyTheTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sysobs-csv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("snapshot.csv")
        var text = StoreFixtures.snapshotHeader + "\n"
        for i in 0..<2000 {
            text += "s_2026\(String(format: "%04d", i)),h_1,2026-10-22T07:32:14Z,2026-10-22T07:32:20Z,\(i),0.3.0,1,501,0,none,n\n"
        }
        text += StoreFixtures.snapshotRows
        try text.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 16 * 1024)
        let row = try XCTUnwrap(CSV.lastRow(of: url, tailBytes: 1024))
        XCTAssertEqual(row["snapshot_id"], "s_20261022T073714Z")
        XCTAssertNil(CSV.lastRow(of: dir.appendingPathComponent("missing.csv")))
    }
}

final class SnapshotTests: XCTestCase {
    func testSnapshotRowFromTheTable() throws {
        let row = try XCTUnwrap(CSV.lastRow(header: StoreFixtures.snapshotHeader, tail: StoreFixtures.snapshotRows, tailBeginsMidLine: false))
        let s = try XCTUnwrap(SnapshotRow(row: row))
        XCTAssertEqual(s.id, "s_20261022T073714Z")
        XCTAssertEqual(s.startedAt, TimeFormat.parse("2026-10-22T07:37:14Z"))
        XCTAssertEqual(s.durationMs, 6420)
        XCTAssertEqual(s.filesMode, "none")
        XCTAssertNil(SnapshotRow(row: ["snapshot_id": "s_1"]), "no started_at, no row")
        XCTAssertNil(SnapshotRow(row: ["started_at": "2026-10-22T07:37:14Z"]), "no id, no row")
    }

    func testHostPictureFromTheTable() throws {
        let row = try XCTUnwrap(CSV.lastRow(header: StoreFixtures.hostHeader, tail: StoreFixtures.hostRow + "\n", tailBeginsMidLine: false))
        let p = try XCTUnwrap(HostPicture(row: row))
        XCTAssertEqual(p.snapshotId, "s_20261022T073714Z")
        XCTAssertEqual(p.load, [316.14, 245.65, 135.3])
        XCTAssertEqual(p.cpuUserPct, 54.8)
        XCTAssertEqual(p.memTotal, 137_438_953_472)
        XCTAssertEqual(p.swapUsed, 3_306_223_042)
        XCTAssertEqual(p.loadLine, "Load 316.14 245.65 135.3 · 1854 processes · 8983 threads")
        XCTAssertEqual(p.cpuLine, "CPU 54.8% user · 23.6% sys · 21.6% idle")
        XCTAssertEqual(p.memoryLine, "Memory 127.0G of 128.0G · 34.8G wired · 7.9G compressed")
        XCTAssertEqual(p.swapLine, "Swap 3.1G of 4.0G")
    }

    func testHostPictureFromShowJSON() throws {
        let (snap, pic) = ShowPayload.parse(Data(StoreFixtures.showJSON.utf8))
        XCTAssertEqual(snap?.id, "s_20261022T073214Z")
        XCTAssertEqual(snap?.durationMs, 5802)
        let p = try XCTUnwrap(pic)
        XCTAssertEqual(p.load, [218.15, 104.67, 54.24])
        XCTAssertEqual(p.cpuLine, "CPU 54.2% user · 21.7% sys · 24.6% idle")
        XCTAssertEqual(p.memoryLine, "Memory 126.0G of 128.0G · 34.4G wired · 7.9G compressed")
        XCTAssertEqual(p.swapLine, "Swap 3.1G of 4.0G")
        XCTAssertEqual(p.procsTotal, 1847)
    }

    func testEmptyColumnsAreAbsentNotZero() throws {
        let p = try XCTUnwrap(HostPicture(row: ["snapshot_id": "s_1", "load1": "", "cpu_user_pct": "", "mem_used_bytes": ""]))
        XCTAssertEqual(p.load, [])
        XCTAssertNil(p.cpuUserPct)
        XCTAssertNil(p.memUsed)
        XCTAssertEqual(p.loadLine, "Load –")
        XCTAssertEqual(p.cpuLine, "CPU –")
        XCTAssertEqual(p.memoryLine, "Memory –")
        XCTAssertEqual(p.swapLine, "Swap –")
        XCTAssertNil(HostPicture(row: [:]))
        let (s, h) = ShowPayload.parse(Data("not json".utf8))
        XCTAssertNil(s); XCTAssertNil(h)
    }

    func testSnapshotResult() {
        let taken = Data(#"{"snapshot_id": "s_20261022T074514Z", "root": "/x", "written": {}, "events_ingested": 1203, "light": {}}"#.utf8)
        XCTAssertEqual(SnapshotResult.parse(taken, exitCode: 0), .taken(id: "s_20261022T074514Z", eventsIngested: 1203))
        XCTAssertEqual(SnapshotResult.parse(taken, exitCode: 0).note, "snapshot s_20261022T074514Z taken, 1203 events folded in")
        let skipped = Data(#"{"snapshot_id": null, "skipped": "full snapshot skipped: store lock held by pid 123", "light": {}}"#.utf8)
        XCTAssertEqual(SnapshotResult.parse(skipped, exitCode: 0), .skipped(reason: "full snapshot skipped: store lock held by pid 123"))
        XCTAssertEqual(SnapshotResult.parse(Data(), exitCode: 2, stderr: "usage: sysobs\nsysobs: error: bad flag"),
                       .failed(message: "exit 2: sysobs: error: bad flag"))
        XCTAssertEqual(SnapshotResult.parse(Data("{}".utf8), exitCode: 0), .failed(message: "no snapshot id in the output"))
    }
}
