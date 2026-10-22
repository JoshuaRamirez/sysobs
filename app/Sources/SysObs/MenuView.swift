import SwiftUI
import AppKit
import SysObsCore

/// The standard menu under the symbol: the latest snapshot and the machine-wide picture, the top processes by CPU
/// and by memory, the recent starts and exits, the two actions, Settings…, Quit.
struct MenuView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("Snapshot \(model.snapshotText)") {
            if let p = model.picture {
                Text(p.loadLine)
                Text(p.cpuLine)
                Text(p.memoryLine)
                Text(p.swapLine)
            } else {
                Text("No host sample in the store")
            }
        }
        Divider()
        Section("Top by CPU · \(model.sampleText)") {
            if let s = model.byCPU, !s.top.isEmpty {
                ForEach(s.top) { p in Text(p.line(by: .cpu)) }
            } else {
                Text("No sample yet")
            }
        }
        Divider()
        Section("Top by Memory") {
            if let s = model.byMemory, !s.top.isEmpty {
                ForEach(s.top) { p in Text(p.line(by: .rss)) }
            } else {
                Text("No sample yet")
            }
        }
        Divider()
        Section("Started and Exited, Last Hour") {
            if model.events.isEmpty {
                Text(model.eventsSource.isEmpty ? "Reading…" : "Nothing recorded")
            }
            ForEach(model.events) { e in
                Label(e.line(), systemImage: e.kind == .start ? "play.circle" : "stop.circle")
            }
        }
        Divider()
        Button(model.snapshotRunning ? "Taking a Snapshot…" : "Take a Snapshot Now") { model.takeSnapshot() }
            .keyboardShortcut("s")
            .disabled(model.snapshotRunning || model.sysobs == nil)
        Button("Refresh") { model.reload() }
            .keyboardShortcut("r")
        if let note = model.note, !note.isEmpty {
            Text(note)
        }
        Divider()
        Button("Settings…") { OpenSettings.now() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit SysObs") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
        // the menu's content is built when it opens: read again so it is current
        Color.clear.frame(width: 0, height: 0).onAppear { model.reload() }
    }
}
