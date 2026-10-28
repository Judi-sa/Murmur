import Foundation

/// Tout est rangé dans ~/.config/murmur : config.json, .env, models/.
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let configDir = home.appendingPathComponent(".config/murmur", isDirectory: true)
    static let configFile = configDir.appendingPathComponent("config.json")
    static let envFile = configDir.appendingPathComponent(".env")
    static let vocabularyFile = configDir.appendingPathComponent("vocabulary.txt")
    /// Historique des dictées, une ligne JSON par dictée. N'existe que si history.enabled est true.
    static let historyFile = configDir.appendingPathComponent("history.jsonl")
    /// Raccourcis vocaux "déclencheur => texte", relus à chaque dictée.
    static let snippetsFile = configDir.appendingPathComponent("snippets.txt")
    /// Compteurs des corrections faites à la main dans la fenêtre Historique.
    static let correctionsFile = configDir.appendingPathComponent("corrections.json")
    /// Audio des dictées dont la transcription a échoué, gardé pour « Réessayer ».
    static let failedDir = configDir.appendingPathComponent("failed", isDirectory: true)
    static let modelsDir = configDir.appendingPathComponent("models", isDirectory: true)
    static let logFile = home.appendingPathComponent("Library/Logs/Murmur.log")
}

struct Config: Codable {
    /// "fn", "right_option", "right_command", "right_control", "right_shift",
    /// "left_option"... ou une combinaison comme "ctrl+option+space".
    var hotkey = "fn"
    /// Touche du mode commande : maintenue sur une sélection, ta parole devient une consigne
    /// qui réécrit le texte sélectionné. Touche modificatrice seule ("right_option"...), "" = désactivé.
    var commandHotkey = "right_option"
    /// Secondes. Un appui plus court que ça est un tap, pas un maintien.
    var tapMaxDuration = 0.30
    /// Secondes entre le relâchement du premier tap et le second appui.
    var doubleTapWindow = 0.40
    /// Durée maximale de tout enregistrement, en secondes (le mode mains libres s'arrête et transcrit).
    var maxRecordingSeconds = 300.0
    /// Les enregistrements dont le pic ne dépasse jamais ce niveau (dBFS) sont jetés comme silence.
    var silenceThresholdDb = -45.0

    var transcription = Transcription()
    var cleanup = Cleanup()
    var insertion = Insertion()
    var vocabulary = Vocabulary()
    var appProfiles = AppProfiles()
    var history = History()
    var pill = Pill()

    var sounds = true
    /// Les transcriptions ne sont jamais écrites dans le journal, sauf si true.
    var logTranscripts = false

    struct Transcription: Codable {
        /// "local" | "groq" | "openai" | "auto" (API si une clé existe, sinon local).
        var provider = "local"
        /// "auto" ou un code ISO comme "fr", "en". Une langue fixe est 2x plus rapide en local.
        var language = "fr"
        /// Nom de modèle ("small", "medium", "small.en"...) ou chemin absolu vers un .bin ggml.
        var localModel = "small"
        /// Vide = recherche dans /opt/homebrew/bin, /usr/local/bin, PATH.
        var whisperBinary = ""
        var threads = 0
        /// Adapte la fenêtre d'encodage de whisper.cpp à la durée du clip au lieu de 30 s fixes (bien plus rapide sur CPU).
        var shrinkAudioContext = true
        /// Décodage glouton au lieu du beam search : ~3x plus rapide, un peu moins précis.
        var greedy = false
        var groqModel = "whisper-large-v3-turbo"
        var openaiModel = "whisper-1"
        /// Indice de vocabulaire facultatif transmis à Whisper (noms propres, jargon).
        var prompt = ""
        /// Amorce bilingue en tête du prompt de Whisper quand la langue est "fr" : les termes
        /// techniques anglais restent en anglais au lieu d'être francisés phonétiquement.
        var bilingualHint = true
        /// API injoignable après une nouvelle tentative : bascule sur whisper.cpp s'il est installé.
        var fallbackToLocal = true
        /// API seulement : les longues dictées sont découpées aux pauses et envoyées pendant
        /// l'enregistrement. Au relâchement, il ne reste que le dernier morceau à transcrire.
        var streaming = true
    }

    struct Cleanup: Codable {
        /// "auto" | "anthropic" | "openai" | "groq" | "none".
        var provider = "auto"
        var anthropicModel = "claude-haiku-4-5"
        var openaiModel = "gpt-4.1-mini"
        var groqModel = "openai/gpt-oss-20b"
        var timeoutSeconds = 10.0
        /// Vide = prompt intégré. La transcription est ajoutée entre balises <transcript>.
        var systemPrompt = ""
        /// Modèle Groq du mode commande : réécrire demande plus de jugement que reponctuer.
        /// Avec Anthropic ou OpenAI, le modèle de nettoyage est réutilisé.
        var commandGroqModel = "openai/gpt-oss-120b"
    }

