import Foundation

/// Graustufenbild 30×12 Pixel; nil ist durchsichtig, 0 ist Schwarz (Augen, Mund).
struct Pixelbild: Equatable {
    static let breite = 30, hoehe = 12
    var grau = [UInt8?](repeating: nil, count: breite * hoehe)

    subscript(x: Int, y: Int) -> UInt8? {
        get { (0..<Self.breite).contains(x) && (0..<Self.hoehe).contains(y) ? grau[y * Self.breite + x] : nil }
        set {
            guard (0..<Self.breite).contains(x), (0..<Self.hoehe).contains(y) else { return }
            grau[y * Self.breite + x] = newValue
        }
    }
}

/// Die Figur kommt aus statusline.sh, damit Animationen nur an einer Stelle gepflegt werden:
/// Jede der ersten 15 Zellen der sechs Oktopus-Zeilen wird zu 2×2 Pixeln.
enum Figur {
    static let skript = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/statusline.sh").path

    static func rendern(json: Data?, zustand: String?) -> Pixelbild? {
        let prozess = Process()
        prozess.executableURL = URL(fileURLWithPath: "/bin/bash")
        prozess.arguments = [skript]
        var umgebung = ProcessInfo.processInfo.environment
        umgebung["OKTOPUS_APP"] = "1"
        umgebung["OKTOPUS_ZUSTAND"] = zustand
        prozess.environment = umgebung
        let ein = Pipe(), aus = Pipe()
        prozess.standardInput = ein
        prozess.standardOutput = aus
        prozess.standardError = FileHandle.nullDevice
        do { try prozess.run() } catch { return nil }
        ein.fileHandleForWriting.write(json ?? Data(#"{"session_id":""}"#.utf8))
        try? ein.fileHandleForWriting.close()
        let daten = aus.fileHandleForReading.readDataToEndOfFile()
        prozess.waitUntilExit()
        return String(data: daten, encoding: .utf8).map(zerlegen)
    }

    // Viertelblöcke: oben links, oben rechts, unten links, unten rechts
    private static let viertel: [Character: [Bool]] = [
        " ": [false, false, false, false], "█": [true, true, true, true],
        "▀": [true, true, false, false], "▄": [false, false, true, true],
        "▌": [true, false, true, false], "▐": [false, true, false, true],
        "▘": [true, false, false, false], "▝": [false, true, false, false],
        "▖": [false, false, true, false], "▗": [false, false, false, true],
        "▚": [true, false, false, true], "▞": [false, true, true, false],
        "▙": [true, false, true, true], "▟": [false, true, true, true],
        "▛": [true, true, true, false], "▜": [true, true, false, true],
        // Graue Details: Gedankenblasen, Schall, Tinte, Schlaf
        "∘": [false, false, false, true], "°": [true, false, false, false],
        ")": [true, false, false, true], "░": [true, false, false, true],
        "▒": [true, true, false, true], "z": [false, false, false, true],
        "Z": [true, true, true, true],
    ]

    // Münder sind 4×2 Pixel und ragen links und rechts eine Pixelspalte über ihre Zelle hinaus
    private static let muender: [Character: [String]] = [
        "‿": ["X..X", ".XX."],
        "o": [".XX.", ".XX."],
        "O": ["XXXX", ".XX."],
        "-": ["....", ".XX."],
        "∩": [".XX.", "X..X"],
    ]

    static func zerlegen(_ text: String) -> Pixelbild {
        var bild = Pixelbild()
        let zeilen = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
        for (zeile, inhalt) in zeilen.enumerated() {
            let skalare = Array(inhalt.unicodeScalars)
            var vorne: UInt8?, hinten: UInt8?
            var spalte = 0, i = 0
            var muendchen: [(x: Int, muster: [String], farbe: UInt8)] = []
            while i < skalare.count, spalte < 15 {
                if skalare[i] == "\u{1B}" {
                    var j = i + 2, parameter = ""
                    while j < skalare.count, skalare[j] != "m" { parameter.unicodeScalars.append(skalare[j]); j += 1 }
                    farbeSetzen(parameter, &vorne, &hinten)
                    i = j + 1
                    continue
                }
                let zeichen = Character(skalare[i])
                let x = spalte * 2, y = zeile * 2
                if let muster = muender[zeichen] {
                    for k in 0..<4 { bild[x + k % 2, y + k / 2] = hinten }
                    muendchen.append((x - 1, muster, vorne ?? 0))
                } else {
                    let bits = viertel[zeichen] ?? [false, false, false, false]
                    for k in 0..<4 { bild[x + k % 2, y + k / 2] = bits[k] ? (vorne ?? 238) : hinten }
                }
                spalte += 1
                i += 1
            }
            // Münder zuletzt, sonst überschreibt die Nachbarzelle ihre äußeren Pixel
            for m in muendchen {
                for (dy, reihe) in m.muster.enumerated() {
                    for (dx, p) in reihe.enumerated() where p == "X" { bild[m.x + dx, zeile * 2 + dy] = m.farbe }
                }
            }
        }
        return bild
    }

    private static func farbeSetzen(_ parameter: String, _ vorne: inout UInt8?, _ hinten: inout UInt8?) {
        let zahlen = parameter.split(separator: ";").compactMap { Int($0) }
        if zahlen.isEmpty { vorne = nil; hinten = nil; return }
        var k = 0
        while k < zahlen.count {
            switch zahlen[k] {
            case 0: vorne = nil; hinten = nil; k += 1
            case 38 where k + 2 < zahlen.count: vorne = grau(zahlen[k + 2]); k += 3
            case 48 where k + 2 < zahlen.count: hinten = grau(zahlen[k + 2]); k += 3
            case 39: vorne = nil; k += 1
            case 49: hinten = nil; k += 1
            default: k += 1
            }
        }
    }

    /// xterm-256-Farbe auf Grauwert; die Figur nutzt nur die Graurampe und Schwarz
    private static func grau(_ n: Int) -> UInt8 {
        switch n {
        case 232...255: return UInt8(8 + (n - 232) * 10)
        case 16: return 0
        case 15, 231: return 255
        default: return 200
        }
    }
}
