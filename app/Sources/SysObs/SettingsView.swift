import SwiftUI
import SysObsCore

/// The Settings scene: two tabs, each a grouped Form, every change written to ~/.config/sysobs/menu-bar.json.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gear") }.tag("general")
            StatusTab().tabItem { Label("Status", systemImage: "info.circle") }.tag("status")
        }
        .frame(width: 520, height: 360)
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .onAppear { model.reload() }
    }
}

struct GeneralTab: View {
    @Environment(AppModel.self) private var model

    /// The interval choices; the current value is added when it is not one of them.
    private static let intervals = [10, 15, 30, 60, 120, 300, 600]

    var body: some View {
        @Bindable var model = model
        let seconds = Binding<Int>(
            get: { model.settings.refreshSeconds },
            set: { model.settings.refreshSeconds = Settings.clampRefresh($0) })
        let choices = Self.intervals.contains(seconds.wrappedValue)
            ? Self.intervals : (Self.intervals + [seconds.wrappedValue]).sorted()
        Form {
            Section {
                Picker("Refresh every", selection: seconds) {
                    ForEach(choices, id: \.self) { s in Text(TimeFormat.interval(seconds: s)).tag(s) }
                }
            } header: {
                Text("Refresh")
            } footer: {
                Text("Each refresh reads the store's two small tables and the procwatch spool, and runs sysobs light twice. The sampler takes a new sample every five minutes; refreshing faster only catches it sooner.")
            }
            Section {
                Stepper(value: $model.settings.topCount, in: Settings.topRange) {
                    LabeledContent("Processes per list", value: "\(model.settings.topCount)")
                }
            } header: {
                Text("Top Lists")
            } footer: {
                Text("How many processes the CPU and memory lists show.")
            }
        }
        .formStyle(.grouped)
    }
}

struct StatusTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("sysobs") {
                LabeledContent("Command", value: model.binaryText)
                LabeledContent("Store", value: model.storeText)
                LabeledContent("Settings", value: Paths.settings.path.replacingOccurrences(of: Paths.home.path, with: "~"))
            }
            Section("Readings") {
                LabeledContent("Last snapshot", value: model.snapshotText)
                LabeledContent("Last sample", value: model.sampleText)
                LabeledContent("Events from", value: model.eventsSourceText)
                LabeledContent("Last refresh", value: model.lastRefresh.map { TimeFormat.clock($0) } ?? "–")
                if let note = model.note, !note.isEmpty {
                    LabeledContent("Note", value: note)
                }
            }
        }
        .formStyle(.grouped)
    }
}
