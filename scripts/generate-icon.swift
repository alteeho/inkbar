import AppKit

let canvas = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
    NSColor.clear.setFill()
    rect.fill()

    let screen = NSRect(x: 64, y: 252, width: 896, height: 520)
    let corner: CGFloat = 52
    let screenPath = NSBezierPath(roundedRect: screen, xRadius: corner, yRadius: corner)
    NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1).setFill()
    screenPath.fill()
    screenPath.addClip()

    let wallpaper = screen.insetBy(dx: 10, dy: 10)
    NSBezierPath(roundedRect: wallpaper, xRadius: 36, yRadius: 36).addClip()
    NSColor(srgbRed: 0.35, green: 0.48, blue: 0.62, alpha: 1).setFill()
    wallpaper.fill()

    let notchW = screen.width * 0.15
    let notchH = screen.height * 0.11
    let notch = NSRect(
        x: screen.midX - notchW / 2,
        y: screen.maxY - notchH,
        width: notchW,
        height: notchH
    )
    NSColor.black.setFill()
    NSBezierPath(roundedRect: notch, xRadius: notchH / 2, yRadius: notchH / 2).fill()

    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode icon\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
try png.write(to: url)
print("Wrote \(url.path)")