    /// Dictionnaire personnel (~/.config/murmur/vocabulary.txt), relu à chaque dictée.
    struct Vocabulary: Codable {
        /// false = le fichier est ignoré, quel que soit son contenu.
        var enabled = true
        /// Les termes alimentent le prompt soufflé à Whisper (local et API).
        var useInTranscription = true
        /// Les termes et les règles "erreur => correction" sont ajoutés au prompt système du nettoyage.
        var useInCleanup = true
    }

    /// Consignes de nettoyage par application. L'app est celle qui avait le focus au moment
    /// où la dictée a démarré (voir AppContext).
    struct AppProfiles: Codable {
        /// false = plus aucune influence de l'app sur le nettoyage, comme avant cette fonctionnalité.
        var enabled = true
        /// Ajoute "L'utilisateur dicte dans <App>." au prompt système. Le LLM adapte alors
        /// spontanément le registre ; mets false pour un prompt strictement identique à l'ancien.
        var mentionAppInPrompt = true
        /// Consigne appliquée quelle que soit l'application. Vide par défaut.
        var defaultInstruction = ""
        /// Profils ciblés. Les exemples livrés sont tous `"enabled": false` : rien ne change
        /// tant que l'utilisateur n'en active pas un.
        var profiles: [Profile] = Profile.examples

        struct Profile: Codable {
            /// Purement descriptif, pour s'y retrouver dans le config.json.
            var name = ""
            /// Identifiants de bundle ciblés, comparés sans tenir compte de la casse.
            var bundleIDs: [String] = []
            /// Texte libre ajouté au prompt système du nettoyage.
            var instruction = ""
            /// true = pas de LLM du tout pour cette app, la transcription brute est collée.
            var disableCleanup = false
            /// false = profil présent mais ignoré.
            var enabled = false

            /// Exemples prêts à activer. Volontairement inertes tant que `enabled` reste false,
            /// sauf « Assistants IA », qui couvre l'essentiel des dictées et est actif d'emblée.
            static let examples: [Profile] = [
                Profile(name: "Assistants IA",
                        bundleIDs: ["com.anthropic.claudefordesktop", "com.microsoft.VSCode",
                                    "com.google.Chrome.app.ggjocahimgaohmigbfhghnlfcnjemagj",
                                    "com.openai.chat", "com.todesktop.230313mzl4w4u92"],
                        instruction: "Le texte est un prompt adressé à une IA. Découpe-le en paragraphes, un par idée. Quand la personne énumère plusieurs éléments, mets-les en liste à puces avec des tirets, en gardant ses propres mots et ses tournures (ne passe pas à l'impératif, ne reformule pas). Ne perds aucune idée, aucune contrainte ni aucun détail technique, et garde les termes anglais, noms de fichiers et identifiants tels qu'ils ont été dits.",
                        disableCleanup: false,
                        enabled: true),
                Profile(name: "Terminal",
                        bundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2"],
                        instruction: "N'ajoute aucune ponctuation qui n'a pas été dictée et ne mets pas de majuscule automatique en début de phrase. Respecte à la lettre les commandes, options, chemins et identifiants de code tels qu'ils ont été dits.",
                        disableCleanup: false,
                        enabled: false),
                Profile(name: "Mail",
                        bundleIDs: ["com.apple.mail"],
                        instruction: "Registre formel et professionnel : phrases complètes et bien ponctuées, pas d'abréviations ni de familiarités. Garde les mots de la personne, n'invente ni formule de politesse ni signature.",
                        disableCleanup: false,
                        enabled: false),
                // Murmur ne voit que l'application, pas l'onglet : ce profil s'applique à tout
                // le navigateur, Gmail comme le reste. À n'activer que si ça te convient.
                Profile(name: "Gmail dans le navigateur",
                        bundleIDs: ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.brave.Browser", "company.thebrowser.Browser"],
                        instruction: "Registre formel et professionnel : phrases complètes et bien ponctuées, pas d'abréviations ni de familiarités.",
                        disableCleanup: false,
                        enabled: false),
                Profile(name: "Messagerie rapide",
                        bundleIDs: ["com.tinyspeck.slackmacgap", "com.apple.Notes", "com.apple.MobileSMS"],
                        instruction: "Ton direct et concis : phrases courtes, pas de tournures cérémonieuses. Ne résume pas et ne retire aucune information.",
                        disableCleanup: false,
                        enabled: false),
            ]
        }
    }

