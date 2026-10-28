import AVFoundation

/// Enregistre le micro en 16 kHz mono 16 bits, le format attendu par Whisper, en mémoire.
///
/// AVAudioEngine plutôt qu'AVAudioRecorder : on voit passer l'audio pendant l'enregistrement,
/// ce qui permet de fermer un morceau à chaque pause et de l'envoyer à l'API pendant que la
/// personne continue de parler (voir `segmenting`). À l'arrêt, le fichier complet est écrit
/// sans les silences du début et de la fin.
final class AudioRecorder {
    /// Ce que l'arrêt de l'enregistrement rend à l'appelant (qui supprime les fichiers).
    struct Recording {
        /// L'enregistrement complet, silences de début et de fin retirés.
        var url: URL
        /// Ce qui reste après le dernier morceau envoyé. nil quand rien n'a été découpé.
        var tailURL: URL?
        /// La fin contient-elle de la parole ? Sinon, inutile de l'envoyer.
        var tailHasSpeech: Bool
        /// Nombre de morceaux déjà remis par `onSegment`.
        var segments: Int
    }

    /// Niveau 0...1, mis à jour une dizaine de fois par seconde, sur le thread principal.
    var onLevel: ((Double) -> Void)?
    /// Un morceau vient de se fermer sur une pause : fichier WAV temporaire, sur le thread principal.
    var onSegment: ((URL) -> Void)?
    /// true = découpe aux pauses pendant l'enregistrement. À fixer avant `start()`.
    var segmenting = false
    /// Seuil de parole (dBFS crête) : en dessous, un enregistrement ou une fin est considéré muet.
    var speechThresholdDb = -45.0

    static let sampleRate = 16_000.0
    /// Un morceau ne se ferme qu'après cette durée : en dessous, l'aller-retour réseau coûte plus
    /// qu'il ne fait gagner.
    private static let minSegmentSamples = Int(12 * sampleRate)
    /// Durée de pause qui ferme un morceau. Assez longue pour ne pas couper un mot en deux.
    private static let pauseSamples = Int(0.35 * sampleRate)
    /// Fenêtre d'analyse de l'énergie : 20 ms.
    private static let window = 320
    /// Marge gardée autour de la parole quand on retire les silences.
    private static let margin = Int(0.2 * sampleRate)

