import Foundation

/// Historique des dictées : ~/.config/murmur/history.jsonl, une ligne JSON par dictée.
///
/// VIE PRIVÉE : ce fichier contient le TEXTE de tes dictées. Il est donc, dans le même esprit
/// que `logTranscripts`, entièrement conditionné à `history.enabled`, qui vaut **false par défaut**.
/// Tant que la clé n'est pas passée à true à la main, rien n'est créé, rien n'est écrit, pas un
/// octet ne touche le disque. Le fichier est créé en chmod 600 (lisible par toi seul).
///
/// L'écriture se fait hors du chemin critique de la dictée (file d'attente dédiée, appel
/// « tire et oublie ») : elle ne retarde jamais le collage du texte et une erreur d'écriture
/// ne peut pas faire échouer une dictée.
struct HistoryEntry: Codable {
    /// Horodatage ISO 8601 de la fin de la dictée.
    var date: String
    /// Durée de l'audio enregistré, en secondes.
    var audioSeconds: Double
    /// Temps passé dans la transcription seule.
    var transcribeSeconds: Double
    /// Temps total transcription + nettoyage.
    var totalSeconds: Double
    /// Provider de transcription réellement utilisé ("local", "groq", "openai").
    var provider: String
    /// Identifiant de bundle de l'app active au démarrage de l'enregistrement.
    var appBundleID: String
    /// Nom affichable de cette app.
    var appName: String
    /// Transcription brute, avant nettoyage.
    var raw: String
    /// Texte finalement inséré (avant l'espace de fin éventuelle).
    var clean: String
    /// Identifiant stable, pour corriger une entrée depuis la fenêtre Historique. Les lignes
    /// écrites avant la 1.2 n'en ont pas : elles en reçoivent un au premier chargement.
    var id: String?
    /// Texte corrigé à la main dans la fenêtre Historique. nil tant que rien n'a été corrigé.
    var edited: String?

    /// Le texte tel que la personne le voit : sa correction si elle en a fait une.
    var shown: String { edited ?? clean }
    /// Identifiant pour l'interface, jamais vide.
    var uid: String { id ?? date }
}

enum History {
    /// File dédiée : l'écriture est séquentielle et n'emprunte jamais le thread de la dictée.
    private static let queue = DispatchQueue(label: "murmur.history")

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: Écriture

    /// Enregistre une dictée. Ne fait STRICTEMENT rien si `cfg.enabled` est false.
    /// Retourne immédiatement : tout le travail disque est différé.
    static func record(_ entry: HistoryEntry, cfg: Config.History) {
        guard cfg.enabled else { return }
        queue.async {
            append(entry, maxEntries: cfg.maxEntries)
        }
    }

    /// Construit une entrée à partir des éléments de la dictée en cours.
    static func makeEntry(date: Date = Date(), audioSeconds: Double, transcribeSeconds: Double,
                          totalSeconds: Double, provider: String, app: AppContext?,
                          raw: String, clean: String) -> HistoryEntry {
        HistoryEntry(date: isoFormatter.string(from: date),
                     audioSeconds: (audioSeconds * 1000).rounded() / 1000,
                     transcribeSeconds: (transcribeSeconds * 1000).rounded() / 1000,
                     totalSeconds: (totalSeconds * 1000).rounded() / 1000,
                     provider: provider,
                     appBundleID: app?.bundleID ?? "",
                     appName: app?.name ?? "",
                     raw: raw,
                     clean: clean,
                     id: UUID().uuidString)
    }

