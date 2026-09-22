import AppKit

/// The dial, drawn straight through CoreGraphics.
/// (SwiftUI is out here — Command Line Tools ship no SwiftUI macro plugin,
/// so `@State` does not expand and the project would need Xcode to build.)
final class DialView: NSView {

    let timer: TimerModel
    var menuBuilder: (() -> NSMenu)?

    /// Drawing for small icon sizes: no numerals or time, heavier ticks.
    /// At 16 px the fine detail collapses into grey mush.
    var simplified = false

    /// Drag angle in degrees, held between 0 and 360. It is unwrapped rather
    /// than taken raw, so dragging past twelve o'clock does not jump from
    /// 59 minutes to zero, and clamped, so it cannot wind up a surplus of
    /// whole turns that would have to be unwound again.
    private var dragAngle: Double?
    private var dragMoved = false
    private var windowDragStart: (mouse: NSPoint, origin: NSPoint)?
    private var scrollAccumulator: Double = 0
    private var blinkOn = false
    private var blinkTimer: Timer?

    private var accent: NSColor { Settings.shared.accent }
    private var face: NSColor {
        Settings.shared.darkFace ? NSColor(white: 0.13, alpha: 1)
                                 : NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
    }
    private var ink: NSColor {
        Settings.shared.darkFace ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.16, alpha: 1)
    }

    init(timer: TimerModel, size: CGFloat) {
        self.timer = timer
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        timer.onChange = { [weak self] in self?.needsDisplay = true }
        timer.onAlarmChange = { [weak self] on in self?.setBlinking(on) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Geometry

    private var side: CGFloat { min(bounds.width, bounds.height) }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var radius: CGFloat { side / 2 }
    /// Thickness of the steel bezel.
    private var ringWidth: CGFloat { max(3, side * 0.042) }
    private var faceR: CGFloat { radius - ringWidth }
    /// Drawn size of the centre knob.
    private var knobR: CGFloat { side * 0.034 }
    /// Its grab area is wider than the drawing — at 190 px the knob itself is
    /// about six pixels across, which is too small to aim at.
    private var knobGrabR: CGFloat { side * 0.075 }

    /// Angle of a point from the centre in degrees: 0 at twelve o'clock,
    /// growing clockwise.
    private func angle(of p: CGPoint) -> Double {
        let deg = atan2(p.x - center.x, p.y - center.y) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        dragMoved = false
        dragAngle = nil
        let p = convert(event.locationInWindow, from: nil)
        let distance = hypot(p.x - center.x, p.y - center.y)
        let onHandle = distance > faceR || distance < knobGrabR

        // the bezel and the centre knob carry the timer around,
        // the face between them winds it up
        if onHandle || event.modifierFlags.contains(.command), let win = window {
            windowDragStart = (NSEvent.mouseLocation, win.frame.origin)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        dragMoved = true

        if let start = windowDragStart, let win = window {
            let now = NSEvent.mouseLocation
            win.setFrameOrigin(NSPoint(x: start.origin.x + (now.x - start.mouse.x),
                                       y: start.origin.y + (now.y - start.mouse.y)))
            return
        }

        let p = convert(event.locationInWindow, from: nil)
        let a = angle(of: p)
        if let prev = dragAngle {
            var delta = a - prev
            if delta >  180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            // the accumulator itself is clamped, not just the time it maps to:
            // letting it run free meant winding several turns past the hour and
            // then having to unwind that invisible surplus before anything moved
            dragAngle = min(max(prev + delta, 0), 360)
        } else {
            dragAngle = a
        }

        var minutes = (dragAngle ?? a) / 6
        // ⌥ gives the fine step, otherwise whole minutes
        if Settings.shared.snapToMinutes && !event.modifierFlags.contains(.option) {
            minutes.round()
        }
        timer.scrub(to: minutes * 60)
    }

    override func mouseUp(with event: NSEvent) {
        defer { windowDragStart = nil; dragAngle = nil }

        if windowDragStart != nil {
            if !dragMoved { timer.toggle() }   // click on the bezel without moving
            window?.saveFrame(usingName: OverlayPanel.autosaveName)
            return
        }

        if dragMoved {
            if timer.remaining > 0 { timer.start() }
        } else {
            timer.toggle()                     // plain click = pause / resume
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuBuilder?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The wheel nudges the time by a fixed step per notch.
    ///
    /// Deriving the step from the delta size gave different amounts on
    /// different devices, so one notch is one step regardless. A trackpad
    /// sends a stream of small deltas instead of notches, so those are
    /// accumulated until they add up to one.
    override func scrollWheel(with event: NSEvent) {
        let dy = Double(event.scrollingDeltaY)
        guard abs(dy) > 0.001 else { return }

        var notches: Double
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += dy
            notches = (scrollAccumulator / Self.pointsPerNotch).rounded(.towardZero)
            guard abs(notches) >= 1 else { return }
            scrollAccumulator -= notches * Self.pointsPerNotch
        } else {
            notches = dy > 0 ? 1 : -1
        }

        let target = timer.remaining + notches * Self.secondsPerNotch
        timer.scrub(to: max(0, min(target, TimerModel.maxSeconds)))
        if timer.remaining > 0 { timer.start() }
    }

    /// Seconds added or removed by one notch of the wheel.
    private static let secondsPerNotch: TimeInterval = 15
    /// How many trackpad points count as one notch.
    private static let pointsPerNotch: Double = 8

    // MARK: - Blinking while ringing

    private func setBlinking(_ on: Bool) {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkOn = false
        guard on else { needsDisplay = true; return }
        let t = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.blinkOn.toggle()
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = side
        let c = center
        let r = radius - 0.5

        // face
        ctx.setFillColor(face.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - faceR, y: c.y - faceR, width: faceR * 2, height: faceR * 2))

        // remaining wedge
        let f = timer.fraction
        if f > 0.0005 && !(timer.isAlarming && blinkOn) {
            ctx.setFillColor(accent.withAlphaComponent(timer.isRunning || timer.isAlarming ? 1 : 0.75).cgColor)
            ctx.beginPath()
            ctx.move(to: c)
            ctx.addArc(center: c, radius: faceR * 0.99,
                       startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * f, clockwise: true)
            ctx.closePath()
            ctx.fillPath()
        }

        // ticks
        for i in 0..<60 {
            let major = i % 5 == 0
            if simplified && !major { continue }
            let a = Double(i) * 6 * .pi / 180
            let dx = sin(a), dy = cos(a)
            let outer = faceR * 0.98
            let inner = faceR * (major ? (simplified ? 0.78 : 0.85) : 0.91)
            ctx.setStrokeColor(ink.withAlphaComponent(major ? 0.85 : 0.35).cgColor)
            ctx.setLineWidth(major ? max(1.5, s / (simplified ? 55 : 110)) : 1)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: c.x + dx * inner, y: c.y + dy * inner))
            ctx.addLine(to: CGPoint(x: c.x + dx * outer, y: c.y + dy * outer))
            ctx.strokePath()
        }

        // numerals every five minutes, zero at twelve o'clock
        if !simplified {
            let numR = faceR * 0.72
            let numFont = NSFont.systemFont(ofSize: max(7, s * 0.072), weight: .medium)
            for step in stride(from: 0, through: 55, by: 5) {
                let a = Double(step) * 6 * .pi / 180
                let p = CGPoint(x: c.x + sin(a) * numR, y: c.y + cos(a) * numR)
                draw(text: "\(step)", font: numFont, color: ink.withAlphaComponent(0.8), centeredAt: p)
            }
        }

        // remaining time
        if !simplified, timer.remaining > 0 || timer.isAlarming {
            let f = NSFont.monospacedDigitSystemFont(ofSize: s * 0.095, weight: .semibold)
            draw(text: timer.label, font: f, color: ink.withAlphaComponent(0.92),
                 centeredAt: CGPoint(x: c.x, y: c.y - faceR * 0.40))
        }

        // steel bezel
        drawSteel(ctx, center: c, outer: r, inner: faceR)

        // steel centre knob
        drawKnob(ctx, center: c, radius: knobR)

        // index at twelve o'clock
        ctx.setFillColor(accent.cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: c.x - s * 0.024, y: c.y + r - 0.5))
        ctx.addLine(to: CGPoint(x: c.x + s * 0.024, y: c.y + r - 0.5))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + faceR * 0.90))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Brushed steel: a ring assembled from thin wedges whose brightness
    /// travels around in four bright bands. (CoreGraphics has no conic
    /// gradient — that one lives only on CAGradientLayer.)
    private func drawSteel(_ ctx: CGContext, center c: CGPoint, outer: CGFloat, inner: CGFloat) {
        let segments = 180
        let step = 2 * Double.pi / Double(segments)
        ctx.saveGState()
        for i in 0..<segments {
            let a0 = Double(i) * step
            let a1 = a0 + step * 1.2          // overlap, or thin gaps show through
            let t = Double(i) / Double(segments)
            let w = 0.50 + 0.38 * abs(sin(t * .pi * 4))
            ctx.setFillColor(NSColor(white: CGFloat(w), alpha: 1).cgColor)
            ctx.beginPath()
            ctx.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
            if inner > 0 {
                ctx.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
            } else {
                ctx.addLine(to: c)
            }
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.restoreGState()

        // edges — without them the ring melts into the background
        ctx.setLineWidth(0.75)
        ctx.setStrokeColor(NSColor(white: 0.15, alpha: 0.55).cgColor)
        ctx.strokeEllipse(in: CGRect(x: c.x - outer + 0.4, y: c.y - outer + 0.4,
                                     width: (outer - 0.4) * 2, height: (outer - 0.4) * 2))
        if inner > 0 {
            ctx.setStrokeColor(NSColor(white: 0.2, alpha: 0.4).cgColor)
            ctx.strokeEllipse(in: CGRect(x: c.x - inner, y: c.y - inner,
                                         width: inner * 2, height: inner * 2))
        }
    }

    /// The knob — at this size a vertical light-to-dark ramp reads as metal
    /// better than wedges, which would blur into a star.
    private func drawKnob(_ ctx: CGContext, center c: CGPoint, radius: CGFloat) {
        let box = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.addEllipse(in: box)
        ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                           colors: [NSColor(white: 0.86, alpha: 1).cgColor,
                                    NSColor(white: 0.60, alpha: 1).cgColor,
                                    NSColor(white: 0.38, alpha: 1).cgColor] as CFArray,
                           locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: c.x, y: box.maxY),
                               end: CGPoint(x: c.x, y: box.minY), options: [])
        ctx.restoreGState()
        ctx.setLineWidth(0.6)
        ctx.setStrokeColor(NSColor(white: 0.12, alpha: 0.5).cgColor)
        ctx.strokeEllipse(in: box.insetBy(dx: 0.3, dy: 0.3))
    }

    /// Off-screen render of the dial into a PNG — used to build the app icon.
    func renderPNG(to path: String) {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func draw(text: String, font: NSFont, color: NSColor, centeredAt p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2))
    }
}
