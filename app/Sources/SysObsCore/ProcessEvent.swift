import Foundation

/// One process start or exit. Two sources, one shape:
/// - the procwatch spool, `spool/procwatch-<hour>.ndjson`: one JSON object per line with `exe`, `argv`, `parent_exe`,
///   written within two seconds of the event; the freshest record there is, read from the file's tail;
/// - `sysobs events --json --no-ingest`: the stored `process_event` rows, resolved to `command`, `parent`, `argv`,
///   up to a snapshot (five minutes) behind. The fallback when there is no spool.
public struct ProcessEvent: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case start, exit }
    public var at: Date
    public var kind: Kind
    public var pid: Int
    public var ppid: Int?
    public var command: String      // the executable's basename
    public var parent: String       // the parent's basename, "" when unknown
    public var argv: String
    public var lifetimeMs: Int?
    public var id: String { "\(kind.rawValue)-\(pid)-\(at.timeIntervalSince1970)" }

    public init(at: Date, kind: Kind, pid: Int, ppid: Int? = nil, command: String, parent: String = "", argv: String = "", lifetimeMs: Int? = nil) {
        self.at = at; self.kind = kind; self.pid = pid; self.ppid = ppid; self.command = command
        self.parent = parent; self.argv = argv; self.lifetimeMs = lifetimeMs
    }

    /// The display name: the basename, or the first word of the command line when the basename is empty.
    public var name: String {
        if !command.isEmpty { return command }
        return Format.shortCommand(argv, width: 24)
    }
    /// "07:32 started  cc-status ← claude" / "07:32 exited  bash ← Python · 2.0 s"
    public func line(timeZone: TimeZone = .current) -> String {
        var s = "\(TimeFormat.clock(at, timeZone: timeZone))  \(kind == .start ? "started" : "exited")  \(name)"
        if !parent.isEmpty { s += " ← \(parent)" }
        if kind == .exit, let ms = lifetimeMs { s += " · \(TimeFormat.duration(ms: ms))" }
        return s
    }

    // MARK: spool

    /// Every complete event in `text` (NDJSON). A line that does not parse — the torn last line of a file being
    /// appended to, or the fragment a tail read begins with — is skipped.
    public static func parse(spool text: String) -> [ProcessEvent] {
        text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return ProcessEvent(spoolObject: o)
        }
    }
    init?(spoolObject o: [String: Any]) {
        guard let ts = o["ts"] as? String, let at = TimeFormat.parse(ts),
              let kind = (o["event"] as? String).flatMap(Kind.init(rawValue:)),
              let pid = Self.int(o["pid"]) else { return nil }
        self.at = at; self.kind = kind; self.pid = pid
        ppid = Self.int(o["ppid"])
        command = Format.basename(o["exe"] as? String ?? "")
        parent = Format.basename(o["parent_exe"] as? String ?? "")
        argv = o["argv"] as? String ?? ""
        lifetimeMs = Self.int(o["lifetime_ms"])
    }

    // MARK: `sysobs events --json`

    public static func parse(eventsJSON data: Data) -> [ProcessEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["events"] as? [[String: Any]] else { return [] }
        return rows.compactMap(ProcessEvent.init(eventsObject:))
    }
    init?(eventsObject o: [String: Any]) {
        guard let ts = o["ts"] as? String, let at = TimeFormat.parse(ts),
              let kind = (o["event"] as? String).flatMap(Kind.init(rawValue:)),
              let pid = Self.int(o["pid"]) else { return nil }
        self.at = at; self.kind = kind; self.pid = pid
        ppid = Self.int(o["ppid"])
        command = o["command"] as? String ?? ""
        parent = o["parent"] as? String ?? ""
        argv = o["argv"] as? String ?? ""
        lifetimeMs = Self.int(o["lifetime_ms"])
    }

    /// The arguments for the fallback call: the last hour, the newest `limit`, nothing ingested (the app is never
    /// the store's writer).
    public static func arguments(limit: Int, since: String = "1h") -> [String] {
        ["events", "--since", since, "-n", String(limit), "--json", "--no-ingest"]
    }

    /// The newest `limit` events at or after `now - window`, oldest first.
    public static func recent(_ events: [ProcessEvent], now: Date, window: TimeInterval = Settings.eventsWindowSeconds,
                              limit: Int = Settings.eventsLimit) -> [ProcessEvent] {
        let cutoff = now.addingTimeInterval(-window)
        // a stable order: events with one stamp (procwatch flushes a tick's starts and exits together) keep file order
        let kept = events.enumerated().filter { $0.element.at >= cutoff }
            .sorted { $0.element.at == $1.element.at ? $0.offset < $1.offset : $0.element.at < $1.element.at }
        return kept.suffix(limit).map(\.element)
    }

    /// Spool JSON carries pid as a number and lifetime_ms as a number or "" (a start has no lifetime);
    /// the events command carries every field as a string.
    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}

/// The spool folder's files, newest last, and how much of each to read: the last `limit` events are in the last
/// few hundred KB of the newest file; the previous hour's file covers a window that crosses the hour.
public enum Spool {
    public static func files(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("procwatch-") && $0.hasSuffix(".ndjson") }.sorted()
            .map { folder.appendingPathComponent($0) }
    }
    /// The last `tailBytes` of `url` as text, beginning at a line boundary (the fragment before it dropped).
    public static func tail(of url: URL, tailBytes: Int = 512 * 1024) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return "" }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return "" }
        var bytes = [UInt8](data)
        if start > 0, let nl = bytes.firstIndex(of: 10) { bytes.removeFirst(nl + 1) } else if start > 0 { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }
    /// The recent events from the newest two spool files; nil when there is no spool at all (procwatch never ran here).
    public static func recentEvents(in folder: URL, now: Date, limit: Int = Settings.eventsLimit) -> [ProcessEvent]? {
        let files = Self.files(in: folder)
        guard !files.isEmpty else { return nil }
        var events: [ProcessEvent] = []
        for url in files.suffix(2) { events += ProcessEvent.parse(spool: tail(of: url)) }
        return ProcessEvent.recent(events, now: now, limit: limit)
    }
}
