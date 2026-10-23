import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon. Needs no Accessibility permission.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var handler: (() -> Void)?
    /// Fired by the temporary Esc hotkey, registered only while an overlay is up.
    var escapeHandler: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var escapeRef: EventHotKeyRef?
    private var handlerInstalled = false

    private static let signature = OSType(0x53545241)  // 'STRA'
    private static let mainID: UInt32 = 1
    private static let escapeID: UInt32 = 2

    @discardableResult
    func register(_ hotKey: HotKey) -> Bool {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: Self.mainID)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Grabs Esc globally, so the overlay can be dismissed even when it is click-through.
    func registerEscape() {
        guard escapeRef == nil else { return }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: Self.escapeID)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escapeRef)
    }

    func unregisterEscape() {
        if let escapeRef { UnregisterEventHotKey(escapeRef) }
        escapeRef = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let isEscape = hotKeyID.id == HotKeyManager.escapeID
            DispatchQueue.main.async {
                if isEscape { HotKeyManager.shared.escapeHandler?() } else { HotKeyManager.shared.handler?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

/// Small panel that captures the next key combination.
final class HotKeyRecorder: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var monitor: Any?
    private var completion: ((HotKey?) -> Void)?

    func begin(current: HotKey, completion: @escaping (HotKey?) -> Void) {
        self.completion = completion

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Hotkey"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let label = NSTextField(wrappingLabelWithString:
            "Press the new shortcut now.\nInclude at least one of ⌃ ⌥ ⇧ ⌘.\n\nCurrent: \(current.display)      Esc to cancel")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 16, width: 340, height: 98)
        panel.contentView?.addSubview(label)
        panel.center()
        self.panel = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { finish(nil); return }
        guard let hotKey = HotKey.make(from: event) else { NSSound.beep(); return }
        finish(hotKey)
    }

    private func finish(_ hotKey: HotKey?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let done = completion
        completion = nil
        let p = panel
        panel = nil
        p?.delegate = nil
        p?.close()
        done?(hotKey)
    }

    func windowWillClose(_ notification: Notification) {
        if completion != nil { finish(nil) }
    }
}
