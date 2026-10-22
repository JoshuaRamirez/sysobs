import Foundation

/// What `sysobs snapshot --json` printed: a snapshot id, or that the full snapshot was skipped because another
/// sysobs held the store lock (the light sample was still written).
public enum SnapshotResult: Equatable, Sendable {
    case taken(id: String, eventsIngested: Int)
    case skipped(reason: String)
    case failed(message: String)

    public static func parse(_ data: Data, exitCode: Int32, stderr: String = "") -> SnapshotResult {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let id = obj["snapshot_id"] as? String, !id.isEmpty {
                return .taken(id: id, eventsIngested: (obj["events_ingested"] as? NSNumber)?.intValue ?? 0)
            }
            if let why = obj["skipped"] as? String { return .skipped(reason: why) }
        }
        let last = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return .failed(message: exitCode == 0 ? "no snapshot id in the output" : "exit \(exitCode)" + (last.isEmpty ? "" : ": \(last)"))
    }

    /// The one line the menu shows under the action.
    public var note: String {
        switch self {
        case .taken(let id, let n): return "snapshot \(id) taken" + (n > 0 ? ", \(n) events folded in" : "")
        case .skipped(let why): return why
        case .failed(let m): return "snapshot failed: \(m)"
        }
    }
}
