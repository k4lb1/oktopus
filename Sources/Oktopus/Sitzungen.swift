import Foundation

/// Eingabe, die Claude Code der Statuszeile gibt; statusline.sh legt sie als /tmp/oktopus-<sid>.json ab.
struct Statuszeile: Decodable {
    struct Modell: Decodable { let display_name: String? }
    struct Aufwand: Decodable { let level: String? }
    struct Nutzung: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cache_creation_input_tokens: Int?
        let cache_read_input_tokens: Int?
    }
    struct Kontext: Decodable {
        let used_percentage: Double?
        let context_window_size: Int?
        let current_usage: Nutzung?
    }
    struct Limit: Decodable {
        let used_percentage: Double?
        let resets_at: Double?
    }
    struct Limits: Decodable {
        let five_hour: Limit?
        let seven_day: Limit?
    }
    struct Cache: Decodable {
        let warm: Bool?
        let expires_at: Double?
        let hit_ratio: Double?
    }
    struct Kosten: Decodable {
        let total_lines_added: Int?
        let total_lines_removed: Int?
        let total_duration_ms: Double?
    }
    struct Arbeitsplatz: Decodable { let current_dir: String? }

    let session_name: String?
    let model: Modell?
    let effort: Aufwand?
    let context_window: Kontext?
    let rate_limits: Limits?
    let prompt_cache: Cache?
    let cost: Kosten?
    let workspace: Arbeitsplatz?
}

/// Eine laufende Claude-Code-Sitzung, zusammengesetzt aus den Dateien der Hooks und der Statuszeile.
struct Sitzung: Identifiable {
    let id: String
    var zustand = "wartet"
    var seit: TimeInterval = 0
    var extra = ""
    var helfer = 0
    /// Läuft in der tmux-Sitzung „rc“ von Tentakel; steht in der Notch getrennt und grau mit grünen Augen
    var tentakel = false
    /// Tentakel-Sitzung, während ein Fernzugriff besteht (/tmp/rc-verbunden)
    var fern = false
    /// rc-Sitzung, an der seit 30 s kein Client mehr hängt
    var verlassen = false
    var json: Data?
    var info: Statuszeile?
    var bild: Pixelbild?

    /// Laufzeit der Sitzung; bleibt beim Sortieren stabil, anders als die letzte Aktivität
    var dauer: Double { info?.cost?.total_duration_ms ?? 0 }

    /// Zustand nach denselben Abklingregeln wie in statusline.sh
    var wirksamerZustand: String {
        let alter = Date().timeIntervalSince1970 - seit
        if alter > 1800 { return "wartet" }
        switch zustand {
        case "hoert" where alter > 2, "fehler" where alter > 4, "spricht" where alter > 3: return "denkt"
        default: return zustand
        }
    }

    /// Wie dringend die Sitzung Aufmerksamkeit braucht; die dringendste vertritt alle in der zugeklappten Notch
    var dringlichkeit: Int {
        switch wirksamerZustand {
        case "fragt": return 5
        case "fehler": return 4
        case "fertig": return 3
        case "tool", "spricht", "denkt", "hoert": return 2
        default: return 1
        }
    }

    var titel: String { info?.session_name ?? info?.model?.display_name ?? "Claude" }

    var modellText: String {
        let name = info?.model?.display_name ?? "?"
        guard let stufe = info?.effort?.level else { return name }
        return "\(name) · " + t("Denkstufe", "effort") + " \(stufe)"
    }

    var kontextProzent: Int? { info?.context_window?.used_percentage.map { Int($0) } }

    var fuenfStundenProzent: Int? { info?.rate_limits?.five_hour?.used_percentage.map { Int($0) } }

    var wochenProzent: Int? { info?.rate_limits?.seven_day?.used_percentage.map { Int($0) } }

    var kontextText: String {
        guard let k = info?.context_window, let p = k.used_percentage else { return "–" }
        let u = k.current_usage
        let belegt = (u?.input_tokens ?? 0) + (u?.output_tokens ?? 0)
            + (u?.cache_creation_input_tokens ?? 0) + (u?.cache_read_input_tokens ?? 0)
        guard let groesse = k.context_window_size else { return "\(Int(p)) %" }
        return "\(Int(p)) % · \(Self.kurz(belegt)) " + t("von", "of") + " \(Self.kurz(groesse))"
    }

    /// Limits als Text; hervorheben, sobald eines 80 % erreicht
    var limits: (text: String, hervorheben: Bool) {
        let fuenf = info?.rate_limits?.five_hour, woche = info?.rate_limits?.seven_day
        func teil(_ l: Statuszeile.Limit?, _ format: (Date) -> String) -> String {
            guard let p = l?.used_percentage else { return "–" }
            let bis = l?.resets_at.map { " " + t("bis", "until") + " " + format(Date(timeIntervalSince1970: $0)) } ?? ""
            return "\(Int(p)) %\(bis)"
        }
        let text = "5 h \(teil(fuenf, Self.uhr)) · " + t("Woche", "week") + " \(teil(woche, Self.tagUhr))"
        let hoch = max(fuenf?.used_percentage ?? 0, woche?.used_percentage ?? 0) >= 80
        return (text, hoch)
    }

    /// Cache-Zustand; knapp, wenn er in weniger als 5 Minuten abläuft
    var cache: (text: String, knapp: Bool) {
        guard let c = info?.prompt_cache else { return ("–", false) }
        guard c.warm == true, let ende = c.expires_at else { return (t("kalt", "cold"), false) }
        let rest = ende - Date().timeIntervalSince1970
        let treffer = Int((c.hit_ratio ?? 0) * 100)
        let minuten = max(Int(rest / 60), 0)
        return (t("warm, noch \(minuten) min · \(treffer) % Treffer", "warm, \(minuten) min left · \(treffer) % hits"), rest < 300)
    }

