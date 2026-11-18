// Renders every gesture as an animated GIF for the README. Build it as main.swift together with Figur.swift:
// cp scripts/gesten.swift /tmp/main.swift && swiftc /tmp/main.swift Sources/Oktopus/Figur.swift -o /tmp/gesten && /tmp/gesten docs/gestures.gif
import AppKit
import ImageIO
import UniformTypeIdentifiers

let gesten: [(zustand: String, helfer: Int, titel: String)] = [
    ("wartet", 0, "waiting"), ("hoert", 0, "listening"), ("denkt", 0, "thinking"), ("tool", 0, "working"),
    ("spricht", 0, "talking"), ("fragt", 0, "asking"), ("fertig", 0, "done"), ("fehler", 0, "error"),
    ("denkt", 1, "with helpers"), ("schlaeft", 0, "asleep"),
]
let spalten = 5, zellB = 180, zellH = 150, ph: CGFloat = 8
let breite = spalten * zellB, hoehe = (gesten.count + spalten - 1) / spalten * zellH
let start = 1_790_000_000, bilder = 8

let ziel = URL(fileURLWithPath: CommandLine.arguments[1])
let datei = CGImageDestinationCreateWithURL(ziel as CFURL, UTType.gif.identifier as CFString, bilder, nil)!
CGImageDestinationSetProperties(datei, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

for bild in 0..<bilder {
    setenv("OKTOPUS_JETZT", String(start + bild), 1)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: breite, pixelsHigh: hoehe, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.04, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: breite, height: hoehe).fill()
    for (i, g) in gesten.enumerated() {
        let x0 = CGFloat(i % spalten * zellB), y0 = CGFloat(hoehe - (i / spalten + 1) * zellH)
        guard let figur = Figur.rendern(json: nil, zustand: g.zustand, helfer: g.helfer) else { continue }
        let fx = x0 + (CGFloat(zellB) - CGFloat(Pixelbild.breite) * ph / 2) / 2, fy = y0 + 44
        for y in 0..<Pixelbild.hoehe {
            for x in 0..<Pixelbild.breite {
                guard let grau = figur[x, y], grau > 0 else { continue }
                NSColor(white: CGFloat(grau) / 255, alpha: 1).setFill()
                NSRect(x: fx + CGFloat(x) * ph / 2, y: fy + CGFloat(Pixelbild.hoehe - 1 - y) * ph, width: ph / 2, height: ph).fill()
            }
        }
        let text = NSAttributedString(string: g.titel, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 0.6, alpha: 1)])
        text.draw(at: NSPoint(x: x0 + (CGFloat(zellB) - text.size().width) / 2, y: y0 + 14))
    }
    NSGraphicsContext.restoreGraphicsState()
    CGImageDestinationAddImage(datei, rep.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
}
CGImageDestinationFinalize(datei)
