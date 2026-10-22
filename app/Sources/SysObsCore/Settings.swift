import Foundation

/// `~/.config/sysobs/menu-bar.json`: how often the menu refreshes and how many processes each top list shows.
/// Missing keys take the defaults; out-of-range values are clamped, never refused.
public struct Settings: Codable, Equatable, Sendable {
    public static let defaultRefreshSeconds = 30
    public static let defaultTopCount = 5
    public static let refreshRange = 5...3600
    public static let topRange = 1...20
    /// The events window and limit are fixed (the brief: the last hour, up to ten).
    public static let eventsWindowSeconds: TimeInterval = 3600
    public static let eventsLimit = 10

    public var refreshSeconds: Int
    public var topCount: Int

    enum CodingKeys: String, CodingKey { case refreshSeconds = "refresh_seconds", topCount = "top_count" }

    public init(refreshSeconds: Int = defaultRefreshSeconds, topCount: Int = defaultTopCount) {
        self.refreshSeconds = Settings.clampRefresh(refreshSeconds)
        self.topCount = Settings.clampTop(topCount)
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshSeconds = Settings.clampRefresh(try c.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? Settings.defaultRefreshSeconds)
        topCount = Settings.clampTop(try c.decodeIfPresent(Int.self, forKey: .topCount) ?? Settings.defaultTopCount)
    }
    public static let `default` = Settings()

    public static func clampRefresh(_ s: Int) -> Int { min(max(s, refreshRange.lowerBound), refreshRange.upperBound) }
    public static func clampTop(_ n: Int) -> Int { min(max(n, topRange.lowerBound), topRange.upperBound) }

    // MARK: file

    /// Defaults when the file is missing or unreadable; never throws.
    public static func load(from url: URL = Paths.settings) -> Settings {
        guard let data = try? Data(contentsOf: url) else { return .default }
        return (try? JSONDecoder().decode(Settings.self, from: data)) ?? .default
    }

    /// Pretty-printed, sorted keys, written atomically (tmp + replace), folder created on demand.
    public func save(to url: URL = Paths.settings) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