    var jetztText: String {
        var was: String
        switch wirksamerZustand {
        case "hoert": was = t("hört zu", "listening")
        case "denkt": was = t("denkt nach", "thinking")
        case "tool": was = "▶ " + (extra.isEmpty ? "Tool" : extra)
        case "spricht": was = t("spricht", "talking")
        case "fragt": was = t("fragt um Erlaubnis", "asking for permission")
        case "fertig": was = t("fertig", "done")
        case "fehler": was = t("Fehler", "error")
        default: was = t("wartet auf dich", "waiting for you")
        }
        if helfer > 0 { was += " · \(helfer) " + t("Helfer", "helpers") }
        return was
    }

    var arbeitText: String {
        let c = info?.cost
        let minuten = Int((c?.total_duration_ms ?? 0) / 60000)
        var ort = info?.workspace?.current_dir ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if ort.hasPrefix(home) { ort = "~" + ort.dropFirst(home.count) }
        return "+\(c?.total_lines_added ?? 0) −\(c?.total_lines_removed ?? 0) " + t("Zeilen", "lines") + " · \(minuten) min · \(ort)"
    }

    private static func kurz(_ n: Int) -> String {
        n >= 1_000_000 ? "\(n / 1_000_000)M" : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }

    private static func uhr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private static func tagUhr(_ d: Date) -> String {
        let tage = Sprache.deutsch ? ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"] : ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return tage[Calendar.current.component(.weekday, from: d) - 1] + " " + uhr(d)
    }
}

enum Sitzungen {
    /// tmux-Sitzung → seit wann kein Client (iPhone oder `rc` am Mac) mehr dranhängt
    private static var losgelassen: [String: TimeInterval] = [:]
    private static var clients: (stand: TimeInterval, ids: Set<String>)?

    /// IDs der rc-tmux-Sitzungen mit Client; nur alle 2 s abgefragt
    private static func angehaengt(_ jetzt: TimeInterval) -> Set<String> {
        if let clients, jetzt - clients.stand < 2 { return clients.ids }
        let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
        var ids = Set<String>()
        if let tmux {
            let prozess = Process()
            prozess.executableURL = URL(fileURLWithPath: tmux)
            prozess.arguments = ["-L", "rc", "list-clients", "-F", "#{session_id}"]
            let rohr = Pipe()
            prozess.standardOutput = rohr
            prozess.standardError = FileHandle.nullDevice
            if (try? prozess.run()) != nil {
                let daten = rohr.fileHandleForReading.readDataToEndOfFile()
                prozess.waitUntilExit()
                ids = Set(String(decoding: daten, as: UTF8.self).split(separator: "\n").map(String.init))
            }
        }
        clients = (jetzt, ids)
        return ids
    }

    /// Offene Sitzungen, die zuletzt aktive zuerst. Offen ist eine Sitzung, solange ihre Statuszeile läuft.
    static func lesen() -> [Sitzung] {
        let fm = FileManager.default
        guard let namen = try? fm.contentsOfDirectory(atPath: "/tmp") else { return [] }
        let jetzt = Date().timeIntervalSince1970
        var nachId: [String: Sitzung] = [:]
        var offen = Set<String>()
        let iPhoneVerbunden = fm.fileExists(atPath: "/tmp/rc-verbunden")

        for name in namen where name.hasPrefix("oktopus-") {
            let rest = String(name.dropFirst("oktopus-".count))
            let pfad = "/tmp/" + name
            if rest.hasSuffix(".json") {
                let id = String(rest.dropLast(".json".count))
                guard let attr = try? fm.attributesOfItem(atPath: pfad),
                      let geaendert = attr[.modificationDate] as? Date,
                      jetzt - geaendert.timeIntervalSince1970 < 20,
                      let daten = fm.contents(atPath: pfad) else { continue }
                var s = nachId[id] ?? Sitzung(id: id)
                s.json = daten
                s.info = try? JSONDecoder().decode(Statuszeile.self, from: daten)
                nachId[id] = s
                offen.insert(id)
            } else if rest.hasSuffix(".helfer") {
                let id = String(rest.dropLast(".helfer".count))
                var s = nachId[id] ?? Sitzung(id: id)
                s.helfer = (try? fm.contentsOfDirectory(atPath: pfad).count) ?? 0
                nachId[id] = s
            } else if rest.hasSuffix(".rc") {
                let id = String(rest.dropLast(".rc".count))
                var s = nachId[id] ?? Sitzung(id: id)
                s.tentakel = true
                s.fern = iPhoneVerbunden
                // Hängt 30 s niemand mehr an der tmux-Sitzung, verschwindet sie aus der Notch
                if let tmuxId = try? String(contentsOfFile: pfad, encoding: .utf8), !tmuxId.isEmpty {
                    if angehaengt(jetzt).contains(tmuxId) {
                        losgelassen[tmuxId] = nil
                    } else {
                        let seit = losgelassen[tmuxId] ?? jetzt
                        losgelassen[tmuxId] = seit
                        s.verlassen = jetzt - seit > 30
                    }
                }
                nachId[id] = s
            } else if !rest.contains(".") {
                guard let text = try? String(contentsOfFile: pfad, encoding: .utf8) else { continue }
                let teile = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: " ").map(String.init)
                var s = nachId[rest] ?? Sitzung(id: rest)
                s.zustand = teile.first ?? "wartet"
                s.seit = teile.count > 1 ? Double(teile[1]) ?? 0 : 0
                s.extra = teile.count > 2 ? teile[2] : ""
                nachId[rest] = s
            }
        }
        return nachId.values.filter { offen.contains($0.id) && !$0.verlassen }.sorted { $0.seit > $1.seit }
    }
}
