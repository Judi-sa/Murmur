import Cocoa
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DictationController!
    private var monitor: HotkeyMonitor?
    private var retryTimer: Timer?
    private var configError: String?
    /// Sous-menu des suggestions, rempli seulement quand on l'ouvre : analyser l'historique
    /// à chaque affichage du menu principal serait du travail inutile à chaque clic.
    private let suggestionsMenu = NSMenu(title: "Suggestions de vocabulaire")
    private var hotkeyError: String?

    private var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let (config, err) = ConfigStore.load()
        configError = err
        controller = DictationController(config: config)
        controller.onStateChange = { [weak self] _ in self?.updateIcon() }

        suggestionsMenu.delegate = self
        installEditMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        Log.write("Murmur démarré. raccourci=\(config.hotkey) transcription=\(config.transcription.provider) cleanup=\(config.cleanup.provider)")
        logVocabulary(config)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted { Log.write("Accès au micro refusé") }
        }
        if enabled { startMonitoring(prompt: true) }
    }

    // MARK: Hotkey

    private func startMonitoring(prompt: Bool) {
        monitor?.stop()
        monitor = nil
        retryTimer?.invalidate()
        retryTimer = nil

        guard let hotkey = Hotkey.parse(controller.config.hotkey) else {
            hotkeyError = "Raccourci invalide \"\(controller.config.hotkey)\" dans config.json"
            Log.write(hotkeyError!)
            updateIcon()
            return
        }
        let commandHotkey = controller.config.commandHotkey
        let commandMask = commandHotkey.isEmpty ? nil : Hotkey.modifierMask(commandHotkey)
        if !commandHotkey.isEmpty && commandMask == nil {
            Log.write("commandHotkey \"\(commandHotkey)\" ignoré : seule une touche modificatrice seule est acceptée")
        }
        let m = HotkeyMonitor(hotkey: hotkey, commandMask: commandMask)
        m.onCommandPress = { [weak self] in self?.controller.commandPressed() }
        m.onCommandRelease = { [weak self] in self?.controller.commandReleased() }
        m.onPress = { [weak self] in self?.controller.hotkeyPressed() }
        m.onRelease = { [weak self] in self?.controller.hotkeyReleased() }
        m.onEscape = { [weak self] in self?.controller.escapePressed() }
        m.onOtherKey = { [weak self] in self?.controller.otherKeyPressed() }

        if m.start() {
            monitor = m
            hotkeyError = nil
            Log.write("En écoute du raccourci \(hotkey)" + (commandMask != nil ? ", mode commande sur \(commandHotkey)" : ""))
        } else {
            hotkeyError = "Autorisation Surveillance de l'entrée / Accessibilité requise"
            Log.write("Échec du tap clavier : accorde Surveillance de l'entrée et Accessibilité, Murmur réessaie automatiquement")
            if prompt { Permissions.request() }
            // Les autorisations accordées dans Réglages Système s'appliquent sans relancer l'app.
            retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, self.enabled, self.monitor == nil else { return }
                self.startMonitoring(prompt: false)
            }
        }
        updateIcon()
    }

    private func stopMonitoring() {
        monitor?.stop()
        monitor = nil
        retryTimer?.invalidate()
        retryTimer = nil
        controller.reset()
        updateIcon()
    }

    // MARK: Menu

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if !enabled {
            symbol = "mic.slash"
        } else if hotkeyError != nil {
            symbol = "exclamationmark.triangle"
        } else {
            switch controller.state {
            case .idle: symbol = "mic"
            case .holding, .handsFree: symbol = "mic.fill"
            case .processing: symbol = "ellipsis.circle"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        button.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === suggestionsMenu {
            fillSuggestions(menu)
            return
        }
        menu.removeAllItems()
        let cfg = controller.config
        let env = Env.load()

        let toggle = NSMenuItem(title: "Dictée activée", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.state = enabled ? .on : .off
        menu.addItem(toggle)

        let status: String
        if let hotkeyError, enabled { status = "⚠︎ \(hotkeyError)" }
        else if let configError { status = "⚠︎ \(configError)" }
        else {
            let stt = Transcriber.resolvedProvider(cfg.transcription, env: env)
            let sttText = stt == "local" ? "whisper.cpp \(cfg.transcription.localModel)" : stt
            status = "Maintiens \(cfg.hotkey) · \(sttText) · nettoyage : \(Cleaner.resolvedProvider(cfg.cleanup, env: env))"
        }
        menu.addItem(disabled(status))
        if enabled && hotkeyError == nil && !(AXIsProcessTrusted() && CGPreflightPostEventAccess()) {
            // Le raccourci marche (Surveillance de l'entrée) mais le collage échouera en silence.
            let warn = NSMenuItem(title: "⚠︎ Accessibilité non cochée : le texte ne se colle pas. Ouvrir…",
                                  action: #selector(openPermissions), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }
        if Transcriber.resolvedProvider(cfg.transcription, env: env) == "local" {
            if Transcriber.whisperBinary(cfg.transcription) == nil {
                menu.addItem(disabled("⚠︎ whisper-cli absent : brew install whisper-cpp"))
            } else if !FileManager.default.fileExists(atPath: Transcriber.modelPath(cfg.transcription)) {
                menu.addItem(disabled("⚠︎ Modèle \(cfg.transcription.localModel) non téléchargé"))
            }
        }
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Historique et corrections…", action: #selector(openHistory), keyEquivalent: "h"))
        let repaste = NSMenuItem(title: "Recoller la dernière dictée", action: #selector(repasteLast), keyEquivalent: "")
        repaste.isEnabled = controller.lastInsertedText != nil
        menu.addItem(repaste)
        let failed = FailedAudio.all().count
        let retry = NSMenuItem(title: failed > 0 ? "Réessayer la dernière dictée échouée (\(failed) gardée\(failed > 1 ? "s" : ""))"
                                                 : "Réessayer la dernière dictée échouée",
                               action: #selector(retryFailed), keyEquivalent: "")
        retry.isEnabled = failed > 0
        menu.addItem(retry)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Ouvrir à la connexion", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Ouvrir le fichier de réglages", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Ouvrir .env (clés API)", action: #selector(openEnv), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ouvrir les raccourcis vocaux", action: #selector(openSnippets), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Recharger les réglages", action: #selector(reloadSettings), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Autorisations…", action: #selector(openPermissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Afficher le journal", action: #selector(openLog), keyEquivalent: ""))
        let suggestions = NSMenuItem(title: "Suggestions de vocabulaire", action: nil, keyEquivalent: "")
        suggestions.submenu = suggestionsMenu
        menu.addItem(suggestions)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter Murmur", action: #selector(quit), keyEquivalent: "q"))
        // autoenablesItems est coupé pour que les entrées grisées (rien à recoller...) le restent.
        menu.autoenablesItems = false
        for item in menu.items where item.action != nil { item.target = self }
    }

    @objc private func openHistory() { HistoryWindowController.shared.show(config: controller.config) }
    @objc private func repasteLast() { controller.repasteLast() }
    @objc private func retryFailed() { controller.retryLastFailed() }

    @objc private func openSnippets() {
        ConfigStore.ensureFiles()
        NSWorkspace.shared.open([Paths.snippetsFile], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    /// Une app de barre de menus n'a pas de menu Édition : sans lui, ⌘C, ⌘V, ⌘Z et ⌘A ne font
    /// rien dans la fenêtre Historique. Le menu reste invisible, seuls ses raccourcis comptent.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Édition")
        edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Fermer la fenêtre", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Suggestions de vocabulaire

    /// Analyse l'historique et propose les corrections récurrentes. Un sous-menu plutôt qu'une
    /// fenêtre : rien à gérer côté cycle de vie, et un clic suffit pour accepter une règle.
    private func fillSuggestions(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = controller.config.history
        guard cfg.enabled else {
            menu.addItem(disabled("Historique désactivé"))
            menu.addItem(disabled("Mets \"history\": { \"enabled\": true } dans config.json"))
            for item in menu.items where item.action != nil { item.target = self }
            return
        }
        // Les dictées les plus récentes suffisent, et bornent le coût de l'analyse.
        let entries = History.load().suffix(500)
        guard !entries.isEmpty else {
            menu.addItem(disabled("Aucune dictée enregistrée pour l'instant"))
            return
        }
        let found = VocabularyAnalyzer.suggestions(from: Array(entries),
                                                   minOccurrences: cfg.suggestionMinOccurrences)
        guard !found.isEmpty else {
            menu.addItem(disabled("Aucune correction récurrente (seuil : \(cfg.suggestionMinOccurrences))"))
            return
        }
        menu.addItem(disabled("Clique pour ajouter la règle au dictionnaire"))
        for s in found.prefix(20) {
            let item = NSMenuItem(title: "\(s.wrong) → \(s.right)  (\(s.count)×)",
                                  action: #selector(addSuggestion(_:)), keyEquivalent: "")
            item.representedObject = s.rule
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func addSuggestion(_ sender: NSMenuItem) {
        guard let rule = sender.representedObject as? String,
              let sep = rule.range(of: " => ") else { return }
        let wrong = String(rule[..<sep.lowerBound])
        let right = String(rule[sep.upperBound...])
        if Vocabulary.appendRule(wrong: wrong, right: right) {
            Log.write("Règle ajoutée au dictionnaire : \(rule)")
        } else {
            alert("Échec de l'ajout", "Impossible d'écrire dans \(Paths.vocabularyFile.path).")
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        enabled ? startMonitoring(prompt: true) : stopMonitoring()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Échec de l'ouverture à la connexion", "\(error.localizedDescription)\n\nDéplace Murmur.app dans /Applications et réessaie.")
        }
    }

    @objc private func openSettings() { NSWorkspace.shared.open(Paths.configFile) }

    @objc private func openEnv() {
        // Aucune app n'est associée aux fichiers .env : ouverture dans TextEdit.
        NSWorkspace.shared.open([Paths.envFile], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openLog() { NSWorkspace.shared.open(Paths.logFile) }

    @objc private func openPermissions() { Permissions.request() }

    @objc private func reloadSettings() {
        let (config, err) = ConfigStore.load()
        configError = err
        controller.reset()
        controller.config = config
        controller.applyConfig()
        Log.write("Réglages rechargés. raccourci=\(config.hotkey)")
        logVocabulary(config)
        if enabled { startMonitoring(prompt: false) }
        if let err { alert("Erreur de réglages", err) }
    }

    /// Trace le dictionnaire chargé : sans ça, un vocabulary.txt mal placé reste invisible.
    private func logVocabulary(_ config: Config) {
        guard config.vocabulary.enabled else {
            Log.write("Dictionnaire personnel désactivé (vocabulary.enabled = false)")
            return
        }
        let vocab = Vocabulary.load()
        Log.write("Dictionnaire personnel : \(vocab.terms.count) terme(s), \(vocab.corrections.count) correction(s)")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

enum Permissions {
    /// Déclenche les demandes système et ouvre les panneaux concernés de Réglages Système.
    static func request() {
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess()
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        // Le collage (⌘V simulé) dépend aussi de l'autorisation d'envoyer des touches.
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        if !AXIsProcessTrustedWithOptions(opts) || !CGPreflightPostEventAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
        if CGPreflightListenEventAccess() && AXIsProcessTrusted() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
