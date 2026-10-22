import Foundation

/// Where sysobs keeps things (README "Install": `$SYSOBS_HOME`, default `~/.local/state/sysobs`) and where its
/// executable is. The app reads the store; it never writes to it and never takes `.store.lock`.
public enum Paths {
    public static let home = URL(fileURLWithPath: NSHomeDirectory())

    /// `$SYSOBS_HOME`, else `$XDG_STATE_HOME/sysobs`, else `~/.local/state/sysobs` — the same resolution as bin/sysobs.
    public static func storeRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = environment["SYSOBS_HOME"], !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
        if let x = environment["XDG_STATE_HOME"], !x.isEmpty {
            return URL(fileURLWithPath: (x as NSString).expandingTildeInPath).appendingPathComponent("sysobs")
        }
        return home.appendingPathComponent(".local/state/sysobs")
    }
    public static func tables(in root: URL) -> URL { root.appendingPathComponent("tables") }
    public static func spool(in root: URL) -> URL { root.appendingPathComponent("spool") }
    public static func snapshotTable(in root: URL) -> URL { tables(in: root).appendingPathComponent("snapshot.csv") }
    public static func hostSampleTable(in root: URL) -> URL { tables(in: root).appendingPathComponent("host_sample.csv") }

    /// The sysobs executable: the repo's bin, else the installed command, whichever exists.
    public static var sysobsCandidates: [URL] {
        [home.appendingPathComponent("Developer/sysobs/bin/sysobs"),
         home.appendingPathComponent(".local/bin/sysobs")]
    }
    public static func firstExecutable(of candidates: [URL] = sysobsCandidates,
                                       isExecutable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) -> URL? {
        candidates.first(where: isExecutable)
    }

    /// Everything sysobs runs through `/usr/bin/env` (the brief), with Homebrew's python3 ahead of the Xcode stub.
    public static let env = URL(fileURLWithPath: "/usr/bin/env")
    public static func searchPath(from current: String?) -> String {
        let front = ["/opt/homebrew/bin", "/usr/local/bin"]
        let rest = (current ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        return (front + rest).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The app's own settings file.
    public static let settings = home.appendingPathComponent(".config/sysobs/menu-bar.json")
}
