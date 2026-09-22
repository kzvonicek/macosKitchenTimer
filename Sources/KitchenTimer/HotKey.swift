import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon — unlike CGEventTap it needs no
/// Accessibility permission, so the app works the moment it launches.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var counter: UInt32 = 0
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false

    /// - Parameters:
    ///   - keyCode: virtual key code (`kVK_ANSI_M` and friends)
    ///   - modifiers: Carbon mask (`cmdKey | optionKey | controlKey`)
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        Self.counter += 1
        id = Self.counter
        Self.installHandlerIfNeeded()
        Self.actions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x4B544D52), id: id) // 'KTMR'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            Self.actions[id] = nil
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard err == noErr else { return err }
            let id = hkID.id
            DispatchQueue.main.async { HotKey.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
