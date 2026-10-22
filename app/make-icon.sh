#!/bin/bash
# Render the SysObs icon (the cpu symbol on a dark rounded square) to an .icns with Swift + AppKit and iconutil.
# Usage: bash make-icon.sh <out.icns>. Optional; build.sh calls it and goes on without it on any failure
# (DeskHub's make-icon.sh, with the symbol and the colour changed).
set -euo pipefail
OUT="$1"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/icon.swift" <<'SWIFT'
import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = CommandLine.arguments[1]
for s in sizes {
    let size = NSSize(width: s, height: s)
    let img = NSImage(size: size)
    img.lockFocus()
    let r = NSRect(origin: .zero, size: size).insetBy(dx: CGFloat(s) * 0.04, dy: CGFloat(s) * 0.04)
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: r, xRadius: CGFloat(s) * 0.22, yRadius: CGFloat(s) * 0.22).fill()
    if let sym = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: CGFloat(s) * 0.55, weight: .semibold)) {
        let tinted = NSImage(size: sym.size)
        tinted.lockFocus()
        NSColor.white.set()
        let br = NSRect(origin: .zero, size: sym.size)
        sym.draw(in: br)
        br.fill(using: .sourceAtop)
        tinted.unlockFocus()
        let bs = tinted.size
        let scale = CGFloat(s) * 0.58 / max(bs.width, bs.height)
        let w = bs.width * scale, h = bs.height * scale
        tinted.draw(in: NSRect(x: (CGFloat(s) - w) / 2, y: (CGFloat(s) - h) / 2, width: w, height: h))
    }
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = s <= 512 ? "icon_\(s)x\(s).png" : "icon_512x512@2x.png"
    try! png.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
    if s >= 32 && s <= 1024 && s != 64 {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(s/2)x\(s/2)@2x.png"))
    }
}
SWIFT
mkdir -p "$TMP/AppIcon.iconset"
swiftc -O -o "$TMP/icon" "$TMP/icon.swift" 2>/dev/null
"$TMP/icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT"
echo "✓ icon at $OUT"