    private var engine: AVAudioEngine?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                          channels: 1, interleaved: true)!

    // État partagé avec le thread audio, protégé par `lock`.
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var segmentStart = 0
    private var segmentCount = 0
    private var silentRun = 0
    private var analyzed = 0
    private var noiseFloorDb = -50.0
    private var peak: Double = -160

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / Self.sampleRate
    }

    var peakDb: Double {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    func start() throws {
        cancel()
        lock.lock()
        samples = []
        samples.reserveCapacity(Int(Self.sampleRate) * 60)
        segmentStart = 0
        segmentCount = 0
        silentRun = 0
        analyzed = 0
        noiseFloorDb = -50
        peak = -160
        lock.unlock()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw MurmurError("Le micro n'a pas pu démarrer l'enregistrement")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.consume(buffer, converter: converter)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MurmurError("Le micro n'a pas pu démarrer l'enregistrement : \(error.localizedDescription)")
        }
        self.engine = engine
    }

    /// Arrête et écrit les fichiers. nil si rien n'a été enregistré.
    func stop() -> Recording? {
        guard let engine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil

        lock.lock()
        let all = samples
        let start = segmentStart
        let count = segmentCount
        samples = []
        lock.unlock()

        guard !all.isEmpty else { return nil }
        let trimmed = Self.trimSilence(all[...], thresholdDb: speechThresholdDb)
        guard let url = Self.writeWAV(trimmed.isEmpty ? all[...] : trimmed) else { return nil }
        var tailURL: URL?
        var tailHasSpeech = false
        if count > 0 {
            let tail = all[start...]
            tailHasSpeech = Self.peakDb(tail) >= speechThresholdDb
            if tailHasSpeech {
                tailURL = Self.writeWAV(Self.trimSilence(tail, thresholdDb: speechThresholdDb, keepStart: true))
            }
        }
        return Recording(url: url, tailURL: tailURL, tailHasSpeech: tailHasSpeech, segments: count)
    }

    /// Arrête sans rien écrire.
    func cancel() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        lock.lock()
        samples = []
        lock.unlock()
    }

    // MARK: Thread audio

    private func consume(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.int16ChannelData?[0] else { return }
        ingest(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    /// Ajoute de l'audio déjà au format 16 kHz mono : mesure, découpage aux pauses, niveau.
    /// Séparé de la conversion pour pouvoir rejouer un fichier WAV dans les tests.
    func ingest(_ chunk: UnsafeBufferPointer<Int16>) {
        guard chunk.count > 0 else { return }
        var sumSquares = 0.0
        var chunkPeak: Int32 = 0
        for s in chunk {
            let v = Double(s)
            sumSquares += v * v
            chunkPeak = max(chunkPeak, abs(Int32(s)))
        }
        let rms = (sumSquares / Double(chunk.count)).squareRoot()
        let avgDb = Self.db(rms)

        var segment: ArraySlice<Int16>?
        lock.lock()
        samples.append(contentsOf: chunk)
        peak = max(peak, Self.db(Double(chunkPeak)))
        if segmenting { segment = detectPause() }
        lock.unlock()

        if let segment, let url = Self.writeWAV(segment) {
            DispatchQueue.main.async { [weak self] in self?.onSegment?(url) }
        }
        let level = max(0, min(1, (avgDb + 50) / 50))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    /// Analyse les nouvelles fenêtres de 20 ms. Appelée sous `lock`. Renvoie le morceau à envoyer
    /// quand une pause assez longue arrive après au moins `minSegmentSamples` de parole.
    private func detectPause() -> ArraySlice<Int16>? {
        var cut: ArraySlice<Int16>?
        while analyzed + Self.window <= samples.count {
            let w = samples[analyzed..<(analyzed + Self.window)]
            analyzed += Self.window
            var sum = 0.0
            for s in w { let v = Double(s); sum += v * v }
            let windowDb = Self.db((sum / Double(Self.window)).squareRoot())
            // Plancher de bruit suivi lentement : la pièce, le ventilateur. Le zéro numérique des
            // premiers instants du micro ne compte pas.
            if windowDb > -90 { noiseFloorDb = min(noiseFloorDb + 0.02, max(windowDb, -75)) }
            let silent = windowDb < min(-30, noiseFloorDb + 12)
            silentRun = silent ? silentRun + Self.window : 0
            if silentRun >= Self.pauseSamples && analyzed - segmentStart >= Self.minSegmentSamples {
                // Coupe au milieu de la pause : aucun des deux morceaux ne perd une syllabe.
                let end = analyzed - silentRun / 2
                cut = samples[segmentStart..<end]
                segmentStart = end
                segmentCount += 1
                silentRun = 0
            }
        }
        return cut
    }

    // MARK: Outils

    private static func db(_ amplitude: Double) -> Double {
        amplitude > 0 ? 20 * log10(amplitude / 32768) : -160
    }

    private static func peakDb(_ s: ArraySlice<Int16>) -> Double {
        var p: Int32 = 0
        for v in s { p = max(p, abs(Int32(v))) }
        return db(Double(p))
    }

    /// Retire le silence au début et à la fin, en gardant une marge de 200 ms autour de la parole.
    /// `keepStart` : pour la fin d'une dictée découpée, le début suit directement le morceau précédent.
    static func trimSilence(_ s: ArraySlice<Int16>, thresholdDb: Double, keepStart: Bool = false) -> ArraySlice<Int16> {
        let limit = Int32(32768 * pow(10, (thresholdDb - 6) / 20))
        guard let first = s.firstIndex(where: { abs(Int32($0)) > limit }),
              let last = s.lastIndex(where: { abs(Int32($0)) > limit }) else { return s }
        let lo = keepStart ? s.startIndex : max(s.startIndex, first - margin)
        let hi = min(s.endIndex, last + margin)
        return s[lo..<hi]
    }

    /// WAV PCM 16 bits mono dans un fichier temporaire.
    static func writeWAV(_ s: ArraySlice<Int16>) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString).wav")
        let dataBytes = UInt32(s.count * 2)
        var d = Data(capacity: 44 + Int(dataBytes))
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        s.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress)?
            .assumingMemoryBound(to: UInt8.self), count: $0.count * 2)) }
        do {
            try d.write(to: url)
            return url
        } catch {
            Log.write("Écriture du WAV impossible : \(error.localizedDescription)")
            return nil
        }
    }
}
