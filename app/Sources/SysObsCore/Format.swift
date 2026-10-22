import Foundation

/// Numbers the way sysobs prints them (`human()`: 1024-based, one decimal) and command lines cut to fit a menu row.
public enum Format {
    /// 28645457920 -> "26.7G"; 512 -> "512B"; nil -> "-". The same ladder as bin/sysobs `human`.
    public static func bytes(_ n: Int64?) -> String {
        guard let n else { return "-" }
        var v = Double(n)
        for unit in ["B", "K", "M", "G", "T", "P"] {
            if abs(v) < 1024 || unit == "P" {
                return unit == "B" ? String(format: "%.0f%@", v, unit) : String(format: "%.1f%@", v, unit)
            }
            v /= 1024
        }
        return String(format: "%.1fP", v)
    }

    /// "54.2%" from 54.23; whole numbers stay whole ("0%", "100%").
    public static func percent(_ v: Double?) -> String {
        guard let v else { return "-" }
        return v == v.rounded() ? String(format: "%.0f%%", v) : String(format: "%.1f%%", v)
    }

    /// Load averages as `sysobs show` prints them: "218.15 104.67 54.24", trailing zeros dropped.
    public static func load(_ values: [Double]) -> String {
        values.map { number($0) }.joined(separator: " ")
    }

    /// 316.14 -> "316.14", 54.0 -> "54", 0.5 -> "0.5".
    public static func number(_ v: Double) -> String {
        if v == v.rounded() { return String(format: "%.0f", v) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    /// The executable's path cut to its name, the rest of the command line kept, the whole clipped to `width`
    /// (bin/sysobs `_short_command`): "/opt/.../Python -I /tmp/x.py" -> "Python -I /tmp/x.py".
    public static func shortCommand(_ command: String, width: Int = 60) -> String {
        var head = command
        var rest = ""
        if let r = command.range(of: " ") {
            head = String(command[..<r.lowerBound])
            rest = String(command[r.lowerBound...])
        }
        if head.hasPrefix("/"), let slash = head.lastIndex(of: "/") {
            head = String(head[head.index(after: slash)...])
        }
        let line = (head + rest).replacingOccurrences(of: "\n", with: " ")
        if line.count <= width { return line }
        return String(line.prefix(max(1, width - 1))) + "…"
    }

    /// The last path component of an executable ("/bin/zsh" -> "zsh"); an empty path stays empty.
    public static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}
