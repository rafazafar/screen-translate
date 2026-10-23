import AppKit
import Carbon.HIToolbox

struct HotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask
    var display: String

    static let `default` = HotKey(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥T"
    )

    /// Builds a hotkey from a recorded key-down. Needs at least one modifier.
    static func make(from event: NSEvent) -> HotKey? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.isEmpty else { return nil }
        var mods: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); symbols += "⌘" }
        return HotKey(keyCode: UInt32(event.keyCode), modifiers: mods, display: symbols + keyName(for: event))
    }

    private static func keyName(for event: NSEvent) -> String {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[event.keyCode] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key\(event.keyCode)"
    }
}

final class Settings {
    static let shared = Settings()
    static let changed = Notification.Name("ScreenTranslateSettingsChanged")

    private let defaults = UserDefaults.standard

    var hotKey: HotKey {
        get {
            guard defaults.object(forKey: "hotkey.keyCode") != nil else { return .default }
            return HotKey(
                keyCode: UInt32(defaults.integer(forKey: "hotkey.keyCode")),
                modifiers: UInt32(defaults.integer(forKey: "hotkey.modifiers")),
                display: defaults.string(forKey: "hotkey.display") ?? "?"
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: "hotkey.keyCode")
            defaults.set(Int(newValue.modifiers), forKey: "hotkey.modifiers")
            defaults.set(newValue.display, forKey: "hotkey.display")
            NotificationCenter.default.post(name: Settings.changed, object: nil)
        }
    }

    var sourceCode: String {
        get { defaults.string(forKey: "language.source") ?? "ja" }
        set { defaults.set(newValue, forKey: "language.source"); NotificationCenter.default.post(name: Settings.changed, object: nil) }
    }

    /// Keep the overlay up and re-translate as the screen changes.
    var liveMode: Bool {
        get { defaults.object(forKey: "liveMode") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "liveMode"); NotificationCenter.default.post(name: Settings.changed, object: nil) }
    }

    var targetCode: String {
        get { defaults.string(forKey: "language.target") ?? "en" }
        set { defaults.set(newValue, forKey: "language.target"); NotificationCenter.default.post(name: Settings.changed, object: nil) }
    }
}
