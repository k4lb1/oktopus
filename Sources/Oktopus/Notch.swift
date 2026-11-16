import AppKit
import ServiceManagement
import SwiftUI

/// Maße rund um die Notch, in Bildschirmkoordinaten
struct Geometrie {
    var notchMitteX: CGFloat = 0
    var oben: CGFloat = 0
    var notchBreite: CGFloat = 0
    var notchHoehe: CGFloat = 32
    let fluegel: CGFloat = 76
    let pixelGross: CGFloat = 6
    static let maxSitzungen = 6

    var breiteZu: CGFloat { notchBreite + 2 * fluegel }
    var breiteOffen: CGFloat { max(notchBreite + 2 * 200, 600) }
    // Pixelhöhe; Pixel sind wie Terminal-Viertelblöcke doppelt so hoch wie breit
    var pixelKlein: CGFloat { floor((notchHoehe - 1) / CGFloat(Pixelbild.hoehe) * 2) / 2 }

    func hoeheOffen(sitzungen n: Int) -> CGFloat {
        notchHoehe + 150 + CGFloat(min(max(n - 1, 0), Self.maxSitzungen - 1)) * 22
    }

    var fensterRahmen: NSRect {
        let h = hoeheOffen(sitzungen: Self.maxSitzungen)
        return NSRect(x: notchMitteX - breiteOffen / 2, y: oben - h, width: breiteOffen, height: h)
    }

    var rahmenZu: NSRect {
        NSRect(x: notchMitteX - breiteZu / 2, y: oben - notchHoehe, width: breiteZu, height: notchHoehe)
    }

    func rahmenOffen(sitzungen n: Int) -> NSRect {
        let h = hoeheOffen(sitzungen: n)
        return NSRect(x: notchMitteX - breiteOffen / 2, y: oben - h, width: breiteOffen, height: h)
    }

    static func berechnen() -> Geometrie {
        var g = Geometrie()
        guard let schirm = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return g }
        g.oben = schirm.frame.maxY
        if let l = schirm.auxiliaryTopLeftArea, let r = schirm.auxiliaryTopRightArea, schirm.safeAreaInsets.top > 0 {
            g.notchBreite = r.minX - l.maxX
            g.notchMitteX = schirm.frame.minX + (l.maxX + r.minX) / 2
            g.notchHoehe = schirm.safeAreaInsets.top
        } else {
            // Bildschirm ohne Notch: kleine Pille mittig unter der Menüleiste
            g.notchMitteX = schirm.frame.midX
            g.notchHoehe = NSStatusBar.system.thickness + 6
        }
        return g
    }
}

final class NotchModell: ObservableObject {
    @Published var bild = Pixelbild()
    @Published var sitzungen: [Sitzung] = []
    @Published var aufgeklappt = false
    @Published var geometrie = Geometrie.berechnen()
}

final class NotchFenster: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let modell = NotchModell()
    private var fenster: NotchFenster!
    private var takt: Timer?
    private var maus: Timer?
    private let hintergrund = DispatchQueue(label: "oktopus.figur")
    private var rendertGerade = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        fenster = NotchFenster()
        fenster.contentView = NSHostingView(rootView: NotchAnsicht(modell: modell))
        platzieren()
        fenster.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.platzieren() }

        takt = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.aktualisieren() }
        maus = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.mausPruefen() }
        aktualisieren()
    }

    private func platzieren() {
        modell.geometrie = Geometrie.berechnen()
        fenster.setFrame(modell.geometrie.fensterRahmen, display: true)
    }

    /// Sitzungen lesen und die Figur über statusline.sh zeichnen lassen; ohne offene Sitzung schläft er
    private func aktualisieren() {
        guard !rendertGerade else { return }
        rendertGerade = true
        hintergrund.async {
            let sitzungen = Sitzungen.lesen()
            let aktuell = sitzungen.first
            let bild = Figur.rendern(json: aktuell?.json, zustand: aktuell == nil ? "schlaeft" : nil)
            DispatchQueue.main.async {
                self.modell.sitzungen = sitzungen
                if let bild { self.modell.bild = bild }
                self.rendertGerade = false
            }
        }
    }

    /// Aufklappen, solange die Maus über der Notch bzw. dem aufgeklappten Feld ist.
    /// Abfragen statt Tracking-Areas, weil das Fenster nie aktiv wird.
    private func mausPruefen() {
        let g = modell.geometrie
        let feld = modell.aufgeklappt ? g.rahmenOffen(sitzungen: modell.sitzungen.count) : g.rahmenZu
        let drin = feld.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if drin != modell.aufgeklappt {
            withAnimation(.spring(duration: 0.35)) { modell.aufgeklappt = drin }
        }
    }
}

// MARK: - Ansicht

