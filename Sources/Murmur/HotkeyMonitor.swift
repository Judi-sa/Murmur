import Cocoa
import Carbon.HIToolbox

/// Raccourci analysé : soit une touche modificatrice seule (fn, right_option...), soit une combinaison.
struct Hotkey: CustomStringConvertible {
    enum Kind {
        /// Bit dépendant du périphérique qui identifie une touche modificatrice physique.
        case modifier(deviceMask: UInt64, name: String)
        case combo(keyCode: Int64, modifiers: CGEventFlags, text: String)
    }
    let kind: Kind

    var description: String {
        switch kind {
        case .modifier(_, let name): return name
        case .combo(_, _, let text): return text
        }
    }

    // Bits dépendants du périphérique, issus de NX_DEVICE*KEYMASK d'IOKit.
    private static let modifierKeys: [String: UInt64] = [
        "fn": 0x800000, "globe": 0x800000,
        "left_control": 0x1, "right_control": 0x2000,
        "left_shift": 0x2, "right_shift": 0x4,
        "left_command": 0x8, "right_command": 0x10,
        "left_option": 0x20, "right_option": 0x40,
    ]

    private static let comboModifiers: [String: CGEventFlags] = [
        "ctrl": .maskControl, "control": .maskControl,
        "opt": .maskAlternate, "option": .maskAlternate, "alt": .maskAlternate,
        "cmd": .maskCommand, "command": .maskCommand,
        "shift": .maskShift, "fn": .maskSecondaryFn,
    ]

    private static let keyCodes: [String: Int] = {
        var m: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
            "backslash": kVK_ANSI_Backslash, "slash": kVK_ANSI_Slash, "period": kVK_ANSI_Period,
            "comma": kVK_ANSI_Comma, "semicolon": kVK_ANSI_Semicolon, "quote": kVK_ANSI_Quote,
            "grave": kVK_ANSI_Grave, "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
            "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17,
            "f18": kVK_F18, "f19": kVK_F19,
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9),
        ]
        for (k, v) in letters { m[k] = v }
        return m
    }()

    /// Bit de périphérique d'une touche modificatrice seule ("right_option"...), nil sinon.
    static func modifierMask(_ raw: String) -> UInt64? {
        modifierKeys[raw.lowercased().replacingOccurrences(of: " ", with: "")]
    }

    static func parse(_ raw: String) -> Hotkey? {
        let s = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if let mask = modifierKeys[s] {
            return Hotkey(kind: .modifier(deviceMask: mask, name: s))
        }
        let parts = s.split(separator: "+").map(String.init)
        guard parts.count >= 2, let key = parts.last, let code = keyCodes[key] else { return nil }
        var flags: CGEventFlags = []
        for p in parts.dropLast() {
            guard let f = comboModifiers[p] else { return nil }
            flags.insert(f)
        }
        return Hotkey(kind: .combo(keyCode: Int64(code), modifiers: flags, text: s))
    }
}

/// Surveillance globale du clavier via un CGEventTap.
/// Les raccourcis modificateurs utilisent un tap en écoute seule (Surveillance de l'entrée). Les combinaisons
/// exigent un tap actif (Accessibilité) pour que la combinaison ne soit pas tapée dans l'app active.
/// Échap et toutes les autres touches passent toujours sans modification.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Autre touche pressée pendant le maintien du raccourci (l'utilisateur tape un raccourci clavier).
    var onOtherKey: (() -> Void)?
    /// Touche du mode commande (modificatrice seule), observée sur le même tap.
    var onCommandPress: (() -> Void)?
    var onCommandRelease: (() -> Void)?

    private let hotkey: Hotkey
    private let commandMask: UInt64?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false
    private var isCommandDown = false

    private static let relevantFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    init(hotkey: Hotkey, commandMask: UInt64? = nil) {
        self.hotkey = hotkey
        // La touche de commande ne peut pas être celle de la dictée.
        if case .modifier(let mask, _) = hotkey.kind, mask == commandMask {
            self.commandMask = nil
        } else {
            self.commandMask = commandMask
        }
    }

    /// Renvoie false si le tap ne peut pas être créé (autorisation manquante).
    func start() -> Bool {
        stop()
        var mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let options: CGEventTapOptions
        switch hotkey.kind {
        case .modifier:
            options = .listenOnly
        case .combo:
            options = .defaultTap
            mask |= 1 << CGEventType.keyUp.rawValue
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            return false
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
        isCommandDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if let commandMask {
            if type == .flagsChanged {
                let down = event.flags.rawValue & commandMask != 0
                if down != isCommandDown {
                    isCommandDown = down
                    down ? onCommandPress?() : onCommandRelease?()
                }
            } else if type == .keyDown && !isRepeat && isCommandDown && keyCode != Int64(kVK_Escape) {
                // Option droite + une touche : la personne tape un caractère spécial, pas une commande.
                onOtherKey?()
            }
        }

        switch hotkey.kind {
        case .modifier(let deviceMask, _):
            if type == .flagsChanged {
                let down = event.flags.rawValue & deviceMask != 0
                if down != isDown {
                    isDown = down
                    down ? onPress?() : onRelease?()
                }
            } else if type == .keyDown && !isRepeat {
                if keyCode == Int64(kVK_Escape) {
                    onEscape?()
                } else if isDown {
                    onOtherKey?()
                }
            }
            return pass

        case .combo(let comboCode, let modifiers, _):
            if keyCode == comboCode {
                if type == .keyDown {
                    let held = event.flags.intersection(Self.relevantFlags.union(.maskSecondaryFn))
                    let wanted = modifiers
                    if isDown { return nil } // répétition automatique de notre combinaison
                    if held.intersection(Self.relevantFlags) == wanted.intersection(Self.relevantFlags)
                        && (!wanted.contains(.maskSecondaryFn) || held.contains(.maskSecondaryFn)) {
                        isDown = true
                        onPress?()
                        return nil
                    }
                } else if type == .keyUp, isDown {
                    isDown = false
                    onRelease?()
                    return nil
                }
            }
            if type == .keyDown && !isRepeat && keyCode == Int64(kVK_Escape) {
                onEscape?()
            }
            return pass
        }
    }
}
