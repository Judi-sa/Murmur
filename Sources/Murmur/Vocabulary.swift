import Foundation

/// Dictionnaire personnel de vocabulaire : ~/.config/murmur/vocabulary.txt.
///
/// Un terme par ligne. Les lignes vides et celles qui commencent par # sont ignorées.
/// Une ligne peut aussi porter une correction explicite sous la forme "erreur => correction"
/// (ex : "Mian Mian => Murmur") quand Whisper se trompe toujours de la même façon.
///
/// Relu à chaque dictée comme le .env : ajouter un terme ne demande pas de redémarrage.
struct Vocabulary {
    /// Les termes à faire reconnaître, dans l'ordre du fichier (les cibles des corrections incluses).
    var terms: [String] = []
    /// Les règles explicites erreur → correction.
    var corrections: [(wrong: String, right: String)] = []

    var isEmpty: Bool { terms.isEmpty && corrections.isEmpty }

    static let empty = Vocabulary()

    // MARK: Chargement

    /// Relu à chaque dictée. Renvoie un dictionnaire vide si le fichier est absent ou illisible,
    /// pour que le comportement reste exactement celui d'avant.
    static func load() -> Vocabulary {
        guard let text = try? String(contentsOf: Paths.vocabularyFile, encoding: .utf8) else { return .empty }
        return parse(text)
    }

    static func parse(_ text: String) -> Vocabulary {
        var vocab = Vocabulary()
        var seen = Set<String>()
        func addTerm(_ term: String) {
            // Dédoublonnage insensible à la casse : le prompt de Whisper est une ressource rare.
            let key = term.lowercased()
            guard !term.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            vocab.terms.append(term)
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let range = line.range(of: "=>") {
                let wrong = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !wrong.isEmpty, !right.isEmpty else { continue }
                vocab.corrections.append((wrong, right))
                // La forme correcte est aussi un terme à souffler à Whisper.
                addTerm(right)
            } else {
                addTerm(line)
            }
        }
        return vocab
    }

    // MARK: Injection dans le prompt de Whisper

    /// Whisper plafonne son initial prompt à 224 tokens et jette silencieusement le reste :
    /// on estime ~1 token pour 4 caractères et on garde une marge confortable.
    static let whisperPromptMaxChars = 700

    /// Concatène le prompt de l'utilisateur (prioritaire, jamais écrasé) et les termes du dictionnaire,
    /// en tronquant sur une limite de terme pour ne pas couper un nom propre en deux.
    func whisperPrompt(appendingTo userPrompt: String, maxChars: Int = Vocabulary.whisperPromptMaxChars) -> String {
        let base = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terms.isEmpty else { return base }

        // Le prompt de l'utilisateur passe en premier : s'il remplit déjà le budget, rien n'est ajouté.
        var budget = maxChars - base.count
        if !base.isEmpty { budget -= 1 }
        guard budget > 0 else { return base }

        var kept: [String] = []
        for term in terms {
            let cost = term.count + (kept.isEmpty ? 0 : 2) // ", "
            if cost > budget { break }
            budget -= cost
            kept.append(term)
        }
        guard !kept.isEmpty else { return base }

        let list = kept.joined(separator: ", ")
        return base.isEmpty ? list : base + " " + list
    }

    // MARK: Injection dans le prompt système du nettoyage

    /// Section ajoutée au prompt système du Cleaner. Volontairement courte et impérative :
    /// le garde-fou de longueur du Cleaner ne tolère pas un modèle qui se met à commenter.
    func cleanupPromptSection() -> String {
        guard !isEmpty else { return "" }
        var parts: [String] = []
        if !terms.isEmpty {
            parts.append("""
            Vocabulaire attendu de la personne : \(terms.joined(separator: ", ")).
            Si un mot de la transcription est phonétiquement proche de l'un d'eux, remplace-le par l'orthographe exacte ci-dessus. Ne force aucun de ces termes quand rien ne leur ressemble, et n'en ajoute jamais un qui n'a pas été dit.
            """)
        }
        if !corrections.isEmpty {
            let rules = corrections.map { "\"\($0.wrong)\" → \"\($0.right)\"" }.joined(separator: " ; ")
            parts.append("Corrections systématiques à appliquer : \(rules).")
        }
        return "\n" + parts.joined(separator: "\n")
    }
}

// MARK: - Application déterministe des règles

