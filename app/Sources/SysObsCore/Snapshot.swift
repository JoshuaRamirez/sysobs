import Foundation

/// One `snapshot` row: when the latest full snapshot was taken and how long it took. The same keys as a row of
/// `tables/snapshot.csv` and as `sysobs show --json`'s `"snapshot"` object (every value a string).
public struct SnapshotRow: Equatable, Sendable {
    public var id: String
    public var startedAt: Date
    public var durationMs: Int?
    public var filesMode: String
    public var note: String

    public init?(row: [String: String]) {
        guard let id = row["snapshot_id"], !id.isEmpty,
              let at = row["started_at"].flatMap(TimeFormat.parse) else { return nil }
        self.id = id
        startedAt = at
        durationMs = row["duration_ms"].flatMap { Int($0) }
        filesMode = row["files_mode"] ?? ""
        note = row["note"] ?? ""
    }
}

/// The machine-wide picture of one snapshot: a `host_sample` row (`tables/host_sample.csv`, or `sysobs show --json`'s
/// `"host_sample"`). Strings in, numbers out; a column that is empty or absent is nil, never zero.
public struct HostPicture: Equatable, Sendable {
    public var snapshotId: String
    public var load: [Double]             // 1, 5, 15 min
    public var cpuUserPct: Double?
    public var cpuSysPct: Double?
    public var cpuIdlePct: Double?
    public var procsTotal: Int?
    public var threadsTotal: Int?
    public var memTotal: Int64?
    public var memUsed: Int64?
    public var memWired: Int64?
    public var memCompressed: Int64?
    public var memFree: Int64?
    public var swapTotal: Int64?
    public var swapUsed: Int64?

    public init?(row: [String: String]) {
        guard let sid = row["snapshot_id"], !sid.isEmpty else { return nil }
        func d(_ k: String) -> Double? { row[k].flatMap { Double($0) } }
        func i(_ k: String) -> Int? { row[k].flatMap { Int($0) } }
        func b(_ k: String) -> Int64? { row[k].flatMap { Int64($0) } }
        snapshotId = sid
        load = ["load1", "load5", "load15"].compactMap(d)
        cpuUserPct = d("cpu_user_pct"); cpuSysPct = d("cpu_sys_pct"); cpuIdlePct = d("cpu_idle_pct")
        procsTotal = i("procs_total"); threadsTotal = i("threads_total")
        memTotal = b("mem_total_bytes"); memUsed = b("mem_used_bytes"); memWired = b("mem_wired_bytes")
        memCompressed = b("mem_compressed_bytes"); memFree = b("mem_free_bytes")
        swapTotal = b("swap_total_bytes"); swapUsed = b("swap_used_bytes")
    }

    // MARK: the lines the menu shows

    /// "CPU 54.2% user · 21.7% sys · 24.6% idle"
    public var cpuLine: String {
        guard cpuUserPct != nil || cpuSysPct != nil || cpuIdlePct != nil else { return "CPU –" }
        return "CPU \(Format.percent(cpuUserPct)) user · \(Format.percent(cpuSysPct)) sys · \(Format.percent(cpuIdlePct)) idle"
    }
    /// "Memory 126.0G of 128.0G · 34.4G wired · 7.9G compressed"
    public var memoryLine: String {
        guard memUsed != nil || memTotal != nil else { return "Memory –" }
        var s = "Memory \(Format.bytes(memUsed)) of \(Format.bytes(memTotal))"
        if let w = memWired { s += " · \(Format.bytes(w)) wired" }
        if let c = memCompressed { s += " · \(Format.bytes(c)) compressed" }
        return s
    }
    /// "Swap 3.1G of 4.0G"
    public var swapLine: String {
        guard swapUsed != nil || swapTotal != nil else { return "Swap –" }
        return "Swap \(Format.bytes(swapUsed)) of \(Format.bytes(swapTotal))"
    }
    /// "Load 218.15 104.67 54.24 · 1847 processes · 9028 threads"
    public var loadLine: String {
        var s = load.isEmpty ? "Load –" : "Load \(Format.load(load))"
        if let p = procsTotal { s += " · \(p) processes" }
        if let t = threadsTotal { s += " · \(t) threads" }
        return s
    }
}

/// `sysobs show --json`: the `"snapshot"` and `"host_sample"` objects of the payload. The row readers above take
/// the same dictionaries straight from the CSV tails, which is how the app reads (show streams the 1 GB process
/// table for its row counts and took two minutes under load).
public enum ShowPayload {
    public static func parse(_ data: Data) -> (snapshot: SnapshotRow?, picture: HostPicture?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        let snap = (obj["snapshot"] as? [String: Any]).map(stringify).flatMap(SnapshotRow.init(row:))
        let pic = (obj["host_sample"] as? [String: Any]).map(stringify).flatMap(HostPicture.init(row:))
        return (snap, pic)
    }
    static func stringify(_ d: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in d {
            if let s = v as? String { out[k] = s }
            else if v is NSNull { out[k] = "" }
            else if let n = v as? NSNumber { out[k] = n.stringValue }
        }
        return out
    }
}
