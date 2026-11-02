import AppKit
import Carbon

struct LauncherShortcut: Codable, Equatable {
    var keyCode: UInt32 = UInt32(kVK_Space)
    var control = true
    var option = true
    var command = false
    var shift = false
    var modifiers: UInt32 {
        (control ? UInt32(controlKey) : 0) | (option ? UInt32(optionKey) : 0)
            | (command ? UInt32(cmdKey) : 0) | (shift ? UInt32(shiftKey) : 0)
    }
    static let keys: [(String, UInt32)] = [("Space", UInt32(kVK_Space))] + [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
        ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31),
        ("P", 35), ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9),
        ("W", 13), ("X", 7), ("Y", 16), ("Z", 6)
    ].map { ($0.0, UInt32($0.1)) }
    var valid: Bool { (control || command) && Self.keys.contains { $0.1 == keyCode } }
    var title: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + (Self.keys.first { $0.1 == keyCode }?.0 ?? "Unknown")
    }
}

@MainActor protocol LauncherHotKeyBackend: AnyObject {
    func register(_ shortcut: LauncherShortcut, action: @escaping () -> Void) throws
    func unregister()
}

enum LauncherHotKeyError: LocalizedError {
    case invalid, reserved, registration(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalid: "Choose a key with Control or Command."
        case .reserved: "This shortcut is assigned to a macOS system command. Choose another combination."
        case .registration(let status): "The global shortcut could not be registered (\(status)). Choose another combination. Quick Launcher remains available in the File menu."
        }
    }
}

@MainActor final class CarbonLauncherHotKey: LauncherHotKeyBackend {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private static let signature: UInt32 = 0x53574244

    func register(_ shortcut: LauncherShortcut, action: @escaping () -> Void) throws {
        unregister()
        guard shortcut.valid else { throw LauncherHotKeyError.invalid }
        var systemKeys: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&systemKeys) == noErr, let array = systemKeys?.takeRetainedValue() as? [[String: Any]] {
            if array.contains(where: {
                ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true &&
                ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == shortcut.keyCode &&
                ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == shortcut.modifiers
            }) { throw LauncherHotKeyError.reserved }
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x53574244, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<CarbonLauncherHotKey>.fromOpaque(context).takeUnretainedValue().action?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { unregister(); throw LauncherHotKeyError.registration(installed) }
        self.action = action
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr else { unregister(); throw LauncherHotKeyError.registration(status) }
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil; handler = nil; action = nil
    }
}
