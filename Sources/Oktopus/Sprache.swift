import Foundation

/// Deutsch, wenn die bevorzugte Systemsprache Deutsch ist, sonst Englisch; wie in statusline.sh
enum Sprache {
    static let deutsch = Locale.preferredLanguages.first?.hasPrefix("de") ?? false
}

func t(_ deutsch: String, _ englisch: String) -> String { Sprache.deutsch ? deutsch : englisch }
