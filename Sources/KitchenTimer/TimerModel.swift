import AppKit

/// The countdown holds an absolute `deadline` instead of subtracting ticks —
/// it survives the machine going to sleep and a congested run loop.
@MainActor
final class TimerModel {

    static let maxSeconds: TimeInterval = 3600   // a full dial = 60 minutes

    private(set) var remaining: TimeInterval = 0 { didSet { onChange?() } }
    private(set) var isRunning = false           { didSet { onChange?() } }
    private(set) var isAlarming = false          { didSet { onAlarmChange?(isAlarming) } }

    var onChange: (() -> Void)?
    var onAlarmChange: ((Bool) -> Void)?

    private var deadline: Date?
    private var ticker: Timer?
    private var alarmTimer: Timer?

    var fraction: Double { min(remaining / Self.maxSeconds, 1) }

    var label: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Control

    /// Dragging across the dial: sets the time and keeps the countdown
    /// still until the button is released.
    func scrub(to seconds: TimeInterval) {
        stopAlarm()
        stopTicker()
        deadline = nil
        isRunning = false
        remaining = max(0, min(seconds, Self.maxSeconds))
        Settings.shared.lastMinutes = remaining / 60
    }

    /// Restores the previous time without starting the countdown.
    func restoreLast() {
        let m = Settings.shared.lastMinutes
        guard m > 0 else { return }
        remaining = min(m * 60, Self.maxSeconds)
    }

    func start() {
        guard remaining > 0 else { return }
        stopAlarm()
        deadline = Date().addingTimeInterval(remaining)
        isRunning = true
        startTicker()
    }

    func pause() {
        guard isRunning else { return }
        deadline = nil
        isRunning = false
        stopTicker()
    }

    func toggle() {
        if isAlarming { reset(); return }
        isRunning ? pause() : start()
    }

    func reset() {
        stopAlarm()
        stopTicker()
        deadline = nil
        isRunning = false
        remaining = 0
    }

    // MARK: - Running

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common — otherwise the countdown stalls while a menu is open
        // or the window is being dragged
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let deadline else { return }
        let left = deadline.timeIntervalSinceNow
        if left <= 0 {
            self.deadline = nil
            stopTicker()
            isRunning = false
            remaining = 0
            fire()
        } else {
            remaining = left
        }
    }

    // MARK: - Alarm

    private func fire() {
        isAlarming = true

        let len = SoundPlayer.shared.duration
        SoundPlayer.shared.play()

        // once the sound is done the dial keeps blinking until someone stops it
        let t = Timer(timeInterval: max(1, len) + 0.3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.alarmTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        alarmTimer = t
    }

    func stopAlarm() {
        alarmTimer?.invalidate()
        alarmTimer = nil
        SoundPlayer.shared.stop()
        if isAlarming { isAlarming = false }
    }
}
