import Foundation

/// Une correction faite à la main dans la fenêtre Historique, et combien de fois elle a été refaite.
struct LearnedCorrection: Codable, Identifiable {
    /// Forme écrite par Murmur, telle que la personne l'a corrigée.
    var wrong: String
    /// Orthographe choisie par la personne (la dernière saisie fait foi).
    var right: String
    var count: Int
    var firstSeen: String
    var lastSeen: String
    /// true une fois la règle écrite dans vocabulary.txt.
    var applied: Bool

    var id: String { Learning.key(wrong, right) }
}

/// Apprentissage des corrections : ~/.config/murmur/corrections.json.
///
/// Chaque correction enregistrée dans la fenêtre Historique est comparée au texte d'avant. Les mots
/// remplacés sont comptés ; à la N-ième correction identique (history.learnThreshold, 3 par défaut),
/// la règle "erreur => correction" est écrite dans vocabulary.txt, précédée d'un commentaire « # auto ».
/// Elle s'applique dès la dictée suivante, au prompt comme au texte final (Vocabulary.applyCorrections).
enum Learning {
    /// Une correction compte un bloc de 1 à 3 mots remplacé par 1 à 3 mots. Au-delà, c'est une
    /// reformulation, pas une faute d'écoute à rejouer automatiquement.
    static let maxWords = 3

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func key(_ wrong: String, _ right: String) -> String {
        TextMatch.fold(wrong) + "\u{1}" + TextMatch.fold(right)
    }

    static func load() -> [LearnedCorrection] {
        guard let data = try? Data(contentsOf: Paths.correctionsFile),
              let list = try? JSONDecoder().decode([LearnedCorrection].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [LearnedCorrection]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? enc.encode(list) else { return }
        try? data.write(to: Paths.correctionsFile, options: .atomic)
        // Les corrections révèlent des bouts de dictées : lisibles par toi seul.
        chmod(Paths.correctionsFile.path, 0o600)
    }

    /// Les remplacements de mots entre le texte affiché et la version corrigée.
    static func pairs(original: String, edited: String) -> [(wrong: String, right: String)] {
        let blocks = VocabularyAnalyzer.divergentBlocks(raw: original, clean: edited)
        // Texte en grande partie réécrit : c'est une reformulation, pas une série de fautes. Les
        // quelques mots que l'alignement croirait « remplacés » seraient des faux positifs.
        let changed = blocks.reduce(0) { $0 + $1.removed.count }
        let total = VocabularyAnalyzer.tokenize(original).count
        guard changed <= max(maxWords, total * 2 / 5) else { return [] }
        return blocks.compactMap { block in
            guard !block.removed.isEmpty, !block.added.isEmpty,
                  block.removed.count <= maxWords, block.added.count <= maxWords else { return nil }
            let wrong = block.removed.map(\.display).joined(separator: " ")
            let right = block.added.map(\.display).joined(separator: " ")
            // Casse, accents ou type d'apostrophe seuls : rien à apprendre.
            guard TextMatch.fold(wrong) != TextMatch.fold(right) else { return nil }
            // Retirer un tic de langage n'est pas une correction d'orthographe.
            if block.removed.allSatisfy({ VocabularyAnalyzer.fillers.contains($0.key) }) { return nil }
            return (wrong, right)
        }
    }

    /// Compte les corrections d'une modification et écrit les règles qui atteignent le seuil.
    /// Renvoie l'état de chaque correction touchée, pour que la fenêtre l'affiche.
    @discardableResult
    static func record(original: String, edited: String, threshold: Int) -> [LearnedCorrection] {
        let found = pairs(original: original, edited: edited)
        guard !found.isEmpty else { return [] }
        var list = load()
        let now = isoFormatter.string(from: Date())
        var touched: [LearnedCorrection] = []
        for (wrong, right) in found {
            let k = key(wrong, right)
            var item: LearnedCorrection
            if let i = list.firstIndex(where: { $0.id == k }) {
                list[i].count += 1
                list[i].right = right
                list[i].lastSeen = now
                item = list[i]
            } else {
                item = LearnedCorrection(wrong: wrong, right: right, count: 1, firstSeen: now, lastSeen: now, applied: false)
                list.append(item)
            }
            if !item.applied && item.count >= max(1, threshold) {
                let day = String(now.prefix(10))
                if Vocabulary.appendRule(wrong: item.wrong, right: item.right, comment: "# auto, appris le \(day)") {
                    item.applied = true
                    if let i = list.firstIndex(where: { $0.id == k }) { list[i].applied = true }
                    Log.write("Correction apprise et ajoutée au dictionnaire (\(item.count) fois)")
                }
            }
            touched.append(item)
        }
        save(list)
        return touched
    }

    /// Oublie une correction : son compteur, et sa règle dans vocabulary.txt si elle y était.
    static func forget(_ item: LearnedCorrection) {
        save(load().filter { $0.id != item.id })
        if item.applied { Vocabulary.removeRule(wrong: item.wrong, right: item.right) }
    }
}
