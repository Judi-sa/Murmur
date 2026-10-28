import Foundation

struct MurmurError: LocalizedError {
    let message: String
    /// Code HTTP quand l'erreur vient d'une API, 0 sinon.
    var status = 0
    init(_ message: String, status: Int = 0) { self.message = message; self.status = status }
    var errorDescription: String? { message }
}

enum Transcriber {
    /// Résout le fournisseur configuré ("auto" préfère Groq, puis OpenAI, puis local).
    static func resolvedProvider(_ cfg: Config.Transcription, env: [String: String]) -> String {
        let p = cfg.provider.lowercased()
        guard p == "auto" else { return p }
        if env["GROQ_API_KEY"] != nil { return "groq" }
        if env["OPENAI_API_KEY"] != nil { return "openai" }
        return "local"
    }

    /// Amorce glissée en tête du prompt de Whisper pour les dictées en français : Whisper imite le
    /// style du prompt, il garde donc les termes anglais au lieu de les écrire « à la française ».
    static let bilingualPrimer = "Dictée en français, avec des termes anglais gardés tels quels : prompt, workflow, landing page, build, deploy."

    /// Transcrit le fichier et renvoie le texte avec le fournisseur réellement utilisé, qui peut
    /// différer du fournisseur configuré quand l'API est tombée et que le repli local a pris le relais.
    /// `previousText` : fin du morceau précédent, pour les dictées découpées en morceaux.
    /// `onFallback` : appelé au moment du basculement vers le local, pour prévenir l'utilisateur.
    static func transcribe(_ wav: URL, cfg: Config.Transcription, env: [String: String],
                           vocabulary: Vocabulary = .empty, previousText: String = "",
                           allowFallback: Bool = true,
                           onFallback: (() async -> Void)? = nil) async throws -> (text: String, provider: String) {
        let provider = resolvedProvider(cfg, env: env)
        let prompt = whisperPrompt(cfg: cfg, vocabulary: vocabulary, previousText: previousText)
        let raw: String
        switch provider {
        case "local":
            raw = try await local(wav, cfg: cfg, prompt: prompt)
        case "groq", "openai":
            do {
                raw = try await apiWithRetry(wav, provider: provider, cfg: cfg, env: env, prompt: prompt)
            } catch {
                guard allowFallback, cfg.fallbackToLocal, isTransient(error), !Task.isCancelled,
                      localAvailable(cfg) else { throw error }
                Log.write("\(provider) injoignable (\(error.localizedDescription)), bascule sur la transcription locale")
                await onFallback?()
                return (scrub(try await local(wav, cfg: cfg, prompt: prompt)), "local (repli)")
            }
        default:
            throw MurmurError("transcription.provider inconnu : \"\(cfg.provider)\"")
        }
        return (scrub(raw), provider)
    }

    /// Le prompt de l'utilisateur reste prioritaire, puis l'amorce bilingue et les termes du
    /// dictionnaire, dans la limite des 224 tokens acceptés par Whisper. Pour un morceau de dictée
    /// découpée, la fin du morceau précédent passe en dernier : c'est ce que Whisper lit comme
    /// « ce qui vient d'être dit », ce qui garde la ponctuation et l'orthographe cohérentes.
    static func whisperPrompt(cfg: Config.Transcription, vocabulary: Vocabulary, previousText: String) -> String {
        var base = cfg.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if cfg.bilingualHint && cfg.language.lowercased() == "fr" {
            base = base.isEmpty ? bilingualPrimer : base + " " + bilingualPrimer
        }
        let tail = String(previousText.suffix(200)).trimmingCharacters(in: .whitespaces)
        let budget = Vocabulary.whisperPromptMaxChars - (tail.isEmpty ? 0 : tail.count + 1)
        let prompt = vocabulary.whisperPrompt(appendingTo: base, maxChars: budget)
        guard !tail.isEmpty else { return prompt }
        return prompt.isEmpty ? tail : prompt + " " + tail
    }

