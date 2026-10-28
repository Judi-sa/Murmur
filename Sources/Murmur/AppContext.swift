import AppKit

/// L'application dans laquelle l'utilisateur est en train de dicter.
///
/// Capturée au DÉMARRAGE de l'enregistrement, jamais à la fin : Murmur affiche sa pastille,
/// peut passer par le presse-papiers et l'utilisateur peut changer de fenêtre pendant la
/// transcription. Interroger `frontmostApplication` à l'arrivée du texte donnerait donc
/// régulièrement la mauvaise app.
struct AppContext {
    /// Identifiant de bundle, ex : "com.apple.Terminal". Vide si macOS ne le donne pas.
    var bundleID: String
    /// Nom localisé affichable, ex : "Terminal".
    var name: String

    /// NSWorkspace est une API AppKit qui doit être lue sur le thread principal.
    /// Les événements de raccourci arrivent déjà sur la boucle principale, d'où le @MainActor
    /// plutôt qu'un saut de thread qui décalerait la capture après le changement de focus.
    @MainActor
    static func capture() -> AppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? bundleID
        guard !bundleID.isEmpty || !name.isEmpty else { return nil }
        return AppContext(bundleID: bundleID, name: name)
    }

    /// Pour le journal : "Terminal" ou, à défaut de nom localisé, l'identifiant de bundle.
    var logLabel: String { name.isEmpty ? bundleID : name }
}

// MARK: Résolution des profils

extension Config.AppProfiles {
    /// Le premier profil activé qui cible cette application. Un seul profil s'applique :
    /// empiler plusieurs consignes contradictoires rendrait le prompt imprévisible.
    func profile(for app: AppContext?) -> Profile? {
        guard enabled, let app, !app.bundleID.isEmpty else { return nil }
        let target = app.bundleID.lowercased()
        return profiles.first { p in
            p.enabled && p.bundleIDs.contains { $0.lowercased() == target }
        }
    }

    /// true quand l'app active demande explicitement de coller la transcription brute.
    func cleanupDisabled(for app: AppContext?) -> Bool {
        profile(for: app)?.disableCleanup ?? false
    }

    /// Section ajoutée au prompt système du nettoyage. Même esprit que `Vocabulary.cleanupPromptSection` :
    /// courte et impérative, pour ne pas pousser le modèle à commenter (le garde-fou de longueur du
    /// Cleaner rejette une sortie bavarde). Renvoie "" quand rien n'est configuré : le prompt reste
    /// alors exactement celui d'avant cette fonctionnalité.
    func cleanupPromptSection(for app: AppContext?) -> String {
        guard enabled else { return "" }
        var parts: [String] = []
        if mentionAppInPrompt, let app, !app.name.isEmpty {
            parts.append("L'utilisateur dicte dans \(app.name).")
        }
        let general = defaultInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !general.isEmpty { parts.append(general) }
        if let instruction = profile(for: app)?.instruction.trimmingCharacters(in: .whitespacesAndNewlines),
           !instruction.isEmpty {
            parts.append(instruction)
        }
        guard !parts.isEmpty else { return "" }
        return "\n" + parts.joined(separator: "\n")
    }
}
