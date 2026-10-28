import Cocoa

/// La machine à états de la dictée.
///
///   idle ──appui──▶ holding ──relâchement (long)──▶ processing ──▶ collage ──▶ idle
///                      │ relâchement (court) = tap : jeté ; un second tap dans la fenêtre
///                      │ garde le nouvel enregistrement actif en mode mains libres
///                      ▼
///                  handsFree ──appui / durée max──▶ processing
///
/// La touche de commande suit le même chemin (holding ▶ processing), sans mains libres : la
/// parole y est une consigne qui réécrit le texte sélectionné.
///
/// Échap annule depuis holding, handsFree ou processing.
final class DictationController {
    enum State { case idle, holding, handsFree, processing }

    private(set) var state: State = .idle
    var config: Config
    let pill = PillController()
    var onStateChange: ((State) -> Void)?
    /// Dernier texte livré, pour « Recoller la dernière dictée ».
    private(set) var lastInsertedText: String?

    private let recorder = AudioRecorder()
    private var pressedAt = Date.distantPast
    private var lastTapReleasedAt: Date?
    private var ignoreNextRelease = false
    private var tickTimer: Timer?
    private var startSoundWork: DispatchWorkItem?
    private var pipeline: Task<Void, Never>?
    private var generation = 0
    /// L'app qui avait le focus quand l'enregistrement a commencé. Capturée là et pas à la fin,
    /// parce que la pastille et le collage peuvent déplacer le focus entre-temps.
    private var recordingApp: AppContext?
    /// Morceaux déjà envoyés à l'API pendant l'enregistrement en cours, dans l'ordre.
    private var segmentTasks: [Task<String, Error>] = []
    /// L'enregistrement en cours est une commande (touche de commande), pas une dictée.
    private var isCommand = false
    /// Lecture de la sélection, lancée une fois le maintien confirmé (voir commandPressed).
    private var selectionWork: DispatchWorkItem?
    private var selectionTask: Task<String?, Never>?

    init(config: Config) {
        self.config = config
        applyConfig()
        recorder.onLevel = { [weak self] level in self?.pill.model.level = level }
        recorder.onSegment = { [weak self] url in self?.enqueueSegment(url) }
    }

    func applyConfig() {
        pill.enabled = config.pill.enabled
        pill.position = config.pill.position
        pill.model.maxSeconds = config.maxRecordingSeconds
    }

    // MARK: Hotkey events

    func hotkeyPressed() {
        switch state {
        case .idle:
            pressedAt = Date()
            startRecording(command: false)
        case .handsFree:
            ignoreNextRelease = true
            finishRecording()
        case .holding, .processing:
            ignoreNextRelease = true
        }
    }

    func hotkeyReleased() {
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard state == .holding, !isCommand else { return }
        let now = Date()
        let held = now.timeIntervalSince(pressedAt)
        if held >= config.tapMaxDuration {
            finishRecording()
            return
        }
        // Un tap.
        if let last = lastTapReleasedAt, pressedAt.timeIntervalSince(last) <= config.doubleTapWindow {
            lastTapReleasedAt = nil
            setState(.handsFree)
            playStartSound(delay: 0)
            pill.show(.handsFree)
            Log.write("Session mains libres démarrée")
        } else {
            lastTapReleasedAt = now
            discardRecording()
        }
    }

