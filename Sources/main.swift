import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let recorder = HotKeyRecorder()
    private var overlays: [OverlayWindow] = []
    private var downloadWindow: NSWindow?
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setIcon(busy: false)
        rebuildMenu()
        HotKeyManager.shared.handler = { [weak self] in self?.translateScreen() }
        registerHotKey()
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    /// Opening the app again (e.g. `open ScreenTranslate.app`) shows the hotkey recorder, since the
    /// menu-bar icon can be hidden behind the notch on a crowded menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        changeHotKey()
        return false
    }

    // MARK: Menu

    private func setIcon(busy: Bool) {
        let name = busy ? "hourglass" : "character.bubble"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Screen Translate")
    }

    private func rebuildMenu() {
        let settings = Settings.shared
        let menu = NSMenu()

        menu.addItem(withTitle: "Translate Screen   \(settings.hotKey.display)", action: #selector(translateScreen), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Change Hotkey…", action: #selector(changeHotKey), keyEquivalent: "").target = self

        menu.addItem(.separator())
        menu.addItem(languageMenu(title: "From: \(Languages.find(settings.sourceCode).name)", selected: settings.sourceCode, action: #selector(pickSource(_:))))
        menu.addItem(languageMenu(title: "To: \(Languages.find(settings.targetCode).name)", selected: settings.targetCode, action: #selector(pickTarget(_:))))
        menu.addItem(withTitle: "Swap Languages", action: #selector(swapLanguages), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Download Language Packs…", action: #selector(downloadLanguages), keyEquivalent: "").target = self

        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private func languageMenu(title: String, selected: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in Languages.all {
            let entry = submenu.addItem(withTitle: language.name, action: action, keyEquivalent: "")
            entry.target = self
            entry.representedObject = language.code
            entry.state = language.code == selected ? .on : .off
        }
        item.submenu = submenu
        return item
    }

    @objc private func pickSource(_ sender: NSMenuItem) { Settings.shared.sourceCode = sender.representedObject as? String ?? "ja" }
    @objc private func pickTarget(_ sender: NSMenuItem) { Settings.shared.targetCode = sender.representedObject as? String ?? "en" }

    @objc private func swapLanguages() {
        let s = Settings.shared
        (s.sourceCode, s.targetCode) = (s.targetCode, s.sourceCode)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change Launch at Login", error.localizedDescription)
        }
        rebuildMenu()
    }

    // MARK: Hotkey

    private func registerHotKey() {
        if !HotKeyManager.shared.register(Settings.shared.hotKey) {
            alert("Hotkey unavailable", "\(Settings.shared.hotKey.display) is already used by the system or another app. Pick a different one from the menu.")
        }
    }

    @objc private func changeHotKey() {
        let previous = Settings.shared.hotKey
        HotKeyManager.shared.unregister()  // so the current combo can be re-recorded
        recorder.begin(current: previous) { [weak self] newKey in
            guard let self else { return }
            if let newKey {
                if HotKeyManager.shared.register(newKey) {
                    Settings.shared.hotKey = newKey
                } else {
                    self.alert("Hotkey unavailable", "\(newKey.display) is already taken. Keeping \(previous.display).")
                    HotKeyManager.shared.register(previous)
                }
            } else {
                HotKeyManager.shared.register(previous)
            }
        }
    }

    // MARK: Translate

    @objc private func translateScreen() {
        if !overlays.isEmpty { dismissOverlays(); return }
        guard !busy else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // System prompt only: an NSAlert would activate this app and can make macOS switch Spaces.
            CGRequestScreenCaptureAccess()
            Toast.show("Allow Screen Recording for Screen Translate, then reopen it")
            return
        }

        busy = true
        setIcon(busy: true)
        let source = Languages.find(Settings.shared.sourceCode)
        let target = Languages.find(Settings.shared.targetCode)
        let infos = NSScreen.screens.compactMap(ScreenInfo.init)

        Task { @MainActor in
            defer { busy = false; setIcon(busy: false) }
            do {
                let session = try await Pipeline.makeSession(source: source, target: target)
                var captures: [(ScreenInfo, CGImage)] = []
                for info in infos { captures.append((info, try await Pipeline.capture(info))) }

                var results: [(ScreenInfo, [RenderBlock])] = []
                for (info, image) in captures {
                    let blocks = try await Pipeline.process(image: image, pointSize: info.frame.size,
                                                            source: source, target: target, session: session)
                    results.append((info, blocks))
                }

                let shown = results.filter { !$0.1.isEmpty }
                guard !shown.isEmpty else { Toast.show("No \(source.name) text found"); return }
                for (info, blocks) in shown {
                    let window = OverlayWindow(screenFrame: info.frame, blocks: blocks) { [weak self] in self?.dismissOverlays() }
                    overlays.append(window)
                }
                overlays.forEach { $0.present() }
            } catch PipelineError.languagesNotInstalled {
                downloadLanguages()
            } catch {
                alert("Translation failed", error.localizedDescription)
            }
        }
    }

    private func dismissOverlays() {
        overlays.forEach { $0.close() }
        overlays.removeAll()
    }

    // MARK: Language download

    @objc private func downloadLanguages() {
        downloadWindow?.close()
        let s = Settings.shared
        let view = LanguageDownloadView(
            source: Locale.Language(identifier: s.sourceCode),
            target: Locale.Language(identifier: s.targetCode)
        ) { [weak self] in
            self?.downloadWindow?.close()
            self?.downloadWindow = nil
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Translation Languages"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        downloadWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Helpers

    private func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

// MARK: - Test mode (no screen-recording permission needed)
//   ScreenTranslate --test in.png out.png [sourceCode] [targetCode]

if let i = CommandLine.arguments.firstIndex(of: "--test"), CommandLine.arguments.count > i + 2 {
    _ = NSApplication.shared
    let input = CommandLine.arguments[i + 1], output = CommandLine.arguments[i + 2]
    let source = Languages.find(CommandLine.arguments.count > i + 3 ? CommandLine.arguments[i + 3] : "ja")
    let target = Languages.find(CommandLine.arguments.count > i + 4 ? CommandLine.arguments[i + 4] : "en")

    Task { @MainActor in
        do {
            guard let image = NSImage(contentsOfFile: input)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                fputs("Can't read \(input)\n", stderr); exit(1)
            }
            let session = try await Pipeline.makeSession(source: source, target: target)
            let size = CGSize(width: image.width, height: image.height)
            let blocks = try await Pipeline.process(image: image, pointSize: size, source: source, target: target, session: session)
            for b in blocks { print("[\(b.lines) line(s)] \(b.text)") }

            let view = OverlayView(size: size, blocks: blocks, backdrop: image)
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
            print("Wrote \(output) with \(blocks.count) block(s)")
            exit(0)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
