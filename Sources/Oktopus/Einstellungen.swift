import AppKit
import ServiceManagement
import SwiftUI

/// Was links neben der Notch steht
enum Anzeige: String, CaseIterable, Identifiable {
    case fuenfStunden, woche, kontext, nichts
    var id: String { rawValue }

    var titel: String {
        switch self {
        case .fuenfStunden: "5-Stunden-Limit"
        case .woche: "Wochenlimit"
        case .kontext: "Kontext der vollsten Sitzung"
        case .nichts: "Nichts"
        }
    }

    /// Prozentwert aus den offenen Sitzungen; Limits gelten fürs Konto, Kontext pro Sitzung
    func prozent(_ sitzungen: [Sitzung]) -> Int? {
        switch self {
        case .fuenfStunden: sitzungen.compactMap(\.fuenfStundenProzent).max()
        case .woche: sitzungen.compactMap(\.wochenProzent).max()
        case .kontext: sitzungen.compactMap(\.kontextProzent).max()
        case .nichts: nil
        }
    }
}

enum Schluessel {
    static let anzeige = "anzeige"
    static let klopfen = "klopfen"
    static let erklaert = "erklaert"
}

/// Ein Zustand der Figur mit Beschreibung, gerendert über statusline.sh wie in der Notch
private struct Geste: Identifiable {
    let zustand: String
    var helfer = 0
    let titel: String
    let text: String
    var id: String { "\(zustand)-\(helfer)" }
}

private let gesten = [
    Geste(zustand: "wartet", titel: "Wartet", text: "Schaut sich um. Die Sitzung wartet auf deine nächste Nachricht."),
    Geste(zustand: "hoert", titel: "Hört zu", text: "Große Augen, offener Mund. Deine Nachricht ist angekommen."),
    Geste(zustand: "denkt", titel: "Denkt nach", text: "Blick nach oben, Gedankenblasen. Claude überlegt."),
    Geste(zustand: "tool", titel: "Arbeitet", text: "Ein Arm greift nach außen. Claude liest, schreibt oder führt einen Befehl aus."),
    Geste(zustand: "spricht", titel: "Spricht", text: "Der Mund bewegt sich. Claude schreibt eine Antwort."),
    Geste(zustand: "fragt", titel: "Fragt um Erlaubnis", text: "Winkt mit dem rechten Arm und klopft an die Notch. Claude braucht deine Freigabe."),
    Geste(zustand: "fertig", titel: "Fertig", text: "Beide Arme oben. Bleibt so, bis du die Notch aufklappst oder weiterschreibst."),
    Geste(zustand: "fehler", titel: "Fehler", text: "Kreuzaugen und Tinte. Ein Befehl oder die Anfrage ist fehlgeschlagen."),
    Geste(zustand: "denkt", helfer: 1, titel: "Mit Helfern", text: "Ein kleiner Oktopus daneben. Unteragenten arbeiten mit."),
    Geste(zustand: "schlaeft", titel: "Schläft", text: "Keine Claude-Code-Sitzung offen."),
]

struct EinstellungsAnsicht: View {
    @AppStorage(Schluessel.anzeige) private var anzeige = Anzeige.fuenfStunden.rawValue
    @AppStorage(Schluessel.klopfen) private var klopfen = true
    @State private var beimAnmelden = SMAppService.mainApp.status == .enabled
    @State private var bilder: [String: Pixelbild] = [:]

    var body: some View {
        TabView {
            erklaerung.tabItem { Label("Gesten", systemImage: "questionmark.circle") }
            einstellungen.tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
        .frame(width: 520, height: 560)
        .task {
            while !Task.isCancelled {
                await bilderLaden()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var erklaerung: some View {
        List(gesten) { g in
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(.black)
                    if let bild = bilder[g.id] { PixelFigur(bild: bild, pixel: 5) }
                }
                .frame(width: 96, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.titel).font(.headline)
                    Text(g.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var einstellungen: some View {
        Form {
            Section("Neben der Notch") {
                Picker("Anzeige", selection: $anzeige) {
                    ForEach(Anzeige.allCases) { Text($0.titel).tag($0.rawValue) }
                }
                Toggle("Bei Erlaubnisfragen an die Notch klopfen", isOn: $klopfen)
            }
            Section("Start") {
                Toggle("Beim Anmelden starten", isOn: $beimAnmelden)
                    .onChange(of: beimAnmelden) { _, an in
                        let dienst = SMAppService.mainApp
                        if an { try? dienst.register() } else { try? dienst.unregister() }
                        beimAnmelden = dienst.status == .enabled
                    }
            }
            Section("Einrichtung") {
                Text("Die Notch-App liest, was die Statuszeile und die Hooks von Claude Code schreiben. Beides wird einmalig eingerichtet, wie in der README beschrieben.")
                    .foregroundStyle(.secondary)
                Link("Anleitung auf GitHub", destination: URL(string: "https://github.com/k4lb1/oktopus#install")!)
            }
        }
        .formStyle(.grouped)
    }

    /// Jede Geste rendern; einmal pro Sekunde, damit Winken und Mundbewegung sichtbar werden
    private func bilderLaden() async {
        let liste = gesten
        let fertig = await Task.detached {
            var ergebnis: [String: Pixelbild] = [:]
            for g in liste {
                ergebnis[g.id] = Figur.rendern(json: nil, zustand: g.zustand, helfer: g.helfer)
            }
            return ergebnis
        }.value
        bilder = fertig
    }
}

/// Das Einstellungsfenster; die App läuft ohne Dock-Symbol und muss sich dafür kurz aktivieren
final class EinstellungsFenster {
    static let shared = EinstellungsFenster()
    private var fenster: NSWindow?

    func zeigen() {
        if fenster == nil {
            let f = NSWindow(contentViewController: NSHostingController(rootView: EinstellungsAnsicht()))
            f.title = "Oktopus"
            f.styleMask = [.titled, .closable]
            f.isReleasedWhenClosed = false
            f.center()
            fenster = f
        }
        NSApp.activate()
        fenster?.makeKeyAndOrderFront(nil)
    }
}
