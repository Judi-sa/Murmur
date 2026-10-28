import Cocoa

// Mode test en ligne de commande : `Murmur --transcribe fichier.wav` lance transcription + nettoyage et affiche le résultat.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
    let wav = URL(fileURLWithPath: args[i + 1])
    let (config, _) = ConfigStore.load()
    let env = Env.load()
    let vocab = config.vocabulary.enabled ? Vocabulary.load() : .empty
    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        do {
            let t0 = Date()
            let (raw, provider) = try await Transcriber.transcribe(wav, cfg: config.transcription, env: env,
                                                                   vocabulary: config.vocabulary.useInTranscription ? vocab : .empty)
            let t1 = Date()
            print("brut    (\(provider), \(String(format: "%.2f", t1.timeIntervalSince(t0)))s): \(raw)")
            if let snippet = Snippets.load().match(raw) {
                print("raccourci vocal : \(snippet)")
                done.signal()
                return
            }
            do {
                var clean = try await Cleaner.clean(raw, cfg: config.cleanup, env: env,
                                                    vocabulary: config.vocabulary.useInCleanup ? vocab : .empty)
                clean = vocab.applyCorrections(Typography.fix(clean, language: config.transcription.language))
                print("nettoyé (\(Cleaner.resolvedProvider(config.cleanup, env: env)), \(String(format: "%.2f", Date().timeIntervalSince(t1)))s): \(clean)")
            } catch {
                print("échec du nettoyage : \(error.localizedDescription)")
            }
        } catch {
            print("erreur : \(error.localizedDescription)")
            exitCode = 1
        }
        done.signal()
    }
    done.wait()
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
