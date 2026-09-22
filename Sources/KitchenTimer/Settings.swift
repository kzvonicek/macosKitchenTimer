import AppKit
import UniformTypeIdentifiers
import AVFoundation

/// Stored preferences. The window position is saved separately through
/// `setFrameAutosaveName`.
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// The app used to be called Minutka and wrote under that bundle id.
    private static let legacyDomain = "eu.zvonicek.minutka"

    private enum Key {
        static let size = "dialSize"
        static let dark = "darkFace"
        static let sound = "soundID"
        static let snap = "snapMinutes"
        static let last = "lastMinutes"
        static let accent = "accentID"
        static let transparency = "transparency"
        static let soundLabel = "soundLabel"
        static let migrated = "migratedFromMinutka"
    }

    init() {
        d.register(defaults: [
            Key.size: 190.0,
            Key.dark: false,
            Key.sound: "ring",
            Key.snap: true,
            Key.last: 0.0,
            Key.accent: "red",
            Key.transparency: 0.0,
        ])
    }

    // MARK: - Dial

    var dialSize: CGFloat {
        get { CGFloat(d.double(forKey: Key.size)) }
        set { d.set(Double(newValue), forKey: Key.size) }
    }

    var darkFace: Bool {
        get { d.bool(forKey: Key.dark) }
        set { d.set(newValue, forKey: Key.dark) }
    }

    var snapToMinutes: Bool {
        get { d.bool(forKey: Key.snap) }
        set { d.set(newValue, forKey: Key.snap) }
    }

    /// The last time dialed in by hand, in minutes. On launch the dial shows
    /// it again, stopped.
    var lastMinutes: Double {
        get { d.double(forKey: Key.last) }
        set { d.set(newValue, forKey: Key.last) }
    }

    // MARK: - Colour

    /// A stable identifier is stored, not the label: labels get translated
    /// and a stored one would stop matching after a language change.
    var accentID: String {
        get { d.string(forKey: Key.accent) ?? "red" }
        set { d.set(newValue, forKey: Key.accent) }
    }

    var accent: NSColor {
        Self.accentChoices.first { $0.id == accentID }?.color
            ?? Self.accentChoices[0].color
    }

    /// Colours used to be stored under their Czech names.
    func migrateAccentIfNeeded() {
        let old = ["Červená": "red", "Tyrkysová": "teal", "Žlutá": "yellow",
                   "Zelená": "green", "Oranžová": "orange"]
        if let mapped = old[accentID] { accentID = mapped }
    }

    static let accentChoices: [(id: String, name: String, color: NSColor)] = [
        ("red",    L("color.red"),    NSColor(srgbRed: 0.87, green: 0.24, blue: 0.24, alpha: 1)),
        ("teal",   L("color.teal"),   NSColor(srgbRed: 0.11, green: 0.66, blue: 0.70, alpha: 1)),
        ("yellow", L("color.yellow"), NSColor(srgbRed: 0.93, green: 0.74, blue: 0.13, alpha: 1)),
        ("green",  L("color.green"),  NSColor(srgbRed: 0.29, green: 0.66, blue: 0.34, alpha: 1)),
        ("orange", L("color.orange"), NSColor(srgbRed: 0.94, green: 0.53, blue: 0.14, alpha: 1)),
    ]

    // MARK: - Transparency

    /// 0 = opaque, 1 = fully see-through.
    var transparency: Double {
        get { min(max(d.double(forKey: Key.transparency), 0), 1) }
        set { d.set(min(max(newValue, 0), 1), forKey: Key.transparency) }
    }

    /// Opacity for `NSWindow.alphaValue`. The floor is a safeguard: a fully
    /// transparent timer could be neither found nor clicked. The menu stops
    /// at 80 %; for hiding there is ⌃⌥⌘M, which can be undone.
    var windowAlpha: Double { max(0.05, 1 - transparency) }

    static let transparencyChoices: [(name: String, value: Double)] = [
        ("0 %", 0.0), ("20 %", 0.2), ("40 %", 0.4), ("60 %", 0.6), ("80 %", 0.8),
    ]

    // MARK: - Sound

    /// Sound identifier: "ring" (recording of a real kitchen timer),
    /// "system:<name>" or "file:<path>".
    var soundID: String {
        get { d.string(forKey: Key.sound) ?? "ring" }
        set { d.set(newValue, forKey: Key.sound) }
    }

    var customSoundURL: URL? {
        guard soundID.hasPrefix("file:") else { return nil }
        return URL(fileURLWithPath: String(soundID.dropFirst(5)))
    }

    /// The file name as the user knows it — for the menu.
    var customSoundLabel: String {
        get { d.string(forKey: Key.soundLabel) ?? L("sound.custom.fallback") }
        set { d.set(newValue, forKey: Key.soundLabel) }
    }

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("KitchenTimer", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// URL of the selected sound. System sounds are plain aiff files
    /// in /System/Library/Sounds.
    func soundURL() -> URL? {
        if soundID.hasPrefix("system:") {
            let name = String(soundID.dropFirst(7))
            let u = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            return FileManager.default.isReadableFile(atPath: u.path) ? u : builtinURL()
        }
        if let u = customSoundURL, FileManager.default.isReadableFile(atPath: u.path) {
            return u
        }
        return builtinURL()
    }

    func builtinURL() -> URL? {
        Bundle.main.url(forResource: "ring", withExtension: "wav")
    }

    /// AVAudioPlayer rather than NSSound — it holds on to its own data and
    /// does not vanish when the instance stops being retained elsewhere.
    func makePlayer() -> AVAudioPlayer? {
        guard let url = soundURL() else { return nil }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        p.volume = 1
        p.prepareToPlay()
        return p
    }

    /// A custom sound is converted into our own directory as stereo 48 kHz.
    ///
    /// Two reasons. Storing just a path is not enough: a file in iCloud Drive
    /// gets evicted from disk and leaves a placeholder behind, on which
    /// playback fails silently. And a mono track on a multi-channel output
    /// (a monitor over DisplayPort reports 6 channels) can land on a channel
    /// the speakers do not play. The original is left untouched.
    func adoptSound(from url: URL) -> URL? {
        let fm = FileManager.default

        // pull an iCloud placeholder down; we wait only briefly, the user is
        // standing at the panel
        if !fm.isReadableFile(atPath: url.path) {
            try? fm.startDownloadingUbiquitousItem(at: url)
            let deadline = Date().addingTimeInterval(8)
            while !fm.isReadableFile(atPath: url.path), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        guard fm.isReadableFile(atPath: url.path) else { return nil }

        // convert aside first: the source may be last time's file, which the
        // cleanup below would delete from under us
        let staging = supportDir.appendingPathComponent("staging.wav")
        try? fm.removeItem(at: staging)

        var produced: URL?
        if Self.convertToStereo(url, to: staging) {
            produced = staging
        } else {
            // conversion failed — a copy of the original beats nothing
            let raw = supportDir.appendingPathComponent("staging." + url.pathExtension)
            try? fm.removeItem(at: raw)
            if (try? fm.copyItem(at: url, to: raw)) != nil { produced = raw }
        }
        guard let made = produced else { return nil }

        for old in (try? fm.contentsOfDirectory(at: supportDir, includingPropertiesForKeys: nil)) ?? []
        where old.lastPathComponent.hasPrefix("alarm.") {
            try? fm.removeItem(at: old)
        }

        let dest = supportDir.appendingPathComponent("alarm." + made.pathExtension)
        try? fm.removeItem(at: dest)
        guard (try? fm.moveItem(at: made, to: dest)) != nil else { return nil }
        return dest
    }

    /// afconvert ships with the system; rolling the conversion by hand with
    /// AVAudioConverter would be a lot more code for the same result.
    private static func convertToStereo(_ src: URL, to dest: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@48000", "-c", "2", src.path, dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
            && FileManager.default.isReadableFile(atPath: dest.path)
    }

    /// Brings a previously stored reference to an outside file into our
    /// directory. If that fails, it falls back to the built-in bell.
    func migrateCustomSoundIfNeeded() {
        guard let url = customSoundURL else { return }
        // a file copied in earlier goes through again unless it is already
        // the stereo wav
        guard url != supportDir.appendingPathComponent("alarm.wav") else { return }
        if let local = adoptSound(from: url) {
            if d.string(forKey: Key.soundLabel) == nil {
                customSoundLabel = url.lastPathComponent
            }
            soundID = "file:\(local.path)"
        } else {
            soundID = "ring"
        }
    }

    static let systemSounds = ["Glass", "Ping", "Submarine", "Funk", "Hero", "Purr"]

    // MARK: - Language

    /// Language codes the bundle actually carries, i.e. one per `*.lproj`.
    /// Dropping another one into Resources makes it show up in the menu.
    /// Codes are deduplicated — the list arrives from both the directories
    /// and `CFBundleLocalizations`, so every language turns up twice.
    static var availableLanguages: [String] {
        Array(Set(Bundle.main.localizations.filter { $0 != "Base" })).sorted()
    }

    /// Name of a language in its own language — "English", "Čeština".
    static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Language forced from the menu, or nil when the system decides.
    /// `AppleLanguages` in our own domain overrides the system preference.
    var languageOverride: String? {
        get { (d.array(forKey: "AppleLanguages") as? [String])?.first }
        set {
            if let code = newValue {
                d.set([code], forKey: "AppleLanguages")
            } else {
                d.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    // MARK: - Rename migration

    /// Carries settings over from the old `eu.zvonicek.minutka` bundle id,
    /// so renaming the app does not reset everything. Runs once.
    func migrateFromLegacyDomainIfNeeded() {
        guard !d.bool(forKey: Key.migrated) else { return }
        d.set(true, forKey: Key.migrated)

        guard let old = UserDefaults(suiteName: Self.legacyDomain) else { return }
        // values are written unconditionally — `object(forKey:)` would report
        // the registered default and never look empty. The flag above keeps
        // this to a single run, so nothing set later gets overwritten.
        for key in [Key.size, Key.dark, Key.sound, Key.snap, Key.last,
                    Key.accent, Key.transparency, Key.soundLabel,
                    "accentColor", "NSWindow Frame MinutkaOverlay"] {
            guard let value = old.object(forKey: key) else { continue }
            switch key {
            case "NSWindow Frame MinutkaOverlay":
                d.set(value, forKey: "NSWindow Frame \(OverlayPanel.autosaveName)")
            case "accentColor":
                // the colour key was renamed along the way
                if old.object(forKey: Key.accent) == nil { d.set(value, forKey: Key.accent) }
            default:
                d.set(value, forKey: key)
            }
        }
    }
}
