import Foundation
import Observation
import SysObsCore

/// What the menu and the Settings window look at. Every `settings.refreshSeconds` it reads the two small tables'
/// tails and the spool's tail itself, and runs `sysobs light --json` (the per-tick ps) for the two top lists.
/// It never writes to the store and never takes its lock: `events` runs with `--no-ingest`, and only "Take a
/// snapshot now" runs a writer, which is sysobs itself.
@MainActor
@Observable
final class AppModel {
    var settings: Settings = .default
    private(set) var snapshot: SnapshotRow?
    private(set) var picture: HostPicture?
    private(set) var byCPU: LightSample?
    private(set) var byMemory: LightSample?
    private(set) var events: [ProcessEvent] = []
    /// "spool" (procwatch's own file) or "events" (`sysobs events`, the stored rows), or "" before the first read.
    private(set) var eventsSource = ""
    /// One line under the actions: the last snapshot's outcome, a missing binary, a failed read.
    private(set) var note: String?
    private(set) var snapshotRunning = false
    private(set) var now = Date()
    private(set) var lastRefresh: Date?
    /// Called after every refresh, for the status item's label (outside SwiftUI).
    var onRefresh: (() -> Void)?

    let storeRoot = Paths.storeRoot()
    let sysobs = Paths.firstExecutable()
    private var timer: Timer?
    private var writing = false

    func start() {
        settings = Settings.load()
        reload()
        schedule()
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.refreshSeconds), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    // MARK: reading

    func reload() {
        now = Date()
        if !writing {
            let onDisk = Settings.load()
            if onDisk != settings { settings = onDisk; schedule() }
        }
        snapshot = CSV.lastRow(of: Paths.snapshotTable(in: storeRoot)).flatMap(SnapshotRow.init(row:))
        picture = CSV.lastRow(of: Paths.hostSampleTable(in: storeRoot)).flatMap(HostPicture.init(row:))
        if let fromSpool = Spool.recentEvents(in: Paths.spool(in: storeRoot), now: now) {
            events = fromSpool
            eventsSource = "spool"
        } else {
            eventsSource = "events"
            run(ProcessEvent.arguments(limit: Settings.eventsLimit)) { [weak self] data, _, _ in
                guard let self else { return }
                self.events = ProcessEvent.recent(ProcessEvent.parse(eventsJSON: data), now: self.now)
                self.onRefresh?()
            }
        }
        let n = settings.topCount
        run(LightSample.arguments(by: .cpu, count: n)) { [weak self] data, _, _ in
            self?.byCPU = LightSample.latest(data); self?.onRefresh?()
        }
        run(LightSample.arguments(by: .rss, count: n)) { [weak self] data, _, _ in
            self?.byMemory = LightSample.latest(data); self?.onRefresh?()
        }
        lastRefresh = now
        onRefresh?()
    }

    // MARK: actions

    /// `sysobs snapshot --json` through /usr/bin/env; the outcome (taken, skipped for the lock, failed) is the note.
    func takeSnapshot() {
        guard !snapshotRunning else { return }
        snapshotRunning = true
        note = "taking a snapshot…"
        run(["snapshot", "--json"]) { [weak self] data, code, err in
            guard let self else { return }
            self.snapshotRunning = false
            self.note = SnapshotResult.parse(data, exitCode: code, stderr: err).note
            self.reload()
        }
    }

    /// Every settings change lands on disk at once and re-arms the timer.
    func saveSettings() {
        writing = true
        defer { writing = false }
        do { try settings.save(); if note?.hasPrefix("could not write") == true { note = nil } }
        catch { note = "could not write \(Paths.settings.lastPathComponent): \(error.localizedDescription)" }
        schedule()
    }

    // MARK: running sysobs

    /// `/usr/bin/env <sysobs> <arguments>`, stdout read whole on a background queue (a pipe left unread blocks
    /// the child), the completion on the main actor. A missing binary is the note, once.
    private func run(_ arguments: [String], completion: @escaping @MainActor (Data, Int32, String) -> Void) {
        guard let bin = sysobs else {
            note = "sysobs is not installed (looked in ~/Developer/sysobs/bin and ~/.local/bin)"
            return
        }
        let proc = Process()
        proc.executableURL = Paths.env
        proc.arguments = [bin.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Paths.searchPath(from: env["PATH"])
        proc.environment = env
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        DispatchQueue.global(qos: .utility).async {
            do { try proc.run() } catch {
                Task { @MainActor in self.note = "could not run sysobs: \(error.localizedDescription)" }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            proc.waitUntilExit()
            let code = proc.terminationStatus
            Task { @MainActor in completion(data, code, errText) }
        }
    }

    // MARK: phrases

    /// "3 min ago (07:32) · 5.8 s" or "no snapshot yet".
    var snapshotText: String {
        guard let s = snapshot else { return "no snapshot yet" }
        var t = "\(TimeFormat.relative(s.startedAt, now: now)) (\(TimeFormat.clock(s.startedAt)))"
        if let ms = s.durationMs { t += " · \(TimeFormat.duration(ms: ms))" }
        return t
    }
    /// The light sample behind the top lists: "sampled 07:37 · load 316.14 245.65 135.3".
    var sampleText: String {
        guard let l = byCPU ?? byMemory else { return "no sample in the last hour" }
        var t = "sampled \(TimeFormat.clock(l.at))"
        if !l.load.isEmpty { t += " · load \(Format.load(l.load))" }
        if let p = l.processes { t += " · \(p) processes" }
        return t
    }
    /// The one-minute load beside the symbol, from the newest sample; empty until there is one.
    var labelText: String {
        guard let load = (byCPU ?? byMemory)?.load.first ?? picture?.load.first else { return "" }
        return " " + Format.number(load.rounded())
    }
    var tooltipText: String { "sysobs · snapshot \(snapshotText) · \(sampleText)" }
    var storeText: String { storeRoot.path.replacingOccurrences(of: Paths.home.path, with: "~") }
    var binaryText: String { sysobs?.path.replacingOccurrences(of: Paths.home.path, with: "~") ?? "not found" }
    var eventsSourceText: String {
        switch eventsSource {
        case "spool": return "procwatch spool (live)"
        case "events": return "sysobs events, stored rows (no spool)"
        default: return "–"
        }
    }
}
