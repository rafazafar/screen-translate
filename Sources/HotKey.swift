import AppKit
import Carbon.HIToolbox

/// Global hotkey via Carbon. Needs no Accessibility permission.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var handler: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    @discardableResult
    func register(_ hotKey: HotKey) -> Bool {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x53545241), id: 1)  // 'STRA'
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyManager.shared.handler?() }
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
