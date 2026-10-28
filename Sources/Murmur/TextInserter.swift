import Cocoa
import Carbon.HIToolbox

/// Insère le texte au curseur de l'app active, quelle qu'elle soit.
enum TextInserter {
    static func insert(_ text: String, cfg: Config.Insertion) {
        let pb = NSPasteboard.general
        let saved = cfg.restoreClipboard ? snapshot(pb) : nil

        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        if cfg.method.lowercased() == "type" {
            typeText(text)
        } else {
            pressCmdV()
        }

        if let saved {
            // Laisse à l'app cible le temps de lire le presse-papiers avant de remettre l'ancien contenu.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard pb.changeCount == ourChange else { return } // l'utilisateur a copié autre chose entre-temps
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
        }
    }

    /// Met le texte dans le presse-papiers sans rien coller (aucun champ actif).
    static func copyOnly(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    // MARK: Cible du collage

    /// Apps qui ne contiennent jamais de champ de texte : coller là, c'est coller dans le vide
    /// (un clic sur le bureau avec Stage Manager donne le focus à WindowManager).
    private static let noTextApps: Set<String> = ["com.apple.WindowManager", "com.apple.dock", "com.apple.loginwindow"]

    /// false seulement quand on est SÛR qu'aucun champ ne recevra le texte. Dans le doute on colle :
    /// les apps Electron (VS Code, Claude) exposent mal leurs éléments à l'accessibilité, et bloquer
    /// un collage légitime serait pire que de coller dans le vide.
    static func hasTextTarget() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let id = app.bundleIdentifier ?? ""
        if noTextApps.contains(id) { return false }
        if id == "com.apple.finder" {
            // Le Finder n'a de champ que pendant un renommage ou dans la recherche.
            guard let role = focusedRole() else { return false }
            return [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"].contains(role)
        }
        return true
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func focusedRole() -> String? {
        guard let el = focusedElement() else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }

    // MARK: Sélection (mode commande)

    /// Le texte sélectionné dans l'app active. L'accessibilité d'abord ; à défaut (Electron,
    /// navigateurs), un ⌘C simulé, puis le presse-papiers d'origine est remis en place.
    @MainActor
    static func selectedText() async -> String? {
        if let el = focusedElement() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &value) == .success,
               let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        pressCmd(CGKeyCode(kVK_ANSI_C))
        var copied: String?
        for _ in 0..<15 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pb.changeCount != before {
                copied = pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
        guard let copied, !copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return copied
    }

    private static func pressCmdV() {
        pressCmd(CGKeyCode(kVK_ANSI_V))
    }

    private static func pressCmd(_ v: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        // Modificateurs explicites : un raccourci encore maintenu (ex. ctrl+option) ne perturbe pas le collage.
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func typeText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + 16, units.count)
            // Ne coupe pas une paire de substitution UTF-16 entre deux événements.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[i..<end])
            for keyDown in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: keyDown)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                e?.post(tap: .cghidEventTap)
            }
            usleep(2_000)
            i = end
        }
    }
}