    func commandPressed() {
        guard state == .idle else { return }
        pressedAt = Date()
        startRecording(command: true)
        // La sélection n'est lue qu'une fois le maintien confirmé : un appui bref sur Option droite
        // sert aussi à taper des caractères spéciaux, et le ⌘C de secours ne doit pas partir pour rien.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCommand, self.state == .holding else { return }
            self.selectionTask = Task { @MainActor in await TextInserter.selectedText() }
        }
        selectionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + config.tapMaxDuration, execute: work)
    }

    func commandReleased() {
        guard state == .holding, isCommand else { return }
        if Date().timeIntervalSince(pressedAt) >= config.tapMaxDuration {
            finishRecording()
        } else {
            discardRecording()
        }
    }

    func escapePressed() {
        switch state {
        case .holding, .handsFree:
            discardRecording()
            pill.flash("Annulé")
            Log.write("Enregistrement annulé avec Échap")
        case .processing:
            generation += 1
            pipeline?.cancel()
            pipeline = nil
            setState(.idle)
            pill.flash("Annulé")
            Log.write("Transcription annulée avec Échap")
        case .idle:
            break
        }
    }

    /// Une autre touche a été pressée pendant le maintien du raccourci : l'utilisateur tape un raccourci clavier.
    func otherKeyPressed() {
        guard state == .holding else { return }
        discardRecording()
    }

    /// Désactivation dans la barre de menus ou rechargement des réglages : abandonne tout ce qui est en cours.
    func reset() {
        if state == .holding || state == .handsFree { discardRecording() }
        if state == .processing { escapePressed() }
        pill.hide()
    }

    // MARK: Menu

    /// Relance le pipeline sur l'audio de la dernière dictée échouée.
    func retryLastFailed() {
        guard state == .idle else { return }
        guard let url = FailedAudio.latest() else {
            pill.flash("Aucune dictée échouée à réessayer")
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let duration = Double(max(0, bytes - 44)) / 32_000
        let rec = AudioRecorder.Recording(url: url, tailURL: nil, tailHasSpeech: false, segments: 0)
        isCommand = false
        setState(.processing)
        pill.show(.transcribing)
        generation += 1
        let gen = generation
        let cfg = config
        let app = MainActor.assumeIsolated { AppContext.capture() }
        Log.write("Nouvelle tentative sur \(url.lastPathComponent)")
        pipeline = Task { [weak self] in
            await self?.process(rec: rec, duration: duration, cfg: cfg, gen: gen, app: app, segments: [])
        }
    }

    /// Recolle le dernier texte livré, au curseur de l'app active.
    func repasteLast() {
        guard let text = lastInsertedText else {
            pill.flash("Aucune dictée à recoller")
            return
        }
        // Laisse le menu se refermer et le focus revenir à l'app avant de coller.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.deliver(text, cfg: self?.config ?? Config())
        }
    }

    // MARK: Recording

    private func startRecording(command: Bool) {
        isCommand = command
        segmentTasks = []
        // Le découpage ne sert qu'avec une API : en local, whisper.cpp traite tout d'un bloc.
        let provider = Transcriber.resolvedProvider(config.transcription, env: Env.load())
        recorder.segmenting = !command && config.transcription.streaming && provider != "local"
        recorder.speechThresholdDb = config.silenceThresholdDb
        do {
            try recorder.start()
        } catch {
            Log.write("Erreur micro : \(error.localizedDescription)")
            pill.flash("Micro indisponible", isError: true)
            isCommand = false
            return
        }
        // NSWorkspace est une API AppKit : elle se lit sur le thread principal, où les événements
        // de raccourci arrivent déjà. assumeIsolated l'affirme sans différer la capture.
        recordingApp = MainActor.assumeIsolated { AppContext.capture() }
        setState(.holding)
        pill.show(command ? .command : .hold)
        // Son de départ différé : le premier tap d'un double tap, qui est jeté, reste silencieux.
        playStartSound(delay: config.tapMaxDuration)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private func tick() {
        guard state == .holding || state == .handsFree else { return }
        let elapsed = recorder.duration
        pill.model.elapsed = elapsed
        if elapsed >= config.maxRecordingSeconds {
            Log.write("Durée maximale atteinte (\(Int(config.maxRecordingSeconds)) s), arrêt")
            ignoreNextRelease = (state == .holding && !isCommand)
            finishRecording()
        }
    }

    private func stopTimers() {
        tickTimer?.invalidate()
        tickTimer = nil
        startSoundWork?.cancel()
        startSoundWork = nil
        selectionWork?.cancel()
        selectionWork = nil
    }

    private func cancelSegments() {
        segmentTasks.forEach { $0.cancel() }
        segmentTasks = []
    }

    private func discardRecording() {
        stopTimers()
        recorder.cancel()
        cancelSegments()
        selectionTask?.cancel()
        selectionTask = nil
        isCommand = false
        setState(.idle)
        pill.hide()
    }

    private func finishRecording() {
        stopTimers()
        let peak = recorder.peakDb
        let duration = recorder.duration
        let segments = segmentTasks
        segmentTasks = []
        guard let rec = recorder.stop() else {
            segments.forEach { $0.cancel() }
            isCommand = false
            setState(.idle)
            pill.hide()
            return
        }
        if duration < 0.25 || peak < config.silenceThresholdDb {
            segments.forEach { $0.cancel() }
            Self.remove(rec)
            isCommand = false
            setState(.idle)
            pill.flash("Aucune parole détectée")
            Log.write(String(format: "Enregistrement ignoré : %.2f s, pic %.1f dB", duration, peak))
            return
        }
        playSound("Pop")
        setState(.processing)
        generation += 1
        let gen = generation
        let cfg = config
        let app = recordingApp
        if isCommand {
            isCommand = false
            pill.show(.working("Réécriture"))
            // Maintien juste au-dessus du seuil : la lecture programmée n'a peut-être pas encore eu lieu.
            let selection = selectionTask ?? Task { @MainActor in await TextInserter.selectedText() }
            selectionTask = nil
            pipeline = Task { [weak self] in
                await self?.processCommand(rec: rec, selection: selection, cfg: cfg, gen: gen)
            }
        } else {
            pill.show(.transcribing)
            pipeline = Task { [weak self] in
                await self?.process(rec: rec, duration: duration, cfg: cfg, gen: gen, app: app, segments: segments)
            }
        }
    }

    /// Un morceau vient de se fermer sur une pause : il part tout de suite à l'API. Les morceaux
    /// s'enchaînent pour que chacun reçoive la fin du précédent comme contexte ; la transcription
    /// d'un morceau (~1 s) est bien plus courte que la parole du suivant (12 s ou plus), donc
    /// l'enchaînement ne retarde rien.
    private func enqueueSegment(_ url: URL) {
        guard state == .holding || state == .handsFree else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let previous = segmentTasks.last
        let cfg = config
        let env = Env.load()
        let vocab = cfg.vocabulary.enabled && cfg.vocabulary.useInTranscription ? Vocabulary.load() : .empty
        segmentTasks.append(Task<String, Error> {
            defer { try? FileManager.default.removeItem(at: url) }
            let before = (try? await previous?.value) ?? ""
            try Task.checkCancellation()
            return try await Transcriber.transcribe(url, cfg: cfg.transcription, env: env, vocabulary: vocab,
                                                    previousText: before, allowFallback: false).text
        })
    }

    // MARK: Pipeline

    private func process(rec: AudioRecorder.Recording, duration: TimeInterval, cfg: Config, gen: Int,
                         app: AppContext?, segments: [Task<String, Error>]) async {
        let env = Env.load()
        // Relu à chaque dictée, comme le .env : un terme ajouté s'applique sans redémarrer.
        let vocab = cfg.vocabulary.enabled ? Vocabulary.load() : .empty
        let transcriptionVocab = cfg.vocabulary.useInTranscription ? vocab : .empty
        let onFallback: () async -> Void = { [weak self] in await self?.showFallback(gen) }
        let started = Date()
        do {
            let transcript: (text: String, provider: String)
            if segments.isEmpty {
                transcript = try await Transcriber.transcribe(rec.url, cfg: cfg.transcription, env: env,
                                                              vocabulary: transcriptionVocab, onFallback: onFallback)
            } else {
                transcript = try await joinSegments(segments, rec: rec, cfg: cfg, env: env,
                                                    vocabulary: transcriptionVocab, onFallback: onFallback)
            }
            let raw = transcript.text
            let tTranscribe = Date().timeIntervalSince(started)
            try Task.checkCancellation()
            guard !raw.isEmpty else {
                Self.remove(rec)
                await finish(gen) { $0.pill.flash("Aucune parole détectée") }
                return
            }

            var text = raw
            if let snippet = Snippets.load().match(raw) {
                // Raccourci vocal : le texte est collé tel qu'écrit dans snippets.txt.
                text = snippet
                Log.write("Raccourci vocal inséré")
            } else {
                // Un profil peut demander de coller le texte brut dans cette app (terminal, champ de code...).
                if cfg.appProfiles.cleanupDisabled(for: app) {
                    Log.write("Nettoyage désactivé par le profil de \(app?.logLabel ?? "?")")
                } else {
                    do {
                        text = try await Cleaner.clean(raw, cfg: cfg.cleanup, env: env,
                                                       vocabulary: cfg.vocabulary.useInCleanup ? vocab : .empty,
                                                       appProfiles: cfg.appProfiles, app: app)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        Log.write("Nettoyage ignoré, transcription brute utilisée : \(error.localizedDescription)")
                    }
                }
                // Typographie d'abord, règles du dictionnaire ensuite : l'orthographe choisie par la
                // personne a le dernier mot, même si le nettoyage l'a ignorée ou n'a pas tourné.
                text = Typography.fix(text, language: cfg.transcription.language)
                text = vocab.applyCorrections(text)
            }
            try Task.checkCancellation()

            let total = Date().timeIntervalSince(started)
            // L'app est ajoutée en fin de ligne pour ne pas bousculer le format existant.
            let appSuffix = app.map { ", dans \($0.logLabel)" } ?? ""
            Log.write(String(format: "Dictée %.1f s audio → transcription %.2f s (%@), total %.2f s, %d caractères%@",
                             duration, tTranscribe, transcript.provider, total, text.count, appSuffix))
            if cfg.logTranscripts { Log.write("Brut : \(raw)\nNettoyé : \(text)") }
            // Historique : désactivé par défaut, et de toute façon écrit sur une file dédiée.
            // L'appel rend la main tout de suite, le collage ci-dessous n'attend rien.
            History.record(History.makeEntry(audioSeconds: duration,
                                             transcribeSeconds: tTranscribe,
                                             totalSeconds: total,
                                             provider: transcript.provider,
                                             app: app, raw: raw, clean: text),
                           cfg: cfg.history)
            Self.remove(rec)

            let output = cfg.insertion.trailingSpace ? text + " " : text
            await finish(gen) { controller in
                controller.deliver(output, cfg: cfg)
            }
        } catch is CancellationError {
            // escapePressed a déjà réinitialisé l'état et l'interface.
            Self.remove(rec)
        } catch let error as URLError where error.code == .cancelled {
            // Idem : annulé par Échap.
            Self.remove(rec)
        } catch {
            Log.write("Échec de la dictée : \(error.localizedDescription)")
            // L'audio est gardé : « Réessayer la dernière dictée échouée » le relancera.
            FailedAudio.keep(rec)
            await finish(gen) { $0.pill.flash(Self.shortError(error) + " · menu › Réessayer", isError: true, seconds: 4) }
        }
    }

    /// Assemble les morceaux envoyés pendant l'enregistrement, puis transcrit la fin. Au moindre
    /// échec, l'enregistrement complet est retranscrit d'un bloc : on ne colle jamais un texte troué.
    private func joinSegments(_ segments: [Task<String, Error>], rec: AudioRecorder.Recording, cfg: Config,
                              env: [String: String], vocabulary: Vocabulary,
                              onFallback: @escaping () async -> Void) async throws -> (text: String, provider: String) {
        do {
            let parts: [String] = try await withTaskCancellationHandler {
                var parts: [String] = []
                for t in segments { parts.append(try await t.value) }
                if let tail = rec.tailURL {
                    parts.append(try await Transcriber.transcribe(tail, cfg: cfg.transcription, env: env,
                                                                  vocabulary: vocabulary, previousText: parts.last ?? "",
                                                                  allowFallback: false).text)
                }
                return parts
            } onCancel: {
                segments.forEach { $0.cancel() }
            }
            Log.write("Dictée découpée en \(parts.count) morceaux pendant l'enregistrement")
            let text = parts.filter { !$0.isEmpty }.joined(separator: " ")
            return (text, Transcriber.resolvedProvider(cfg.transcription, env: env))
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            Log.write("Découpage en échec (\(error.localizedDescription)), transcription d'un bloc")
            return try await Transcriber.transcribe(rec.url, cfg: cfg.transcription, env: env,
                                                    vocabulary: vocabulary, onFallback: onFallback)
        }
    }

    private func processCommand(rec: AudioRecorder.Recording, selection: Task<String?, Never>,
                                cfg: Config, gen: Int) async {
        defer { Self.remove(rec) }
        let env = Env.load()
        let vocab = cfg.vocabulary.enabled && cfg.vocabulary.useInTranscription ? Vocabulary.load() : .empty
        do {
            guard let selected = await selection.value else {
                await finish(gen) { $0.pill.flash("Sélectionne d'abord un texte", isError: true, seconds: 2.5) }
                return
            }
            let instruction = try await Transcriber.transcribe(rec.url, cfg: cfg.transcription, env: env,
                                                               vocabulary: vocab).text
            try Task.checkCancellation()
            guard !instruction.isEmpty else {
                await finish(gen) { $0.pill.flash("Aucune consigne entendue") }
                return
            }
            let started = Date()
            let rewritten = try await Commander.rewrite(selection: selected, instruction: instruction,
                                                        cfg: cfg.cleanup, env: env)
            try Task.checkCancellation()
            // Le contenu n'est jamais journalisé, seulement sa taille.
            Log.write(String(format: "Commande : %d → %d caractères en %.2f s", selected.count, rewritten.count,
                             Date().timeIntervalSince(started)))
            await finish(gen) { controller in
                controller.pill.hide()
                // La sélection est toujours active dans l'app : le collage la remplace.
                TextInserter.insert(rewritten, cfg: cfg.insertion)
                controller.lastInsertedText = rewritten
            }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            Log.write("Échec de la commande : \(error.localizedDescription)")
            await finish(gen) { $0.pill.flash(Self.shortError(error), isError: true, seconds: 3) }
        }
    }

    @MainActor
    private func showFallback(_ gen: Int) {
        guard gen == generation, state == .processing else { return }
        pill.show(.working("API injoignable : transcription locale"))
    }

    /// Colle le texte, ou le laisse dans le presse-papiers quand aucun champ ne peut le recevoir.
    private func deliver(_ text: String, cfg: Config) {
        lastInsertedText = text
        let trusted = AXIsProcessTrusted()
        let canPost = CGPreflightPostEventAccess()
        if !trusted || !canPost {
            // Sans Accessibilité (ou avec une autorisation restée attachée à une ancienne compilation),
            // macOS jette le ⌘V simulé sans erreur : le texte n'arriverait nulle part.
            TextInserter.copyOnly(text)
            if !canPost { CGRequestPostEventAccess() }
            pill.flash(.notice("Accessibilité à cocher : ⌘V pour coller", symbol: "lock.fill"), seconds: 4)
            Log.write("Collage impossible (accessibilité \(trusted ? "oui" : "non"), envoi de touches \(canPost ? "oui" : "non")) : dictée copiée dans le presse-papiers")
        } else if TextInserter.hasTextTarget() {
            pill.hide()
            TextInserter.insert(text, cfg: cfg.insertion)
        } else {
            TextInserter.copyOnly(text)
            pill.flash(.notice("Copié : ⌘V pour coller", symbol: "doc.on.clipboard"), seconds: 3)
            Log.write("Aucun champ de texte actif : dictée copiée dans le presse-papiers")
        }
    }

    /// Exécute `body` sur le thread principal seulement si ce traitement n'a pas été annulé ou remplacé.
    @MainActor
    private func finish(_ gen: Int, _ body: (DictationController) -> Void) {
        guard gen == generation, state == .processing else { return }
        pipeline = nil
        setState(.idle)
        body(self)
    }

    private static func shortError(_ error: Error) -> String {
        if let e = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost].contains(e.code) {
            return "Hors ligne"
        }
        let msg = error.localizedDescription
        if msg.contains("whisper-cli introuvable") { return "whisper-cli non installé" }
        if msg.contains("Modèle absent") { return "Modèle Whisper non téléchargé" }
        if msg.contains("absente du .env") { return "Clé API absente du .env" }
        return msg
    }

    private static func remove(_ rec: AudioRecorder.Recording) {
        // L'audio d'une nouvelle tentative réussie vit dans failed/ : il part aussi.
        try? FileManager.default.removeItem(at: rec.url)
        if let tail = rec.tailURL { try? FileManager.default.removeItem(at: tail) }
    }

    // MARK: Helpers

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    private func playStartSound(delay: TimeInterval) {
        startSoundWork?.cancel()
        guard config.sounds else { return }
        let work = DispatchWorkItem { [weak self] in self?.playSound("Tink") }
        startSoundWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func playSound(_ name: String) {
        guard config.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}

/// Audio des dictées dont la transcription a échoué : ~/.config/murmur/failed/, 5 au plus.
enum FailedAudio {
    static let maxKept = 5

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Range l'enregistrement complet. Un fichier déjà dans failed/ (nouvelle tentative) y reste.
    static func keep(_ rec: AudioRecorder.Recording) {
        if let tail = rec.tailURL { try? FileManager.default.removeItem(at: tail) }
        let fm = FileManager.default
        guard rec.url.deletingLastPathComponent().standardizedFileURL != Paths.failedDir.standardizedFileURL else { return }
        do {
            // Ces fichiers contiennent ta voix : dossier lisible par toi seul.
            try fm.createDirectory(at: Paths.failedDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            let dest = Paths.failedDir.appendingPathComponent("\(formatter.string(from: Date())).wav")
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: rec.url, to: dest)
            Log.write("Audio gardé pour une nouvelle tentative : \(dest.lastPathComponent)")
        } catch {
            Log.write("Impossible de garder l'audio : \(error.localizedDescription)")
            try? fm.removeItem(at: rec.url)
        }
        for old in all().dropLast(maxKept) { try? fm.removeItem(at: old) }
    }

    /// Les fichiers gardés, du plus ancien au plus récent (le nom est un horodatage).
    static func all() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.failedDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func latest() -> URL? { all().last }
}
