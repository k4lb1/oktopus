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
    var json: Data?
    var info: Statuszeile?

    /// Zustand nach denselben Abklingregeln wie in statusline.sh
    var wirksamerZustand: String {
        let alter = Date().timeIntervalSince1970 - seit
        if alter > 1800 { return "wartet" }
        switch zustand {
        case "hoert" where alter > 2, "fehler" where alter > 4, "spricht" where alter > 3: return "denkt"
        case "fertig" where alter > 4: return "wartet"
        default: return zustand
        }
    }

    var titel: String { info?.session_name ?? info?.model?.display_name ?? "Claude" }

    var modellText: String {
        let name = info?.model?.display_name ?? "?"
        guard let stufe = info?.effort?.level else { return name }
        return "\(name) · Denkstufe \(stufe)"
    }

    var kontextProzent: Int? { info?.context_window?.used_percentage.map { Int($0) } }

    var kontextText: String {
        guard let k = info?.context_window, let p = k.used_percentage else { return "–" }
        let u = k.current_usage
        let belegt = (u?.input_tokens ?? 0) + (u?.output_tokens ?? 0)
            + (u?.cache_creation_input_tokens ?? 0) + (u?.cache_read_input_tokens ?? 0)
        guard let groesse = k.context_window_size else { return "\(Int(p)) %" }
        return "\(Int(p)) % · \(Self.kurz(belegt)) von \(Self.kurz(groesse))"
    }

    /// Limits als Text; hervorheben, sobald eines 80 % erreicht
    var limits: (text: String, hervorheben: Bool) {
        let fuenf = info?.rate_limits?.five_hour, woche = info?.rate_limits?.seven_day
        func teil(_ l: Statuszeile.Limit?, _ format: (Date) -> String) -> String {
            guard let p = l?.used_percentage else { return "–" }
            let bis = l?.resets_at.map { " bis " + format(Date(timeIntervalSince1970: $0)) } ?? ""
            return "\(Int(p)) %\(bis)"
        }
        let text = "5 h \(teil(fuenf, Self.uhr)) · Woche \(teil(woche, Self.tagUhr))"
        let hoch = max(fuenf?.used_percentage ?? 0, woche?.used_percentage ?? 0) >= 80
        return (text, hoch)
    }

    /// Cache-Zustand; knapp, wenn er in weniger als 5 Minuten abläuft
    var cache: (text: String, knapp: Bool) {
        guard let c = info?.prompt_cache else { return ("–", false) }
        guard c.warm == true, let ende = c.expires_at else { return ("kalt", false) }
        let rest = ende - Date().timeIntervalSince1970
        let treffer = Int((c.hit_ratio ?? 0) * 100)
        return ("warm, noch \(max(Int(rest / 60), 0)) min · \(treffer) % Treffer", rest < 300)
    }

    var jetztText: String {
        var was: String
        switch wirksamerZustand {
        case "hoert": was = "hört zu"
        case "denkt": was = "denkt nach"
        case "tool": was = "▶ " + (extra.isEmpty ? "Tool" : extra)
        case "spricht": was = "spricht"
        case "fragt": was = "fragt um Erlaubnis"
        case "fertig": was = "fertig"
        case "fehler": was = "Fehler"
        default: was = "wartet auf dich"
        }
        if helfer > 0 { was += " · \(helfer) Helfer" }
        return was
    }

    var arbeitText: String {
        let c = info?.cost
        let minuten = Int((c?.total_duration_ms ?? 0) / 60000)
        var ort = info?.workspace?.current_dir ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if ort.hasPrefix(home) { ort = "~" + ort.dropFirst(home.count) }
        return "+\(c?.total_lines_added ?? 0) −\(c?.total_lines_removed ?? 0) Zeilen · \(minuten) min · \(ort)"
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
        let tage = ["So", "Mo", "Di", "Mi", "Do", "Fr", "Sa"]
        return tage[Calendar.current.component(.weekday, from: d) - 1] + " " + uhr(d)
    }
}

enum Sitzungen {
    /// Offene Sitzungen, die zuletzt aktive zuerst. Offen ist eine Sitzung, solange ihre Statuszeile läuft.
    static func lesen() -> [Sitzung] {
        let fm = FileManager.default
        guard let namen = try? fm.contentsOfDirectory(atPath: "/tmp") else { return [] }
        let jetzt = Date().timeIntervalSince1970
        var nachId: [String: Sitzung] = [:]
        var offen = Set<String>()

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
        return nachId.values.filter { offen.contains($0.id) }.sorted { $0.seit > $1.seit }
    }
}
