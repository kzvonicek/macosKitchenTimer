import AppKit

/// A nonactivating panel — clicking the timer does not steal focus from
/// whatever is underneath.
final class OverlayPanel: NSPanel {

    static let autosaveName = "KitchenTimerOverlay"

    init(size: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar                 // above ordinary windows and full-screen content
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false // moving is handled in DialView
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applyTransparency() {
        alphaValue = Settings.shared.windowAlpha
    }

    func resize(to size: CGFloat) {
        let origin = frame.origin
        let top = frame.maxY
        setFrame(NSRect(x: origin.x, y: top - size, width: size, height: size), display: true)
    }

    /// Pulls the window back onto visible screen when the display setup changes.
    func clampToScreen() {
        guard let vis = (screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = frame
        f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
        if f != frame { setFrame(f, display: true) }
    }
}
