import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let timer = TimerModel()
    private var panel: OverlayPanel!
    private var dial: DialView!
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ note: Notification) {
        let env = ProcessInfo.processInfo.environment
        // KITCHENTIMER_RENDER_SIZE overrides the size for off-screen renders only
        let size = (env["KITCHENTIMER_RENDER_SIZE"].flatMap { Double($0) }).map { CGFloat($0) }
            ?? Settings.shared.dialSize

        panel = OverlayPanel(size: size)
        dial = DialView(timer: timer, size: size)
        dial.menuBuilder = { [weak self] in self?.buildMenu() ?? NSMenu() }
        panel.contentView = dial

        dial.autoresizingMask = [.width, .height]
        panel.setFrameAutosaveName(OverlayPanel.autosaveName)
        // the autosave also carries last time's size; settings are the source
        // of truth, or the window and the dial would drift apart
        panel.resize(to: size)
        if panel.frame.origin == .zero, let vis = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: vis.maxX - size - 28, y: vis.maxY - size - 28))
        }
        timer.restoreLast()

        // before anything else — the diagnostics below depend on it
        Settings.shared.migrateFromLegacyDomainIfNeeded()
        Settings.shared.migrateAccentIfNeeded()
        Settings.shared.migrateCustomSoundIfNeeded()
        SoundPlayer.shared.prepare()   // so the first ring does not wait on the audio device

        // KITCHENTIMER_TEST_SOUND=<count> — n playback attempts with pauses,
        // reporting how much of the sound actually ran. play() returns true
        // even when the sound is swallowed, so catching flaky playback needs this.
        if let n = env["KITCHENTIMER_TEST_SOUND"].flatMap({ Int($0) }) {
            Task { @MainActor in
                print("sound: \(Settings.shared.soundID)")
                print("file:  \(Settings.shared.soundURL()?.path ?? "—")")
                var failed = 0
                for i in 1...n {
                    let ok = SoundPlayer.shared.play()
                    try? await Task.sleep(for: .milliseconds(600))
                    let p = SoundPlayer.shared.progress
                    if !ok || p < 0.3 { failed += 1 }
                    print(String(format: "  %2d. play=%@  played %.2f s after 600 ms  %@",
                                 i, ok ? "true " : "false", p,
                                 (ok && p >= 0.3) ? "ok" : "SWALLOWED"))
                    SoundPlayer.shared.stop()
                    try? await Task.sleep(for: .milliseconds(400))
                }
                print(failed == 0 ? "all \(n) attempts ok" : "\(failed) of \(n) failed")
                NSApp.terminate(nil)
            }
            return
        }

        // KITCHENTIMER_DUMP_MENU=1 — prints the context menu structure and exits
        if env["KITCHENTIMER_DUMP_MENU"] != nil {
            func dump(_ m: NSMenu, _ indent: String) {
                for i in m.items {
                    let mark = i.state == .on ? " ✓" : ""
                    print(i.isSeparatorItem ? "\(indent)—" : "\(indent)\(i.title)\(mark)")
                    if let sub = i.submenu { dump(sub, indent + "    ") }
                }
            }
            dump(buildMenu(), "")
            NSApp.terminate(nil)
            return
        }

        // KITCHENTIMER_RENDER=<path.png> [KITCHENTIMER_RENDER_MINUTES=25]
        // [KITCHENTIMER_RENDER_PLAIN=1] — draws the dial and exits
        if let path = env["KITCHENTIMER_RENDER"] {
            dial.simplified = env["KITCHENTIMER_RENDER_PLAIN"] != nil
            timer.scrub(to: (Double(env["KITCHENTIMER_RENDER_MINUTES"] ?? "23") ?? 23) * 60)
            dial.renderPNG(to: path)
            NSApp.terminate(nil)
            return
        }

        panel.applyTransparency()
        panel.clampToScreen()
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        // ⌃⌥⌘M — hide / show the timer
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_M),
                        modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            self?.toggleVisibility()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panel.clampToScreen() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    // MARK: - Actions

    private func toggleVisibility() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func applySize(_ new: CGFloat) {
        Settings.shared.dialSize = new
        panel.resize(to: new)
        dial.frame = NSRect(x: 0, y: 0, width: new, height: new)
        dial.needsDisplay = true
        panel.clampToScreen()
        panel.invalidateShadow()
    }

    // MARK: - Context menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        for m in [1, 2, 3, 5, 10, 15, 20, 25, 30, 45, 60] {
            let item = NSMenuItem(title: L("menu.minutes", m), action: #selector(preset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = m
            menu.addItem(item)
        }

        menu.addItem(.separator())
        add(menu, L(timer.isRunning ? "menu.pause" : "menu.start"), #selector(togglePlay))

        menu.addItem(.separator())

        let sizes = NSMenu()
        for (key, value) in [("menu.size.small", 140.0), ("menu.size.medium", 190.0),
                             ("menu.size.large", 260.0), ("menu.size.huge", 340.0)] {
            let i = NSMenuItem(title: L(key), action: #selector(setSize(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = value
            i.state = abs(Settings.shared.dialSize - value) < 0.5 ? .on : .off
            sizes.addItem(i)
        }
        let sizeItem = NSMenuItem(title: L("menu.size"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let colors = NSMenu()
        for choice in Settings.accentChoices {
            let i = NSMenuItem(title: choice.name, action: #selector(setAccent(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = choice.id
            i.state = Settings.shared.accentID == choice.id ? .on : .off
            colors.addItem(i)
        }
        let colorItem = NSMenuItem(title: L("menu.color"), action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)

        let transparencies = NSMenu()
        for (name, value) in Settings.transparencyChoices {
            let i = NSMenuItem(title: name, action: #selector(setTransparency(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = value
            i.state = abs(Settings.shared.transparency - value) < 0.01 ? .on : .off
            transparencies.addItem(i)
        }
        let transparencyItem = NSMenuItem(title: L("menu.transparency"), action: nil, keyEquivalent: "")
        transparencyItem.submenu = transparencies
        menu.addItem(transparencyItem)

        let sounds = NSMenu()
        let ring = NSMenuItem(title: L("menu.sound.builtin"), action: #selector(setBuiltin(_:)), keyEquivalent: "")
        ring.target = self
        ring.representedObject = "ring"
        ring.state = Settings.shared.soundID == "ring" ? .on : .off
        sounds.addItem(ring)
        sounds.addItem(.separator())
        for name in Settings.systemSounds {
            let i = NSMenuItem(title: name, action: #selector(setSound(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = name
            i.state = Settings.shared.soundID == "system:\(name)" ? .on : .off
            sounds.addItem(i)
        }
        sounds.addItem(.separator())
        if Settings.shared.customSoundURL != nil {
            let i = NSMenuItem(title: Settings.shared.customSoundLabel,
                               action: #selector(playCurrent), keyEquivalent: "")
            i.target = self
            i.state = .on
            sounds.addItem(i)
        }
        let pick = NSMenuItem(title: L("menu.sound.custom"), action: #selector(pickSound), keyEquivalent: "")
        pick.target = self
        sounds.addItem(pick)

        let soundItem = NSMenuItem(title: L("menu.sound"), action: nil, keyEquivalent: "")
        soundItem.submenu = sounds
        menu.addItem(soundItem)

        // only worth showing once there is something to choose between
        if Settings.availableLanguages.count > 1 {
            let languages = NSMenu()
            let system = NSMenuItem(title: L("menu.language.system"),
                                    action: #selector(setLanguage(_:)), keyEquivalent: "")
            system.target = self
            system.representedObject = ""      // empty = follow the system
            system.state = Settings.shared.languageOverride == nil ? .on : .off
            languages.addItem(system)
            languages.addItem(.separator())
            for code in Settings.availableLanguages {
                let i = NSMenuItem(title: Settings.languageName(code),
                                   action: #selector(setLanguage(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = code
                i.state = Settings.shared.languageOverride == code ? .on : .off
                languages.addItem(i)
            }
            let languageItem = NSMenuItem(title: L("menu.language"), action: nil, keyEquivalent: "")
            languageItem.submenu = languages
            menu.addItem(languageItem)
        }

        add(menu, L("menu.darkFace"), #selector(toggleDark))
            .state = Settings.shared.darkFace ? .on : .off
        add(menu, L("menu.snap"), #selector(toggleSnap))
            .state = Settings.shared.snapToMinutes ? .on : .off

        menu.addItem(.separator())
        let hint = NSMenuItem(title: L("menu.hint"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())
        add(menu, L("menu.quit"), #selector(quit))
        return menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
        return i
    }

    @objc private func preset(_ sender: NSMenuItem) {
        timer.scrub(to: TimeInterval(sender.tag) * 60)
        timer.start()
    }
    @objc private func togglePlay() { timer.toggle() }
    @objc private func quit()       { NSApp.terminate(nil) }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        applySize(CGFloat(v))
    }
    @objc private func setAccent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.accentID = id
        dial.needsDisplay = true
    }
    @objc private func setTransparency(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.shared.transparency = v
        panel.applyTransparency()
    }
    @objc private func setSound(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? String else { return }
        Settings.shared.soundID = "system:\(n)"
        preview()
    }
    @objc private func setBuiltin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.soundID = id
        preview()
    }
    @objc private func playCurrent() { preview() }

    @objc private func pickSound() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.prompt = L("sound.panel.prompt")
        p.message = L("sound.panel.message")
        // an accessory app has to come forward, or the panel opens behind
        // every other window
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        guard let local = Settings.shared.adoptSound(from: url) else {
            let a = NSAlert()
            a.messageText = L("sound.error.title")
            a.informativeText = L("sound.error.body", url.lastPathComponent)
            a.runModal()
            return
        }
        Settings.shared.customSoundLabel = url.lastPathComponent
        Settings.shared.soundID = "file:\(local.path)"
        preview()
    }

    /// A preview after picking — otherwise you cannot tell what you chose.
    private func preview() {
        SoundPlayer.shared.play()
    }

    /// Strings are read once at launch, so a language switch relaunches
    /// the app rather than trying to rebuild everything in place.
    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        let picked: String? = code.isEmpty ? nil : code
        guard picked != Settings.shared.languageOverride else { return }
        Settings.shared.languageOverride = picked
        UserDefaults.standard.synchronize()
        relaunch()
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    @objc private func toggleDark() {
        Settings.shared.darkFace.toggle()
        dial.needsDisplay = true
    }
    @objc private func toggleSnap() {
        Settings.shared.snapToMinutes.toggle()
    }
}

// Top-level code in main.swift runs on the main thread, but the compiler
// does not see it as isolated — hence assumeIsolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no app switcher entry
    _ = delegate                          // keeps the delegate alive (NSApp holds it weakly)
    app.run()
}