struct PixelFigur: View {
    let bild: Pixelbild
    /// Pixelhöhe; die Breite ist die Hälfte, wie bei Viertelblöcken im Terminal
    let pixel: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for y in 0..<Pixelbild.hoehe {
                for x in 0..<Pixelbild.breite {
                    // Schwarz bleibt ein Loch im Körper, so sind Augen und Mund dunkel
                    guard let g = bild[x, y], g > 0 else { continue }
                    let rechteck = CGRect(x: CGFloat(x) * pixel / 2, y: CGFloat(y) * pixel, width: pixel / 2, height: pixel)
                    ctx.fill(Path(rechteck), with: .color(Color(white: Double(g) / 255)))
                }
            }
        }
        .frame(width: CGFloat(Pixelbild.breite) * pixel / 2, height: CGFloat(Pixelbild.hoehe) * pixel)
    }
}

struct NotchAnsicht: View {
    @ObservedObject var modell: NotchModell

    private let schrift = Font.system(size: 11, design: .monospaced)
    private let etikett = Color(white: 0.35)
    private let wert = Color(white: 0.65)

    var body: some View {
        let g = modell.geometrie
        let offen = modell.aufgeklappt
        let breite = offen ? g.breiteOffen : g.breiteZu
        let hoehe = offen ? g.hoeheOffen(sitzungen: modell.sitzungen.count) : g.notchHoehe
        let radius: CGFloat = offen ? 20 : 10

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                .fill(.black)
            if offen {
                aufgeklappt(g).transition(.opacity)
            } else {
                zugeklappt(g).transition(.opacity)
            }
        }
        .frame(width: breite, height: hoehe, alignment: .top)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contextMenu {
            Button(SMAppService.mainApp.status == .enabled ? "Nicht mehr beim Anmelden starten" : "Beim Anmelden starten") {
                let dienst = SMAppService.mainApp
                if dienst.status == .enabled { try? dienst.unregister() } else { try? dienst.register() }
            }
            Button("Beenden") { NSApp.terminate(nil) }
        }
    }

    private func zugeklappt(_ g: Geometrie) -> some View {
        HStack(spacing: 0) {
            Text(modell.sitzungen.first?.kontextProzent.map { "\($0) %" } ?? "")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(wert)
                .frame(width: g.fluegel)
            Color.clear.frame(width: g.notchBreite)
            PixelFigur(bild: modell.bild, pixel: g.pixelKlein)
                .frame(width: g.fluegel)
        }
        .frame(height: g.notchHoehe)
    }

    private func aufgeklappt(_ g: Geometrie) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: g.notchHoehe - 6)
            HStack(alignment: .top, spacing: 18) {
                PixelFigur(bild: modell.bild, pixel: g.pixelGross)
                if let s = modell.sitzungen.first {
                    details(s)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Schläft").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text("Keine Claude-Code-Sitzung offen").font(schrift).foregroundStyle(wert)
                    }
                }
            }
            let weitere = modell.sitzungen.dropFirst().prefix(Geometrie.maxSitzungen - 1)
            if !weitere.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(weitere)) { s in
                        HStack(spacing: 8) {
                            Text(s.titel).foregroundStyle(wert).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(s.jetztText).foregroundStyle(etikett).lineLimit(1)
                            Text(s.kontextProzent.map { "\($0) %" } ?? "–").foregroundStyle(etikett)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .font(schrift)
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ s: Sitzung) -> some View {
        let limits = s.limits, cache = s.cache
        return VStack(alignment: .leading, spacing: 4) {
            Text(s.titel).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            Text(s.modellText).font(schrift).foregroundStyle(wert)
            zeile("Kontext") {
                HStack(spacing: 6) {
                    balken(s.kontextProzent ?? 0)
                    Text(s.kontextText).foregroundStyle(wert)
                }
            }
            zeile("Limits") { Text(limits.text).foregroundStyle(limits.hervorheben ? .white : wert) }
            zeile("Cache") { Text(cache.text).foregroundStyle(cache.knapp ? .white : wert) }
            zeile("Jetzt") { Text(s.jetztText).foregroundStyle(wert) }
            zeile("") { Text(s.arbeitText).foregroundStyle(etikett).lineLimit(1) }
        }
        .font(schrift)
    }

    private func zeile<Inhalt: View>(_ name: String, @ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        HStack(spacing: 8) {
            Text(name).foregroundStyle(etikett).frame(width: 56, alignment: .leading)
            inhalt()
        }
    }

    private func balken(_ prozent: Int) -> some View {
        let voll = (prozent + 5) / 10
        return HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                Rectangle().fill(i < voll ? Color.white : Color(white: 0.2)).frame(width: 7, height: 3)
            }
        }
    }
}