    /// Historique des dictées (~/.config/murmur/history.jsonl).
    ///
    /// ATTENTION VIE PRIVÉE : ce fichier contient le texte de tes dictées. Comme `logTranscripts`,
    /// il est donc à false par défaut : tant que tu n'actives pas `history.enabled` à la main,
    /// aucun fichier n'est créé et rien n'est écrit.
    struct History: Codable {
        /// false = rien n'est enregistré, pas même un fichier vide.
        var enabled = false
        /// Plafond de lignes. Les plus anciennes sont élaguées au-delà, pour que
        /// le fichier ne grossisse pas indéfiniment.
        var maxEntries = 2000
        /// Nombre d'occurrences à partir duquel une correction récurrente est proposée
        /// dans le menu « Suggestions de vocabulaire ».
        var suggestionMinOccurrences = 3
        /// Nombre de corrections identiques faites à la main (fenêtre Historique) à partir duquel
        /// la règle est écrite dans vocabulary.txt et appliquée automatiquement.
        var learnThreshold = 3
    }

    struct Insertion: Codable {
        /// "paste" (presse-papiers + Cmd-V) ou "type" (frappes clavier simulées).
        var method = "paste"
        /// false = la transcription reste dans le presse-papiers. true = l'ancien contenu est restauré.
        var restoreClipboard = false
        /// Ajouté après le texte pour que deux dictées consécutives ne se collent pas.
        var trailingSpace = true
    }

    struct Pill: Codable {
        var enabled = true
        /// "bottom" | "top"
        var position = "bottom"
    }
}

// Les clés absentes reprennent leur valeur par défaut : un config.json partiel suffit.
extension Config {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        commandHotkey = try c.decodeIfPresent(String.self, forKey: .commandHotkey) ?? d.commandHotkey
        tapMaxDuration = try c.decodeIfPresent(Double.self, forKey: .tapMaxDuration) ?? d.tapMaxDuration
        doubleTapWindow = try c.decodeIfPresent(Double.self, forKey: .doubleTapWindow) ?? d.doubleTapWindow
        maxRecordingSeconds = try c.decodeIfPresent(Double.self, forKey: .maxRecordingSeconds) ?? d.maxRecordingSeconds
        silenceThresholdDb = try c.decodeIfPresent(Double.self, forKey: .silenceThresholdDb) ?? d.silenceThresholdDb
        transcription = try c.decodeIfPresent(Transcription.self, forKey: .transcription) ?? d.transcription
        cleanup = try c.decodeIfPresent(Cleanup.self, forKey: .cleanup) ?? d.cleanup
        insertion = try c.decodeIfPresent(Insertion.self, forKey: .insertion) ?? d.insertion
        vocabulary = try c.decodeIfPresent(Vocabulary.self, forKey: .vocabulary) ?? d.vocabulary
        appProfiles = try c.decodeIfPresent(AppProfiles.self, forKey: .appProfiles) ?? d.appProfiles
        history = try c.decodeIfPresent(History.self, forKey: .history) ?? d.history
        pill = try c.decodeIfPresent(Pill.self, forKey: .pill) ?? d.pill
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        logTranscripts = try c.decodeIfPresent(Bool.self, forKey: .logTranscripts) ?? d.logTranscripts
    }
}

extension Config.Transcription {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.Transcription()
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        localModel = try c.decodeIfPresent(String.self, forKey: .localModel) ?? d.localModel
        whisperBinary = try c.decodeIfPresent(String.self, forKey: .whisperBinary) ?? d.whisperBinary
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? d.threads
        shrinkAudioContext = try c.decodeIfPresent(Bool.self, forKey: .shrinkAudioContext) ?? d.shrinkAudioContext
        greedy = try c.decodeIfPresent(Bool.self, forKey: .greedy) ?? d.greedy
        groqModel = try c.decodeIfPresent(String.self, forKey: .groqModel) ?? d.groqModel
        openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? d.openaiModel
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? d.prompt
        bilingualHint = try c.decodeIfPresent(Bool.self, forKey: .bilingualHint) ?? d.bilingualHint
        fallbackToLocal = try c.decodeIfPresent(Bool.self, forKey: .fallbackToLocal) ?? d.fallbackToLocal
        streaming = try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? d.streaming
    }
}

extension Config.Cleanup {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.Cleanup()
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? d.provider
        anthropicModel = try c.decodeIfPresent(String.self, forKey: .anthropicModel) ?? d.anthropicModel
        openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? d.openaiModel
        groqModel = try c.decodeIfPresent(String.self, forKey: .groqModel) ?? d.groqModel
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt
        commandGroqModel = try c.decodeIfPresent(String.self, forKey: .commandGroqModel) ?? d.commandGroqModel
    }
}

extension Config.Vocabulary {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.Vocabulary()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        useInTranscription = try c.decodeIfPresent(Bool.self, forKey: .useInTranscription) ?? d.useInTranscription
        useInCleanup = try c.decodeIfPresent(Bool.self, forKey: .useInCleanup) ?? d.useInCleanup
    }
}

