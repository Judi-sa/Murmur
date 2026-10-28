import Foundation

/// Raccourcis vocaux : ~/.config/murmur/snippets.txt, une ligne « déclencheur => texte ».
///
/// Quand la dictée entière correspond à un déclencheur (casse, accents et ponctuation ignorés,
/// « insère » facultatif en tête), le texte associé est collé tel quel, sans nettoyage.
/// Relu à chaque dictée comme vocabulary.txt.
struct Snippets {
    var items: [(trigger: String, text: String)] = []

    static func load() -> Snippets {
        guard let text = try? String(contentsOf: Paths.snippetsFile, encoding: .utf8) else { return Snippets() }
        return parse(text)
    }

    static func parse(_ text: String) -> Snippets {
        var out = Snippets()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let sep = line.range(of: "=>") else { continue }
            let trigger = normalize(String(line[..<sep.lowerBound]))
            let value = line[sep.upperBound...].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n")
            guard !trigger.isEmpty, !value.isEmpty else { continue }
            out.items.append((trigger, value))
        }
        return out
    }

    /// Le texte du raccourci si la dictée n'est QUE son déclencheur, sinon nil.
    func match(_ dictation: String) -> String? {
        guard !items.isEmpty else { return nil }
        var key = Self.normalize(dictation)
        for prefix in ["insere-moi ", "insere moi ", "inserer ", "insere "] where key.hasPrefix(prefix) {
            key.removeFirst(prefix.count)
            break
        }
        return items.first { $0.trigger == key }?.text
    }

    /// Mots repliés (minuscules, sans accents) séparés par une espace, ponctuation retirée.
    static func normalize(_ s: String) -> String {
        TextMatch.words(s).map(\.key).joined(separator: " ")
    }
}
