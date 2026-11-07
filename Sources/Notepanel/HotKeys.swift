import Carbon.HIToolbox

/// Global shortcuts through Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.
@MainActor
final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hot key events on the main thread.
                MainActor.assumeIsolated { hotKeys.actions[id.id]?() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    /// Replaces every registered shortcut. One that another app already holds is skipped.
    func set(_ bindings: [(Shortcut, () -> Void)]) {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        for (index, (shortcut, action)) in bindings.enumerated() {
            let id = EventHotKeyID(signature: OSType(0x6E70_6E6C), id: UInt32(index + 1))  // 'npnl'
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode), UInt32(shortcut.modifiers), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id.id] = action
            }
        }
    }
}
