// macOS Platform_Layer: event tap (Req 2), output synthesis (Req 16), permissions (Req 18).

import AppKit
import ApplicationServices
import Carbon
import KeyChordCore

// MARK: - Event tap

/// Session-level CGEvent tap on the main run loop. The handler must not block (Req 2.9).
final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    var isRunning: Bool { port.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Starts the tap, or brings back one that macOS disabled or invalidated (for example after the
    /// Accessibility grant was reset and given again while KeyChord was running).
    func start() -> Bool {
        if let port {
            if CFMachPortIsValid(port) {
                CGEvent.tapEnable(tap: port, enable: true)
                if CGEvent.tapIsEnabled(tap: port) { return true }
            }
            stop()
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: eventTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.port = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func reenable() {
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// Removes the tap so the next start() creates a fresh one.
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        source = nil
        port = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        handler(type, event)
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type, event)
}

// MARK: - Event conversion

enum EventConversion {
    /// Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK), so left and right keys are told apart.
    static let deviceMasks: [KeyCode: (ModifierKey, UInt64)] = [
        56: (.shift, 0x02), 60: (.shift, 0x04),
        59: (.control, 0x01), 62: (.control, 0x2000),
        58: (.option, 0x20), 61: (.option, 0x40),
        55: (.command, 0x08), 54: (.command, 0x10),
    ]

    static func flags(_ f: CGEventFlags) -> ModifierFlags {
        var m: ModifierFlags = []
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskAlphaShift) { m.insert(.capsLock) }        // Req 9.10
        return m
    }

    /// Which modifier a flagsChanged event is about, and whether it went down.
    static func modifierChange(code: KeyCode, flags: UInt64) -> (ModifierKey, Bool)? {
        if let (key, mask) = deviceMasks[code] {
            let allDeviceBits: UInt64 = 0x207F
            if flags & allDeviceBits != 0 { return (key, flags & mask != 0) }
            // Some events carry no device bits; fall back to the generic flag.
            let generic: CGEventFlags = key == .shift ? .maskShift : key == .control ? .maskControl
                : key == .option ? .maskAlternate : .maskCommand
            return (key, CGEventFlags(rawValue: flags).contains(generic))
        }
        switch code {
        case 57: return (.capsLock, CGEventFlags(rawValue: flags).contains(.maskAlphaShift))
        case 63: return (.function, CGEventFlags(rawValue: flags).contains(.maskSecondaryFn))
        default: return nil
        }
    }

    static func nowMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
}

// MARK: - Output emission

/// Applies Output_Actions with tagged Synthetic_Events (Req 2.7, 16.1 - 16.3).
final class OutputEmitter {
    /// Tag stored in kCGEventSourceUserData ("KCHD").
    static let tag: Int64 = 0x4B43_4844
    private let source = CGEventSource(stateID: .privateState)

    enum Failure: Error { case eventCreation }

    static func isSynthetic(_ e: CGEvent) -> Bool { e.getIntegerValueField(.eventSourceUserData) == tag }

    func emit(_ actions: [OutputAction]) throws {
        for a in actions {
            switch a {
            case .insert(let s): try insert(s)
            case .deleteBackward(let n): try tap(51, n)      // Delete
            case .deleteForward(let n): try tap(117, n)      // Forward Delete
            case .moveLeft(let n): try tap(123, n)           // Left Arrow
            case .moveRight(let n): try tap(124, n)          // Right Arrow
            }
        }
    }

    private func event(_ code: CGKeyCode, down: Bool) throws -> CGEvent {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { throw Failure.eventCreation }
        e.flags = []                                          // Req 16.3
        e.setIntegerValueField(.eventSourceUserData, value: Self.tag)
        return e
    }

    private func tap(_ code: CGKeyCode, _ n: Int) throws {
        guard n > 0 else { return }
        for _ in 0..<n {
            try event(code, down: true).post(tap: .cghidEventTap)
            try event(code, down: false).post(tap: .cghidEventTap)
        }
    }

    /// Unicode text, independent of layout and Caps Lock (Req 16.2). Chunks stay on grapheme boundaries.
    private func insert(_ s: String) throws {
        var chunk: [UniChar] = []
        func flush() throws {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                let e = try event(0, down: down)
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.post(tap: .cghidEventTap)
            }
            chunk.removeAll()
        }
        for ch in s {
            let units = Array(String(ch).utf16)
            if chunk.count + units.count > 20 { try flush() }
            chunk += units
        }
        try flush()
    }
}

// MARK: - Permissions and system state

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// Informational only. KeyChord's tap is an active (filtering) tap, which macOS allows with the
    /// Accessibility grant alone; Input Monitoring only covers listen-only taps. Requiring it as well
    /// kept KeyChord in "no permission" after a TCC reset, because nothing re-adds the app to that list.
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    static var allGranted: Bool { accessibility }

    static func openAccessibility() {
        // Prompting adds KeyChord to the Accessibility list, which matters after `tccutil reset`:
        // without it the app is not listed and has to be added by hand with "+".
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openInputMonitoring() {
        _ = CGRequestListenEventAccess()   // adds KeyChord to the Input Monitoring list
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

}

enum SecureInput {
    static var isOn: Bool { IsSecureEventInputEnabled() }
}

// MARK: - Hardware

enum Hardware {
    /// The Mac model, for example "MacBookPro18,3".
    static var model: String { sysctl("hw.model") ?? "unknown" }
    static var chip: String { sysctl("machdep.cpu.brand_string") ?? "" }

    /// The keyboard type macOS has for the keyboard ("ISO", "ANSI", "JIS" or "unknown"). It is the type of the
    /// keyboard used last, so with an external keyboard it may not be the built-in one's.
    static var keyboardType: String {
        switch Int(KBGetLayoutType(Int16(LMGetKbdType()))) {
        case kKeyboardISO: return "ISO"
        case kKeyboardJIS: return "JIS"
        case kKeyboardANSI: return "ANSI"
        default: return "unknown"
        }
    }

    /// The physical layout to draw and take the wiring of, from `keyboardType`: nil for JIS and unknown types.
    static var detectedKeyboard: KeyboardGeometry.Kind? {
        switch keyboardType {
        case "ISO": return .iso
        case "ANSI": return .ansi
        default: return nil
        }
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// Codes of every key the hardware currently reports as down (Req 3.11).
func physicallyHeldKeys() -> Set<KeyCode> {
    var out = Set<KeyCode>()
    for code in 0..<128 where CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) {
        out.insert(KeyCode(code))
    }
    return out
}