    static func localAvailable(_ cfg: Config.Transcription) -> Bool {
        whisperBinary(cfg) != nil && FileManager.default.fileExists(atPath: modelPath(cfg))
    }

    /// Panne passagère qui mérite une nouvelle tentative : réseau, délai dépassé, erreur serveur
    /// ou quota momentané. Une clé invalide ou un modèle inconnu échoueraient à l'identique.
    static func isTransient(_ error: Error) -> Bool {
        if let e = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(e.code)
        }
        if let e = error as? MurmurError { return e.status >= 500 || e.status == 429 }
        // Connexion refusée sous le réseau (pare-feu, VPN, filtre) : l'erreur remonte en POSIX.
        return (error as NSError).domain == NSPOSIXErrorDomain
    }

    private static func apiWithRetry(_ wav: URL, provider: String, cfg: Config.Transcription,
                                     env: [String: String], prompt: String) async throws -> String {
        let isGroq = provider == "groq"
        let keyName = isGroq ? "GROQ_API_KEY" : "OPENAI_API_KEY"
        guard let key = env[keyName] else { throw MurmurError("\(keyName) absente du .env") }
        let endpoint = isGroq ? "https://api.groq.com/openai/v1/audio/transcriptions"
                              : "https://api.openai.com/v1/audio/transcriptions"
        let model = isGroq ? cfg.groqModel : cfg.openaiModel
        do {
            return try await api(wav, endpoint: endpoint, key: key, model: model, cfg: cfg, prompt: prompt)
        } catch {
            // Hors ligne, une seconde tentative immédiate n'a aucune chance : on passe au repli.
            let offline = (error as? URLError)?.code == .notConnectedToInternet
            guard isTransient(error), !offline, !Task.isCancelled else { throw error }
            Log.write("Transcription \(provider) : \(error.localizedDescription), nouvelle tentative")
            return try await api(wav, endpoint: endpoint, key: key, model: model, cfg: cfg, prompt: prompt)
        }
    }

    /// Génériques de sous-titres appris par Whisper sur les vidéos : il les « entend » dans le
    /// silence ou le souffle. Ils n'ont aucune chance d'être dictés, on les retire où qu'ils soient.
    private static let subtitleCredits =
        #"\s*[^.!?\n]{0,60}Amara\.org[^.!?\n]{0,40}[.!?]?|\s*(Sous[-‑]titrage (Société Radio-Canada|ST' ?\d+|FR\b[^.!?\n]{0,40}|MFP\b[^.!?\n]{0,20})|Sous[-‑]titres réalisés (par|pour) [^.!?\n]{0,50}|Subtitles by [^.!?\n]{0,50})[.!?]?"#

    /// Formules de fin de vidéo : on ne les retire que si elles forment TOUTE la transcription,
    /// parce qu'un script de contenu peut très bien contenir « abonnez-vous » pour de vrai.
    private static let outroOnly =
        #"^(merci d.avoir regardé( cette vidéo)?|merci à tous|abonnez-vous( à la chaîne)?|n.oubliez pas de vous abonner|thanks? (you )?for watching|thank you)[\s.!…]*$"#

    /// Retire les marqueurs non vocaux de Whisper ([BLANK_AUDIO], (musique), ♪), les génériques de
    /// sous-titres inventés, et compacte les espaces.
    static func scrub(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*(music|musique|silence|blank|inaudible|applause|applaudissements|laughs?|rires?)[^)]*\)|♪"#,
                                          with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: subtitleCredits, with: " ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: outroOnly, options: [.regularExpression, .caseInsensitive]) != nil { return "" }
        return t
    }

    // MARK: whisper.cpp

    static func whisperBinary(_ cfg: Config.Transcription) -> String? {
        let fm = FileManager.default
        if !cfg.whisperBinary.isEmpty {
            return fm.isExecutableFile(atPath: cfg.whisperBinary) ? cfg.whisperBinary : nil
        }
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs {
            for name in ["whisper-cli", "whisper-cpp"] {
                let path = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    static func modelPath(_ cfg: Config.Transcription) -> String {
        let m = cfg.localModel
        if m.hasPrefix("/") || m.hasPrefix("~") { return (m as NSString).expandingTildeInPath }
        return Paths.modelsDir.appendingPathComponent("ggml-\(m).bin").path
    }

    private static func local(_ wav: URL, cfg: Config.Transcription, prompt: String) async throws -> String {
        guard let bin = whisperBinary(cfg) else {
            throw MurmurError("whisper-cli introuvable. Lance : brew install whisper-cpp")
        }
        let model = modelPath(cfg)
        guard FileManager.default.fileExists(atPath: model) else {
            throw MurmurError("Modèle absent : \(model). Lance scripts/download-model.sh \(cfg.localModel)")
        }
        let threads = cfg.threads > 0 ? cfg.threads : max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        var args = ["-m", model, "-f", wav.path, "-nt", "-np", "-l", cfg.language, "-t", String(threads)]
        if !prompt.isEmpty { args += ["--prompt", prompt] }
        if cfg.greedy { args += ["-bs", "1", "-bo", "1"] }
        // Whisper encode toujours une fenêtre de 30 s (1500 trames). La réduire à la durée du clip
        // rend les dictées courtes plusieurs fois plus rapides sur CPU. 16 kHz mono 16 bits = 32 ko/s.
        if cfg.shrinkAudioContext {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: wav.path)[.size] as? Int) ?? 0
            let seconds = Double(max(0, bytes - 44)) / 32_000
            if seconds < 28 {
                // Marge généreuse : une fenêtre trop serrée fait sauter le début du clip.
                let frames = Int(((seconds * 1.5 + 5) * 50 / 64).rounded(.up)) * 64
                args += ["-ac", String(min(1500, max(256, frames)))]
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                // Lecture des pipes en arrière-plan pour qu'une sortie volumineuse ne bloque pas le processus.
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }
                    let stdout = out.fileHandleForReading.readDataToEndOfFile()
                    let stderr = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else if process.terminationStatus != 0 {
                        let tail = String(decoding: stderr.suffix(400), as: UTF8.self)
                        cont.resume(throwing: MurmurError("whisper-cli a quitté avec le code \(process.terminationStatus) : \(tail)"))
                    } else {
                        cont.resume(returning: String(decoding: stdout, as: UTF8.self))
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: Groq / OpenAI (endpoint multipart compatible OpenAI)

    private static func api(_ wav: URL, endpoint: String, key: String, model: String, cfg: Config.Transcription, prompt: String) async throws -> String {
        let boundary = "murmur-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", model)
        field("response_format", "json")
        field("temperature", "0")
        if cfg.language != "auto" { field("language", cfg.language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: wav))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        // Délai proportionnel à la durée : une dictée de 5 s qui n'a pas répondu en 10 s est
        // bloquée, inutile d'attendre une minute avant de réessayer. 16 kHz mono 16 bits = 32 ko/s.
        let seconds = Double(max(0, body.count - 44)) / 32_000
        var req = URLRequest(url: URL(string: endpoint)!, timeoutInterval: min(60, 8 + seconds * 0.5))
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let json = try await HTTP.json(req)
        guard let text = json["text"] as? String else { throw MurmurError("La réponse de transcription ne contient pas de texte") }
        return text
    }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        return URLSession(configuration: c)
    }()

    static func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let snippet = String(decoding: data.prefix(300), as: UTF8.self)
            throw MurmurError("HTTP \(status) de \(req.url?.host ?? "l'API") : \(snippet)", status: status)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MurmurError("Réponse inattendue de \(req.url?.host ?? "l'API")")
        }
        return obj
    }
}