    private static func append(_ entry: HistoryEntry, maxEntries: Int) {
        let enc = JSONEncoder()
        // Une ligne = un objet JSON : pas de saut de ligne dans la sortie, et des accents lisibles.
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let url = Paths.historyFile
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // Création avec les bons droits dès le départ : le fichier ne doit jamais
            // exister ne serait-ce qu'un instant en lecture pour les autres comptes.
            fm.createFile(atPath: url.path, contents: nil,
                          attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        if let d = line.data(using: .utf8) { handle.write(d) }
        try? handle.close()
        // Ceinture et bretelles : un fichier créé avant cette version garde peut-être 644.
        chmod(url.path, 0o600)

        rotate(maxEntries: maxEntries)
    }

    /// Élague les lignes les plus anciennes pour que le fichier ne grossisse pas indéfiniment.
    /// On ne réécrit qu'au-delà d'une marge de 10 % du plafond : sans ça, chaque dictée
    /// provoquerait une réécriture complète une fois le plafond atteint.
    private static func rotate(maxEntries: Int) {
        guard maxEntries > 0 else { return }
        let slack = max(50, maxEntries / 10)
        guard let text = try? String(contentsOf: Paths.historyFile, encoding: .utf8) else { return }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > maxEntries + slack else { return }
        lines.removeFirst(lines.count - maxEntries)
        let out = lines.joined(separator: "\n") + "\n"
        try? out.write(to: Paths.historyFile, atomically: true, encoding: .utf8)
        // Une écriture atomique remplace le fichier : les droits sont à réappliquer.
        chmod(Paths.historyFile.path, 0o600)
    }

    // MARK: Correction depuis la fenêtre Historique

    /// Charge l'historique en donnant un identifiant aux anciennes lignes qui n'en ont pas.
    /// La réécriture passe par la file d'écriture : elle ne croise jamais un ajout en cours.
    static func loadForEditing() -> [HistoryEntry] {
        queue.sync {
            var entries = load()
            guard entries.contains(where: { $0.id == nil }) else { return entries }
            for i in entries.indices where entries[i].id == nil { entries[i].id = UUID().uuidString }
            rewrite(entries)
            return entries
        }
    }

    /// Enregistre la correction d'une entrée. Renvoie false si l'entrée n'existe plus (élaguée).
    @discardableResult
    static func update(id: String, edited: String) -> Bool {
        queue.sync {
            var entries = load()
            guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[i].edited = edited
            rewrite(entries)
            return true
        }
    }

    private static func rewrite(_ entries: [HistoryEntry]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        let lines = entries.compactMap { (try? enc.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
        let out = lines.joined(separator: "\n") + "\n"
        try? out.write(to: Paths.historyFile, atomically: true, encoding: .utf8)
        chmod(Paths.historyFile.path, 0o600)
    }

    // MARK: Lecture

    /// Relit l'historique. Les lignes illisibles (fichier tronqué, version antérieure) sont ignorées.
    static func load() -> [HistoryEntry] {
        guard let text = try? String(contentsOf: Paths.historyFile, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? dec.decode(HistoryEntry.self, from: data)
        }
    }
}

// MARK: - Suggestions de vocabulaire

/// Une correction que le nettoyage applique de façon récurrente : bon candidat pour
/// une règle "erreur => correction" dans vocabulary.txt.
struct VocabularySuggestion {
    var wrong: String
    var right: String
    var count: Int

    /// La ligne telle qu'elle sera ajoutée au dictionnaire.
    var rule: String { "\(wrong) => \(right)" }
}

enum VocabularyAnalyzer {
    /// Repère les mots que le nettoyage remplace toujours par les mêmes, sur l'ensemble
    /// de l'historique. Les corrections déjà présentes dans vocabulary.txt sont écartées.
    static func suggestions(from entries: [HistoryEntry], minOccurrences: Int,
                            existing: Vocabulary = .load()) -> [VocabularySuggestion] {
        var counts: [String: (wrong: String, right: String, n: Int)] = [:]
        for entry in entries {
            for pair in corrections(raw: entry.raw, clean: entry.shown) {
                let key = pair.wrong.lowercased() + "\u{1}" + pair.right.lowercased()
                if var c = counts[key] {
                    c.n += 1
                    counts[key] = c
                } else {
                    counts[key] = (pair.wrong, pair.right, 1)
                }
            }
        }

        // Une règle déjà écrite dans le dictionnaire n'a plus rien à suggérer.
        let known = Set(existing.corrections.map { $0.wrong.lowercased() + "\u{1}" + $0.right.lowercased() })

        return counts
            .filter { $0.value.n >= max(1, minOccurrences) && !known.contains($0.key) }
            .map { VocabularySuggestion(wrong: $0.value.wrong, right: $0.value.right, count: $0.value.n) }
            // Les plus fréquentes d'abord, puis par ordre alphabétique pour un menu stable.
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.wrong.lowercased() < $1.wrong.lowercased() }
    }

    // MARK: Diff au niveau des mots

    struct Token {
        /// Le mot tel qu'il apparaît dans le texte, ponctuation retirée.
        var display: String
        /// Forme comparable : minuscules, sans accents ni ponctuation.
        var key: String
    }

    /// Découpe en mots comparables. La ponctuation et la casse disparaissent : le nettoyage
    /// en ajoute systématiquement et ce ne sont pas des corrections de vocabulaire.
    static func tokenize(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace })
            .compactMap { raw in
                let display = String(raw).trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                guard !display.isEmpty else { return nil }
                // Apostrophes et tirets unifiés : « c'est » contre « c’est » n'est pas une erreur d'écoute.
                let key = TextMatch.fold(display)
                return Token(display: display, key: key)
            }
    }

    /// Les tics de langage que le prompt de nettoyage supprime de toute façon : leur disparition
    /// n'est pas une correction d'orthographe, il ne faut jamais en faire une suggestion.
    static let fillers: Set<String> = [
        "euh", "euhm", "hum", "hmm", "heu", "bah", "ben", "bon", "alors", "genre",
        "voila", "voilà", "quoi", "donc", "enfin", "tu", "vois", "disons", "en", "fait",
    ]