extension Vocabulary {
    /// Applique les règles "erreur => correction" directement sur le texte final.
    ///
    /// Le prompt du nettoyage les cite déjà, mais un LLM peut les ignorer, et le nettoyage peut
    /// être sauté (profil, panne, délai). Ce remplacement garantit que l'orthographe choisie par
    /// la personne gagne à chaque fois. Il porte sur des mots entiers, sans tenir compte de la
    /// casse, des accents ni du type d'apostrophe, et garde la majuscule d'un début de phrase.
    func applyCorrections(_ text: String) -> String {
        guard !corrections.isEmpty, !text.isEmpty else { return text }
        var out = text
        // Les règles les plus longues d'abord : "Mian Mian" doit passer avant un éventuel "Mian".
        let rules = corrections
            .map { (wrong: TextMatch.words($0.wrong).map(\.key), right: $0.right) }
            .filter { !$0.wrong.isEmpty }
            .sorted { $0.wrong.count > $1.wrong.count }
        for rule in rules {
            out = TextMatch.replace(rule.wrong, with: rule.right, in: out)
        }
        return out
    }
}

/// Outils de comparaison de mots partagés par le dictionnaire, l'apprentissage et les raccourcis.
enum TextMatch {
    struct Word {
        var range: Range<String.Index>
        /// Forme comparable : minuscules, sans accents, apostrophes et tirets unifiés.
        var key: String
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’‑-][\p{L}\p{N}]+)*"#)

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‑", with: "-")
    }

    static func words(_ text: String) -> [Word] {
        let ns = NSRange(text.startIndex..., in: text)
        return wordPattern.matches(in: text, range: ns).compactMap { m in
            guard let r = Range(m.range, in: text) else { return nil }
            return Word(range: r, key: fold(String(text[r])))
        }
    }

    /// Remplace chaque occurrence de la suite de mots `wrong` (formes repliées) par `right`.
    /// Les mots doivent se suivre, séparés uniquement par des espaces.
    static func replace(_ wrong: [String], with right: String, in text: String) -> String {
        let ws = words(text)
        guard ws.count >= wrong.count, !wrong.isEmpty else { return text }
        var hits: [(Range<String.Index>, String)] = []
        var i = 0
        while i + wrong.count <= ws.count {
            let window = ws[i..<(i + wrong.count)]
            let same = zip(window, wrong).allSatisfy { $0.key == $1 }
            let contiguous = zip(window, window.dropFirst()).allSatisfy { a, b in
                text[a.range.upperBound..<b.range.lowerBound].allSatisfy(\.isWhitespace)
            }
            if same && contiguous {
                let range = window.first!.range.lowerBound..<window.last!.range.upperBound
                let original = text[range]
                var replacement = right
                // Début de phrase en majuscule, correction écrite en minuscule : on garde la majuscule.
                if let o = original.first, o.isUppercase, let r = replacement.first, r.isLowercase {
                    replacement = r.uppercased() + replacement.dropFirst()
                }
                if original != replacement { hits.append((range, replacement)) }
                i += wrong.count
            } else {
                i += 1
            }
        }
        var out = text
        // De la fin vers le début : les index des remplacements suivants restent valides.
        for (range, replacement) in hits.reversed() {
            out.replaceSubrange(range, with: replacement)
        }
        return out
    }
}

/// Retouches typographiques sûres, appliquées au texte final des dictées en français.
enum Typography {
    /// Mots qui s'élident légitimement devant une apostrophe : « qu’il », « l’état », « jusqu’à ».
    private static let elisions: Set<String> = [
        "c", "d", "j", "l", "m", "n", "s", "t", "qu", "jusqu", "lorsqu", "puisqu", "quoiqu", "presqu", "quelqu", "aujourd",
    ]
    private static let strayApostrophe = try! NSRegularExpression(pattern: #"(\p{L}+)’(?=\s)"#)
    private static let straightApostrophe = try! NSRegularExpression(pattern: #"(?<=\p{L})'(?=\p{L})"#)

    static func fix(_ text: String, language: String) -> String {
        guard language.lowercased() == "fr", !text.isEmpty else { return text }
        var out = text
        // 1. Apostrophes parasites que Whisper colle après un mot entier (« les’ images ») :
        //    seul un mot élidé peut se terminer par une apostrophe suivie d'un espace.
        let ns = NSRange(out.startIndex..., in: out)
        for m in strayApostrophe.matches(in: out, range: ns).reversed() {
            guard let whole = Range(m.range, in: out), let word = Range(m.range(at: 1), in: out) else { continue }
            if !elisions.contains(TextMatch.fold(String(out[word]))) {
                out.replaceSubrange(whole, with: String(out[word]))
            }
        }
        // 2. Apostrophe droite entre deux lettres : apostrophe typographique française.
        out = straightApostrophe.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                          withTemplate: "’")
        return out
    }
}
