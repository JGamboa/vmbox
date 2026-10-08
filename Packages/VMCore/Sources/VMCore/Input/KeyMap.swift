import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

public struct KeyStroke: Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    public var characters: String

    public init(keyCode: UInt16, modifiers: KeyModifiers, characters: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.characters = characters
    }
}

public enum KeyMapError: Error, Equatable, CustomStringConvertible {
    case unsupportedCharacters(String)
    case unknownKey(String)
    case emptyCombo
    case textTooLong(Int)

    public var description: String {
        switch self {
        case .unsupportedCharacters(let chars):
            "Caracteres no soportados con la distribución de teclado US: «\(chars)». Usa ASCII imprimible, \\n y \\t (o clipboard_set con el guest-agent)."
        case .unknownKey(let key): "Tecla o modificador desconocido: «\(key)»"
        case .emptyCombo: "La combinación está vacía"
        case .textTooLong(let count): "Texto demasiado largo (\(count) caracteres; máximo \(KeyMap.maxTextLength))"
        }
    }
}

/// Mapeo a key codes virtuales de macOS (kVK_*) para distribución US-ANSI.
/// La VM recibe códigos de tecla físicos: el invitado debe usar distribución US.
public enum KeyMap {
    public static let maxTextLength = 10_000

    public static let modifierKeyCodes: [KeyModifiers: UInt16] = [.control: 59, .option: 58, .shift: 56, .command: 55]

    static let unshifted: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
        ".": 47, " ": 49, "`": 50,
    ]

    static let shifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9",
        ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    static let named: [String: UInt16] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51, "escape": 53, "esc": 53,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]

    static let namedCharacters: [UInt16: String] = [36: "\r", 48: "\t", 49: " ", 51: "\u{8}", 53: "\u{1b}"]

    static let modifierNames: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "super": .command, "win": .command, "meta": .command,
        "ctrl": .control, "control": .control, "alt": .option, "option": .option, "opt": .option, "shift": .shift,
    ]

    public static func strokes(forText text: String) throws -> [KeyStroke] {
        guard text.count <= maxTextLength else { throw KeyMapError.textTooLong(text.count) }
        var strokes: [KeyStroke] = []
        var unsupported = ""
        for character in text {
            if let stroke = stroke(forCharacter: character) {
                strokes.append(stroke)
            } else if !unsupported.contains(character) {
                unsupported.append(character)
            }
        }
        guard unsupported.isEmpty else { throw KeyMapError.unsupportedCharacters(unsupported) }
        return strokes
    }

    static func stroke(forCharacter character: Character) -> KeyStroke? {
        switch character {
        case "\n", "\r", "\r\n": return KeyStroke(keyCode: 36, modifiers: [], characters: "\r")
        case "\t": return KeyStroke(keyCode: 48, modifiers: [], characters: "\t")
        default: break
        }
        if let code = unshifted[character] {
            return KeyStroke(keyCode: code, modifiers: [], characters: String(character))
        }
        if character.isASCII, character.isUppercase, let lower = character.lowercased().first, let code = unshifted[lower] {
            return KeyStroke(keyCode: code, modifiers: .shift, characters: String(character))
        }
        if let base = shifted[character], let code = unshifted[base] {
            return KeyStroke(keyCode: code, modifiers: .shift, characters: String(character))
        }
        return nil
    }

    /// Formato: modificadores y tecla separados por "+", p. ej. "cmd+space", "ctrl+alt+t", "cmd++", "super".
    public static func stroke(forCombo combo: String) throws -> KeyStroke {
        var spec = combo.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { throw KeyMapError.emptyCombo }
        let keyPart: String
        if spec == "+" {
            keyPart = "+"
            spec = ""
        } else if spec.hasSuffix("++") {
            keyPart = "+"
            spec = String(spec.dropLast(2))
        } else if let plus = spec.range(of: "+", options: .backwards) {
            keyPart = spec[plus.upperBound...].trimmingCharacters(in: .whitespaces)
            spec = String(spec[..<plus.lowerBound])
        } else {
            keyPart = spec
            spec = ""
        }

        var modifiers: KeyModifiers = []
        for name in spec.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !name.isEmpty {
            guard let modifier = modifierNames[name] else { throw KeyMapError.unknownKey(name) }
            modifiers.insert(modifier)
        }

        let lowered = keyPart.lowercased()
        if let code = named[lowered] {
            return KeyStroke(keyCode: code, modifiers: modifiers, characters: namedCharacters[code] ?? "")
        }
        if let modifier = modifierNames[lowered], let code = modifierKeyCodes[modifier] {
            return KeyStroke(keyCode: code, modifiers: modifiers, characters: "")
        }
        guard keyPart.count == 1, let character = keyPart.first else { throw KeyMapError.unknownKey(keyPart) }
        let base: Character = character.isASCII && character.isLetter ? Character(character.lowercased()) : character
        guard let stroke = stroke(forCharacter: base) else { throw KeyMapError.unknownKey(keyPart) }
        return KeyStroke(keyCode: stroke.keyCode, modifiers: modifiers.union(stroke.modifiers), characters: stroke.characters)
    }
}