    /// Aligne les deux textes et récupère les substitutions de mot à mot.
    /// Les insertions pures et les suppressions pures (tics retirés, ponctuation, reformulations)
    /// sont ignorées : seul un mot REMPLACÉ par un autre mot indique une erreur de transcription.
    static func corrections(raw: String, clean: String) -> [(wrong: String, right: String)] {
        divergentBlocks(raw: raw, clean: clean).flatMap { pairUp($0.removed, $0.added) }
    }

    /// Les blocs où les deux textes divergent, après alignement LCS des mots.
    static func divergentBlocks(raw: String, clean: String) -> [(removed: [Token], added: [Token])] {
        let a = tokenize(raw)
        let b = tokenize(clean)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // Garde-fou : la table LCS est quadratique, une dictée très longue ne doit pas
        // faire ramer le menu. Au-delà, on renonce à analyser cette entrée.
        guard a.count * b.count <= 400_000 else { return [] }

        // LCS classique sur les formes normalisées.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i].key == b[j].key ? lcs[i + 1][j + 1] + 1
                                                 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var result: [(removed: [Token], added: [Token])] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i].key == b[j].key { i += 1; j += 1; continue }
            // Un bloc divergent : on collecte les mots supprimés d'un côté, ajoutés de l'autre.
            var removed: [Token] = [], added: [Token] = []
            while i < a.count && j < b.count && a[i].key != b[j].key {
                if lcs[i + 1][j] >= lcs[i][j + 1] {
                    removed.append(a[i]); i += 1
                } else {
                    added.append(b[j]); j += 1
                }
            }
            // Un bloc qui finit le texte d'un côté : le reste de l'autre côté lui appartient.
            if i == a.count || j == b.count {
                removed += a[i...]; added += b[j...]
                i = a.count; j = b.count
            }
            result.append((removed, added))
        }
        return result
    }

    /// Apparie les mots d'un bloc divergent. On ne garde que les remplacements plausibles :
    /// même nombre de mots des deux côtés (ou un pour un), et formes suffisamment proches
    /// pour qu'il s'agisse d'une erreur d'écoute plutôt que d'une reformulation.
    private static func pairUp(_ removed: [Token], _ added: [Token]) -> [(wrong: String, right: String)] {
        guard !removed.isEmpty, removed.count == added.count else { return [] }
        var out: [(wrong: String, right: String)] = []
        for (r, a) in zip(removed, added) {
            if fillers.contains(r.key) || fillers.contains(a.key) { continue }
            // Casse et accents seuls : déjà neutralisés par la clé, donc rien à suggérer.
            if r.key == a.key { continue }
            guard isPlausibleMisheard(r.key, a.key) else { continue }
            out.append((r.display, a.display))
        }
        return out
    }

    /// Deux mots sont considérés comme la même erreur d'écoute quand ils se ressemblent
    /// assez (distance d'édition ≤ 40 % de la longueur). Ça écarte les reformulations
    /// ("rapidement" → "vite") tout en gardant les écorchures ("mien mien" → "Murmur").
    private static func isPlausibleMisheard(_ a: String, _ b: String) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        let maxLen = max(a.count, b.count)
        let budget = max(1, Int(Double(maxLen) * 0.4))
        return levenshtein(Array(a), Array(b), limit: budget) <= budget
    }

    /// Distance d'édition, abandonnée dès que `limit` est dépassé (deux mots très différents
    /// ne méritent pas de calculer la valeur exacte).
    private static func levenshtein(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var best = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                best = min(best, cur[j])
            }
            if best > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

// MARK: - Écriture dans le dictionnaire

extension Vocabulary {
    /// Ajoute une règle "erreur => correction" à la fin de vocabulary.txt, précédée d'un
    /// commentaire facultatif (« # auto… » pour les règles apprises).
    /// Le fichier est relu à chaque dictée : la règle s'applique sans redémarrage.
    @discardableResult
    static func appendRule(wrong: String, right: String, comment: String? = nil) -> Bool {
        let rule = "\(wrong) => \(right)"
        var text = (try? String(contentsOf: Paths.vocabularyFile, encoding: .utf8)) ?? ""
        // Idempotent : cliquer deux fois sur la même suggestion n'écrit pas deux lignes.
        let already = text.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == rule.lowercased()
        }
        if already { return true }
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if let comment { text += comment + "\n" }
        text += rule + "\n"
        do {
            try text.write(to: Paths.vocabularyFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.write("Impossible d'écrire dans vocabulary.txt : \(error.localizedDescription)")
            return false
        }
    }

    /// Retire une règle, et le commentaire « # auto » qui la précède s'il y en a un.
    static func removeRule(wrong: String, right: String) {
        guard let text = try? String(contentsOf: Paths.vocabularyFile, encoding: .utf8) else { return }
        let rule = "\(wrong) => \(right)".lowercased()
        var lines = text.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == rule }) else { return }
        lines.remove(at: i)
        if i > 0, lines[i - 1].hasPrefix("# auto") { lines.remove(at: i - 1) }
        try? lines.joined(separator: "\n").write(to: Paths.vocabularyFile, atomically: true, encoding: .utf8)
    }
}
