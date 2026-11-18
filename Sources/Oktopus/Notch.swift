import AppKit
import ServiceManagement
import SwiftUI

/// Maße rund um die Notch, in Bildschirmkoordinaten
struct Geometrie {
    var notchMitteX: CGFloat = 0
    var oben: CGFloat = 0
    var notchBreite: CGFloat = 0
    var notchHoehe: CGFloat = 32
    let fluegel: CGFloat = 42
    let pixelListe: CGFloat = 4
    let zeileHoehe: CGFloat = 58
    let meldungHoehe: CGFloat = 24
    static let maxSitzungen = 6

    var breiteZu: CGFloat { notchBreite + 2 * fluegel }
    var breiteOffen: CGFloat { max(notchBreite + 2 * 200, 600) }
    // Pixelhöhe; Pixel sind wie Terminal-Viertelblöcke doppelt so hoch wie breit.
    // 2 pt hoch, 1 pt breit fällt auf ganze Retina-Pixel und bleibt scharf.
    let pixelKlein: CGFloat = 2

    func hoeheOffen(sitzungen n: Int) -> CGFloat {
        notchHoehe + 6 + CGFloat(min(max(n, 1), Self.maxSitzungen)) * zeileHoehe + 40
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

/// Kurze Nachricht unter der Notch, z. B. wenn eine Sitzung fertig ist
struct Meldung: Equatable {
    let text: String
    let wichtig: Bool
}

final class NotchModell: ObservableObject {
    @Published var bild = Pixelbild()
    @Published var sitzungen: [Sitzung] = []
    @Published var aufgeklappt = false
    @Published var meldung: Meldung?
    @Published var geometrie = Geometrie.berechnen()

    /// Irgendeine Sitzung wartet auf eine Erlaubnis
    var klopft: Bool { sitzungen.contains { $0.wirksamerZustand == "fragt" } }

    /// Die dringendste Sitzung, bei Gleichstand die zuletzt aktive
    static func vertreter(_ sitzungen: [Sitzung]) -> Sitzung? {
        sitzungen.max { ($0.dringlichkeit, $0.seit) < ($1.dringlichkeit, $1.seit) }
    }
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

    /// Sitzungen lesen und die Figur über statusline.sh zeichnen lassen; ohne offene Sitzung zeigt sie den Schlafzustand
    private func aktualisieren() {
        guard !rendertGerade else { return }
        rendertGerade = true
        hintergrund.async {
            var sitzungen = Sitzungen.lesen()
            for i in sitzungen.indices { sitzungen[i].bild = Figur.rendern(json: sitzungen[i].json, zustand: nil) }
            let bild = NotchModell.vertreter(sitzungen)?.bild ?? Figur.rendern(json: nil, zustand: "schlaeft")
            DispatchQueue.main.async {
                self.modell.sitzungen = sitzungen
                if let bild { self.modell.bild = bild }
                self.melden(sitzungen)
                self.rendertGerade = false
            }
        }
    }

    /// Wann zuletzt eine Sitzung als fertig gemeldet wurde, damit jedes Fertig nur einmal kommt
    private var gemeldetFertig: [String: TimeInterval] = [:]
    private var fertigBis: Date?

    /// Erlaubnisfragen bleiben stehen, bis sie beantwortet sind; Fertig zeigt sich ein paar Sekunden
    private func melden(_ sitzungen: [Sitzung]) {
        let jetzt = Date().timeIntervalSince1970
        var neu: Meldung?

        for s in sitzungen where s.zustand == "fertig" && jetzt - s.seit < 10 && gemeldetFertig[s.id] != s.seit {
            gemeldetFertig[s.id] = s.seit
            neu = Meldung(text: "✓ fertig · \(s.titel)", wichtig: false)
            fertigBis = Date().addingTimeInterval(6)
        }
        if let fragt = sitzungen.first(where: { $0.wirksamerZustand == "fragt" }) {
            neu = Meldung(text: "? braucht dich · \(fragt.titel)", wichtig: true)
        } else if neu == nil, let m = modell.meldung, !m.wichtig, let bis = fertigBis, Date() < bis {
            neu = m
        }
        if neu != modell.meldung {
            withAnimation(.spring(duration: 0.35)) { modell.meldung = neu }
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

/// Klopfanimation, wenn eine Sitzung auf eine Eingabe wartet:
/// zwei schnelle Stöße nach vorn, dabei kurze Klopfstriche links und rechts
struct KlopfendeFigur: View {
    let bild: Pixelbild
    let pixel: CGFloat
    let klopft: Bool

    var body: some View {
        TimelineView(.animation(paused: !klopft)) { kontext in
            let stoss = klopft ? Self.stoss(kontext.date.timeIntervalSinceReferenceDate) : 0
            PixelFigur(bild: bild, pixel: pixel)
                .scaleEffect(1 + 0.2 * stoss)
                .overlay { Self.striche(groesse: pixel * 3).opacity(stoss) }
        }
    }

    /// 0…1: zwei kurze Stöße zu Beginn jedes 1,4-Sekunden-Takts
    static func stoss(_ t: TimeInterval) -> Double {
        let p = t.truncatingRemainder(dividingBy: 1.4)
        func buckel(_ mitte: Double) -> Double { max(0, 1 - abs(p - mitte) / 0.08) }
        return max(buckel(0.08), buckel(0.34))
    }

    /// Je drei kurze Striche, die vom Kopf weg nach außen zeigen
    private static func striche(groesse: CGFloat) -> some View {
        Canvas { ctx, size in
            // Die Fläche ist rundum um 2 × groesse größer als die Figur
            let halb = size.width / 2 - groesse * 2
            let mitteY = groesse * 2 + (size.height - groesse * 4) * 0.35
            for seite in [-1.0, 1.0] {
                let x0 = size.width / 2 + seite * (halb + groesse * 0.4)
                for winkel in [-0.5, 0.0, 0.5] {
                    var strich = Path()
                    strich.move(to: CGPoint(x: x0, y: mitteY + winkel * groesse * 1.2))
                    strich.addLine(to: CGPoint(x: x0 + seite * groesse, y: mitteY + winkel * groesse * 2))
                    ctx.stroke(strich, with: .color(Color(white: 0.6)), lineWidth: max(1, groesse / 5))
                }
            }
        }
        .padding(-groesse * 2)
        .allowsHitTesting(false)
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
        let hoehe = offen ? g.hoeheOffen(sitzungen: modell.sitzungen.count)
            : g.notchHoehe + (modell.meldung == nil ? 0 : g.meldungHoehe)
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sitzungsPunkte.frame(width: g.fluegel)
                Color.clear.frame(width: g.notchBreite)
                KlopfendeFigur(bild: modell.bild, pixel: g.pixelKlein, klopft: modell.klopft)
                    .frame(width: g.fluegel)
            }
            .frame(height: g.notchHoehe)
            if let m = modell.meldung {
                Text(m.text)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(m.wichtig ? .white : wert)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: g.meldungHoehe - 4, alignment: .top)
                    .transition(.opacity)
            }
        }
    }

    /// 5-Stunden-Limit des Kontos, ab 80 % weiß; darunter ein Punkt pro offenem Terminal:
    /// weiß wartet auf Eingabe, hellgrau arbeitet, dunkel ruht
    private var sitzungsPunkte: some View {
        let liste = modell.sitzungen.sorted { $0.dauer > $1.dauer }.prefix(Geometrie.maxSitzungen)
        let fuenf = modell.sitzungen.compactMap(\.fuenfStundenProzent).max()
        return VStack(spacing: 4) {
            Text(fuenf.map { "\($0) %" } ?? "")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle((fuenf ?? 0) >= 80 ? .white : wert)
                .lineLimit(1)
                .fixedSize()
            if liste.count > 1 {
                HStack(spacing: 3) {
                    ForEach(Array(liste)) { s in
                        Circle()
                            .fill(s.dringlichkeit >= 3 ? Color.white : s.dringlichkeit == 2 ? Color(white: 0.6) : Color(white: 0.3))
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
    }

    /// Alle offenen Sitzungen untereinander, jede mit eigenem Oktopus; Limits gelten fürs Konto und stehen einmal oben
    private func aufgeklappt(_ g: Geometrie) -> some View {
        let liste = modell.sitzungen.sorted { $0.dauer > $1.dauer }.prefix(Geometrie.maxSitzungen)
        let limits = modell.sitzungen.first(where: { $0.info?.rate_limits != nil })?.limits
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: g.notchHoehe + 6)
            if let limits {
                Text("Limits  " + limits.text)
                    .font(schrift)
                    .foregroundStyle(limits.hervorheben ? .white : etikett)
                    .padding(.bottom, 8)
            }
            if liste.isEmpty {
                HStack(spacing: 14) {
                    PixelFigur(bild: modell.bild, pixel: g.pixelListe)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Schläft").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Text("Keine Claude-Code-Sitzung offen").font(schrift).foregroundStyle(wert)
                    }
                }
                .frame(height: g.zeileHoehe)
            }
            ForEach(Array(liste)) { s in
                zeile(s, g)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func zeile(_ s: Sitzung, _ g: Geometrie) -> some View {
        let cache = s.cache
        return HStack(spacing: 14) {
            KlopfendeFigur(bild: s.bild ?? modell.bild, pixel: g.pixelListe, klopft: s.wirksamerZustand == "fragt")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(s.titel).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(s.jetztText).foregroundStyle(wert).lineLimit(1)
                }
                HStack(spacing: 6) {
                    balken(s.kontextProzent ?? 0)
                    Text(s.kontextText).foregroundStyle(wert)
                }
                HStack(spacing: 0) {
                    Text(s.modellText + " · Cache ").foregroundStyle(etikett)
                    Text(cache.text).foregroundStyle(cache.knapp ? .white : etikett)
                }
                .lineLimit(1)
            }
            .font(schrift)
        }
        .frame(height: g.zeileHoehe)
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
