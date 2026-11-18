import AppKit
import ServiceManagement
import SwiftUI

/// Was links neben der Notch steht
enum Anzeige: String, CaseIterable, Identifiable {
    case fuenfStunden, woche, kontext, nichts
    var id: String { rawValue }

    var titel: String {
        switch self {
        case .fuenfStunden: t("5-Stunden-Limit", "5-hour limit")
        case .woche: t("Wochenlimit", "Weekly limit")
        case .kontext: t("Kontext der vollsten Sitzung", "Context of the fullest session")
        case .nichts: t("Nichts", "Nothing")
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
    Geste(zustand: "wartet", titel: t("Wartet", "Waiting"), text: t("Schaut sich um. Die Sitzung wartet auf deine nächste Nachricht.", "Looks around. The session is waiting for your next message.")),
    Geste(zustand: "hoert", titel: t("Hört zu", "Listening"), text: t("Große Augen, offener Mund. Deine Nachricht ist angekommen.", "Big eyes, open mouth. Your message has arrived.")),
    Geste(zustand: "denkt", titel: t("Denkt nach", "Thinking"), text: t("Blick nach oben, Gedankenblasen. Claude überlegt.", "Looks up, thought bubbles. Claude is thinking.")),
    Geste(zustand: "tool", titel: t("Arbeitet", "Working"), text: t("Ein Arm greift nach außen. Claude liest, schreibt oder führt einen Befehl aus.", "One arm reaches out. Claude is reading, writing or running a command.")),
    Geste(zustand: "spricht", titel: t("Spricht", "Talking"), text: t("Der Mund bewegt sich. Claude schreibt eine Antwort.", "The mouth moves. Claude is writing a reply.")),
    Geste(zustand: "fragt", titel: t("Fragt um Erlaubnis", "Asking for permission"), text: t("Winkt mit dem rechten Arm und klopft an die Notch. Claude braucht deine Freigabe.", "Waves the right arm and knocks on the notch. Claude needs your approval.")),
    Geste(zustand: "fertig", titel: t("Fertig", "Done"), text: t("Beide Arme oben. Bleibt so, bis du die Notch aufklappst oder weiterschreibst.", "Both arms up. Stays that way until you open the notch or reply.")),
    Geste(zustand: "fehler", titel: t("Fehler", "Error"), text: t("Kreuzaugen und Tinte. Ein Befehl oder die Anfrage ist fehlgeschlagen.", "Crossed eyes and ink. A command or the request failed.")),
    Geste(zustand: "denkt", helfer: 1, titel: t("Mit Helfern", "With helpers"), text: t("Ein kleiner Oktopus daneben. Unteragenten arbeiten mit.", "A small octopus beside it. Subagents are helping.")),
    Geste(zustand: "schlaeft", titel: t("Schläft", "Asleep"), text: t("Keine Claude-Code-Sitzung offen.", "No Claude Code session open.")),
]

struct EinstellungsAnsicht: View {
    @AppStorage(Schluessel.anzeige) private var anzeige = Anzeige.fuenfStunden.rawValue
    @AppStorage(Schluessel.klopfen) private var klopfen = true
    @State private var beimAnmelden = SMAppService.mainApp.status == .enabled
    @State private var bilder: [String: Pixelbild] = [:]

    var body: some View {
        TabView {
            erklaerung.tabItem { Label(t("Gesten", "Gestures"), systemImage: "questionmark.circle") }
            einstellungen.tabItem { Label(t("Einstellungen", "Settings"), systemImage: "gearshape") }
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
            Section(t("Neben der Notch", "Next to the notch")) {
                Picker(t("Anzeige", "Show"), selection: $anzeige) {
                    ForEach(Anzeige.allCases) { Text($0.titel).tag($0.rawValue) }
                }
                Toggle(t("Bei Erlaubnisfragen an die Notch klopfen", "Knock on the notch for permission requests"), isOn: $klopfen)
            }
            Section(t("Start", "Startup")) {
                Toggle(t("Beim Anmelden starten", "Open at login"), isOn: $beimAnmelden)
                    .onChange(of: beimAnmelden) { _, an in
                        let dienst = SMAppService.mainApp
                        if an { try? dienst.register() } else { try? dienst.unregister() }
                        beimAnmelden = dienst.status == .enabled
                    }
            }
            Section(t("Einrichtung", "Setup")) {
                Text(t("Die Notch-App liest, was die Statuszeile und die Hooks von Claude Code schreiben. Beides wird einmalig eingerichtet, wie in der README beschrieben.", "The notch app reads what the Claude Code status line and hooks write. Both are set up once, as described in the README."))
                    .foregroundStyle(.secondary)
                Link(t("Anleitung auf GitHub", "Setup guide on GitHub"), destination: URL(string: "https://github.com/k4lb1/oktopus#install")!)
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
