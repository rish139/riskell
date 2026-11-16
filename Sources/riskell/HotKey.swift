import Carbon.HIToolbox
import Foundation
import RiskellKit

/// Global hotkeys through Carbon's RegisterEventHotKey: no Accessibility or Input Monitoring needed, and nothing runs until the key is pressed.
enum HotKey {
    private static var refs: [EventHotKeyRef?] = []
    private static var actions: [UInt32: () -> Void] = [:]

    /// `key` is a kVK_ code, `mods` Carbon modifier bits (controlKey | optionKey ...). Returns false if another app holds the combination.
    @discardableResult
    static func register(key: Int, mods: Int, _ action: @escaping () -> Void) -> Bool {
        if actions.isEmpty {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { HotKey.actions[id.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(UInt32(key), UInt32(mods), EventHotKeyID(signature: OSType(0x726b_736c), id: id), GetApplicationEventTarget(), 0, &ref)
        guard err == noErr else { print("hotkey: \(key)/\(mods) is taken (\(err))"); return false }
        actions[id] = action
        refs.append(ref)
        return true
    }
}
