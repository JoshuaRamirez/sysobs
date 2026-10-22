import Foundation

/// One tick of `sysobs light --json`: the per-tick `ps` the sampler writes outside the store, every five minutes
/// even when the full snapshot could not finish. `top` is already sorted by the `--by` key and cut to `-n`.
public struct LightSample: Equatable, Sendable {
    public struct Process: Equatable, Sendable, Identifiable {
        public var pid: Int
        public var ppid: Int?
        public var cpuPct: Double
        public var rssKB: Int64
        public var elapsedS: Int?
        public var command: String
        public var id: Int { pid }
        public init(pid: Int, ppid: Int? = nil, cpuPct: Double, rssKB: Int64, elapsedS: Int? = nil, command: String) {
            self.pid = pid; self.ppid = ppid; self.cpuPct = cpuPct; self.rssKB = rssKB; self.elapsedS = elapsedS; self.command = command
        }
        /// "187.7%  26.7G  llama-server --model …" for a menu row.
        public func line(by key: SortKey, width: Int = 56) -> String {
            let n = key == .cpu ? Format.percent(cpuPct) : Format.bytes(rssKB * 1024)
            return "\(n)  \(Format.shortCommand(command, width: width))"
        }
    }
    public enum SortKey: String, Sendable { case cpu, rss }

    public var at: Date
    public var load: [Double]
    public var cores: Int?
    public var status: String
    public var processes: Int?
    public var cpuPctTotal: Double?
    public var top: [Process]

    /// The whole `--json` array; samples in the order sysobs printed them (oldest first).
    public static func parse(_ data: Data) -> [LightSample] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap(LightSample.init(object:))
    }
    /// The newest sample of the window, the one the menu shows.
    public static func latest(_ data: Data) -> LightSample? { parse(data).max { $0.at < $1.at } }

    init?(object o: [String: Any]) {
        guard let ts = o["ts"] as? String, let at = TimeFormat.parse(ts) else { return nil }
        self.at = at
        load = (o["load"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        cores = (o["cores"] as? NSNumber)?.intValue
        status = o["status"] as? String ?? ""
        processes = (o["processes"] as? NSNumber)?.intValue
        cpuPctTotal = (o["cpu_pct_total"] as? NSNumber)?.doubleValue
        top = ((o["top"] as? [[String: Any]]) ?? []).compactMap { p in
            guard let pid = (p["pid"] as? NSNumber)?.intValue else { return nil }
            return Process(pid: pid, ppid: (p["ppid"] as? NSNumber)?.intValue,
                           cpuPct: (p["cpu_pct"] as? NSNumber)?.doubleValue ?? 0,
                           rssKB: (p["rss_kb"] as? NSNumber)?.int64Value ?? 0,
                           elapsedS: (p["elapsed_s"] as? NSNumber)?.intValue,
                           command: p["command"] as? String ?? "")
        }
    }

    /// The arguments for one light call: the last hour, sorted by `key`, `count` rows per sample.
    public static func arguments(by key: SortKey, count: Int, since: String = "1h") -> [String] {
        ["light", "--since", since, "--by", key.rawValue, "-n", String(count), "--json"]
    }
}
