// Renders the app icon (1024 px, macOS grid) from the "done" pose. Build it as main.swift together with Figur.swift:
// cp scripts/icon.swift /tmp/main.swift && swiftc /tmp/main.swift Sources/Oktopus/Figur.swift -o /tmp/icon && /tmp/icon icon.png
import AppKit

let bild = Figur.rendern(json: nil, zustand: "fertig")!
let groesse = 1024, kachel: CGFloat = 824
let ctx = CGContext(data: nil, width: groesse, height: groesse, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rand = (CGFloat(groesse) - kachel) / 2
ctx.addPath(CGPath(roundedRect: CGRect(x: rand, y: rand, width: kachel, height: kachel),
                   cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(CGColor(gray: 0.04, alpha: 1)); ctx.fillPath()
let ph: CGFloat = 44, pw = ph / 2
let breite = CGFloat(Pixelbild.breite) * pw, hoehe = CGFloat(Pixelbild.hoehe) * ph
let x0 = (CGFloat(groesse) - breite) / 2, y0 = (CGFloat(groesse) - hoehe) / 2
for y in 0..<Pixelbild.hoehe { for x in 0..<Pixelbild.breite {
    guard let g = bild[x, y], g > 0 else { continue }
    ctx.setFillColor(CGColor(gray: CGFloat(g) / 255, alpha: 1))
    ctx.fill(CGRect(x: x0 + CGFloat(x) * pw, y: CGFloat(groesse) - y0 - CGFloat(y + 1) * ph, width: pw, height: ph))
}}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
