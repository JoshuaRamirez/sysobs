// swift-tools-version:5.9
import PackageDescription

// SysObs — the menu-bar app for sysobs (docs/menu-bar-app.md says what it shows and where it reads).
// SysObsCore is UI-free and unit-tested on fixtures; SysObs is the SwiftUI/AppKit app wrapped in SysObs.app by build.sh.
let package = Package(
    name: "SysObs",
    platforms: [.macOS("14.4")],   // NSHostingMenu, the SwiftUI menu under an NSStatusItem, is 14.4+
    targets: [
        .target(name: "SysObsCore"),
        .testTarget(name: "SysObsCoreTests", dependencies: ["SysObsCore"]),
        .executableTarget(name: "SysObs", dependencies: ["SysObsCore"]),
    ]
)