extension Config.AppProfiles {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.AppProfiles()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        mentionAppInPrompt = try c.decodeIfPresent(Bool.self, forKey: .mentionAppInPrompt) ?? d.mentionAppInPrompt
        defaultInstruction = try c.decodeIfPresent(String.self, forKey: .defaultInstruction) ?? d.defaultInstruction
        // Une liste absente reprend les exemples ; une liste vide explicite reste vide.
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? d.profiles
    }
}

extension Config.AppProfiles.Profile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.AppProfiles.Profile()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        bundleIDs = try c.decodeIfPresent([String].self, forKey: .bundleIDs) ?? d.bundleIDs
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? d.instruction
        disableCleanup = try c.decodeIfPresent(Bool.self, forKey: .disableCleanup) ?? d.disableCleanup
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    }
}

extension Config.History {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.History()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        maxEntries = try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? d.maxEntries
        suggestionMinOccurrences = try c.decodeIfPresent(Int.self, forKey: .suggestionMinOccurrences) ?? d.suggestionMinOccurrences
        learnThreshold = try c.decodeIfPresent(Int.self, forKey: .learnThreshold) ?? d.learnThreshold
    }
}

extension Config.Insertion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.Insertion()
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? d.method
        restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        trailingSpace = try c.decodeIfPresent(Bool.self, forKey: .trailingSpace) ?? d.trailingSpace
    }
}

extension Config.Pill {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.Pill()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? d.position
    }
}

enum ConfigStore {
    /// Charge config.json et en écrit un par défaut au premier lancement.
    static func load() -> (Config, String?) {
        ensureFiles()
        do {
            let data = try Data(contentsOf: Paths.configFile)
            return (try JSONDecoder().decode(Config.self, from: data), nil)
        } catch {
            let msg = "config.json invalide, réglages par défaut utilisés : \(error.localizedDescription)"
            Log.write(msg)
            return (Config(), msg)
        }
    }

    static func ensureFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Paths.modelsDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Paths.configFile.path) {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? enc.encode(Config()) {
                try? data.write(to: Paths.configFile)
            }
        }
        if !fm.fileExists(atPath: Paths.envFile.path) {
            let template = """
            # Clés API de Murmur. Laisse vide pour rester 100 % local et hors ligne.
            # Transcription (utilisée quand transcription.provider vaut "groq", "openai" ou "auto")
            GROQ_API_KEY=
            OPENAI_API_KEY=
            # LLM de nettoyage (cleanup.provider "auto" choisit Anthropic, puis OpenAI, puis Groq)
            ANTHROPIC_API_KEY=

            """
            try? template.write(to: Paths.envFile, atomically: true, encoding: .utf8)
            chmod(Paths.envFile.path, 0o600)
        }
        if !fm.fileExists(atPath: Paths.vocabularyFile.path) {
            let template = """
            # Dictionnaire personnel de Murmur : les mots que Whisper écorche.
            # Un terme par ligne. Les lignes vides et celles qui commencent par # sont ignorées.
            # Forme "erreur => correction" pour une correction systématique, ex : Mian Mian => Murmur
            # Le fichier est relu à chaque dictée : pas besoin de redémarrer.
            # Ajoute ici ton prénom, le nom de ton entreprise, tes outils...
            Murmur
            Groq
            whisper.cpp

            """
            try? template.write(to: Paths.vocabularyFile, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: Paths.snippetsFile.path) {
            let template = """
            # Raccourcis vocaux de Murmur. Une ligne par raccourci : déclencheur => texte à coller.
            # Dis le déclencheur seul (ou précédé de « insère ») : le texte est collé tel quel, sans nettoyage.
            # La casse, les accents et la ponctuation du déclencheur ne comptent pas. \\n = saut de ligne.
            # Le fichier est relu à chaque dictée : pas besoin de redémarrer.
            # mon lien calendly => https://calendly.com/ton-lien
            # ma signature => Bien cordialement,\\nPrénom Nom

            """
            try? template.write(to: Paths.snippetsFile, atomically: true, encoding: .utf8)
        }
    }
}

enum Env {
    /// Relu à chaque dictée : une clé modifiée s'applique sans redémarrer.
    /// Ordre : ~/.config/murmur/.env, puis un .env à côté de l'app, puis l'environnement du processus.
    static func load() -> [String: String] {
        var result = ProcessInfo.processInfo.environment
        let bundleSibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".env")
        for url in [bundleSibling, Paths.envFile] {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for raw in text.split(whereSeparator: \.isNewline) {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("export ") { line.removeFirst(7) }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" {
                    value = String(value.dropFirst().dropLast())
                }
                if !value.isEmpty { result[key] = value }
            }
        }
        return result
    }
}

enum Log {
    private static let queue = DispatchQueue(label: "murmur.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            FileHandle.standardError.write(line.data(using: .utf8)!)
            let url = Paths.logFile
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
