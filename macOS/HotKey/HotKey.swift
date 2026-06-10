import Carbon.HIToolbox
import Foundation

/// Minimal Carbon global-hotkey wrapper (defaults to ⇧⌘V). Carbon's
/// `RegisterEventHotKey` remains fully supported for this purpose and needs no
/// special permissions, unlike CGEvent taps.
final class HotKey {
    private static let signature: OSType = 0x434C_5053 // "CLPS"
    private static let hotKeyIdentifier: UInt32 = 1

    private let handler: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Returns nil when the handler installation or hotkey registration fails
    /// (e.g. the combination is already taken by another app).
    init?(
        keyCode: UInt32 = UInt32(kVK_ANSI_V),
        modifiers: UInt32 = UInt32(cmdKey | shiftKey),
        handler: @escaping () -> Void
    ) {
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard
                    status == noErr,
                    hotKeyID.signature == HotKey.signature,
                    hotKeyID.id == HotKey.hotKeyIdentifier
                else { return OSStatus(eventNotHandledErr) }

                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    hotKey.handler()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
        guard installStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyIdentifier)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        // On failure, deinit still runs for a failed class initializer and
        // removes the already-installed event handler.
        guard registerStatus == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
