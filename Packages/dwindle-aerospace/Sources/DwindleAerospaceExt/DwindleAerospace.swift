// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// Dwindle tiling for AeroSpace: the workspace's tiling tree stays binary, a new window splits the focused one in half, and the
/// split directions alternate, as Hyprland's dwindle layout does. AeroSpace keeps doing the layout; this only sends it the joins it
/// would not make by itself, and the tidy that puts a workspace back into one chain.
///
/// It has nothing to do between events: riskell calls `commands(for:in:)` on its window-manager queue, which returns the commands
/// for the request it is about to send, so the windows are laid out once and nothing wakes up on its own.
public final class DwindleAerospace: Behaviour, ManagerHook {
    public static let id = "dwindle-aerospace"
    /// Only AeroSpace places a new window right after the most recently used one, and leaves a join to its own script.
    public static let manager: String? = "aerospace"

    /// The keys that do nothing without this behaviour (the move keys and the tidy key, bound to `true` for it to act on) are in this mode of
    /// AeroSpace; `main` keeps the plain keys, so the manager is usable whenever riskell is not running.
    public var bindingMode: String? { "riskell" }

    public var events: Set<String> {
        [ManagerEvent.windowDetected, ManagerEvent.windowArrived, ManagerEvent.bindingTriggered]
    }

    /// The binding that tidies the workspace, read once when the behaviour starts. A text setting is not in the settings card, so it is set
    /// in the package's settings file.
    private static let defaultTidyKey = "alt-shift-t"

    /// The bindings that move the focused window, by the direction each one means. None is set by default: a direction that is not named has
    /// no key, so AeroSpace's own `move` keeps working until the owner chooses to bind these.
    private static let moveSettings: [(key: String, direction: Direction)] = [
        ("moveLeftKey", .left), ("moveRightKey", .right), ("moveUpKey", .up), ("moveDownKey", .down)
    ]

    /// The bindings that focus left and right, which riskell takes over at the edge of a workspace: where something is still beside the focused
    /// window, AeroSpace's own `focus` (the same binding) does the move. None is set by default.
    private static let focusSettings: [(key: String, direction: Direction)] = [("focusLeftKey", .left), ("focusRightKey", .right)]

    /// What the behaviour reads. Built whole in `start`, before riskell registers it as a hook, and never changed after: the queue that
    /// calls `commands(for:in:)` only reads it, and a settings change stops the behaviour (so riskell's queue stops calling it) before it
    /// starts again with a new one.
    private struct Settings {
        let tidyKey: String
        /// Each move binding as AeroSpace writes it, with the direction it moves in.
        let moveKeys: [String: Direction]
        /// Each focus binding as AeroSpace writes it, with the direction it focuses in.
        let focusKeys: [String: Direction]
    }

    private var settings: Settings?

    /// The windows this behaviour has sent to another workspace and that have not been seen arriving yet: their arrival is its own doing, so
    /// they are not placed like a new window. Read and written only from the queue that calls `commands(for:in:)`.
    private var hops: Set<Int> = []

    public init() {}

    public func start(_ env: Env) -> (() -> Void)? {
        var moves: [String: Direction] = [:]
        for (key, direction) in DwindleAerospace.moveSettings {
            let binding = env.prefs.string(key, default: "")
            if !binding.isEmpty { moves[binding] = direction }
        }
        var focuses: [String: Direction] = [:]
        for (key, direction) in DwindleAerospace.focusSettings {
            let binding = env.prefs.string(key, default: "")
            if !binding.isEmpty { focuses[binding] = direction }
        }
        settings = Settings(tidyKey: env.prefs.string("tidyKey", default: DwindleAerospace.defaultTidyKey), moveKeys: moves, focusKeys: focuses)
        return nil
    }

    /// Of the key bindings, only the tidy key, the move keys and the focus keys are this behaviour's: the rest cost nothing for it, not even
    /// the state riskell builds for an event.
    public func wants(_ event: ManagerEvent) -> Bool {
        guard let settings else { return false }
        guard event.name == ManagerEvent.bindingTriggered else { return true }
        guard let binding = event.fields["binding"] else { return false }
        return binding == settings.tidyKey || settings.moveKeys[binding] != nil || settings.focusKeys[binding] != nil
    }

    /// Only a move key or a focus key needs to know where the windows are, and the frames cost a window-server call, so no other binding asks
    /// for them.
    public func needsFrames(for event: ManagerEvent) -> Bool {
        guard let settings, event.name == ManagerEvent.bindingTriggered, let binding = event.fields["binding"] else { return false }
        return settings.moveKeys[binding] != nil || settings.focusKeys[binding] != nil
    }

    public func commands(for event: ManagerEvent, in state: ManagerState) -> [ManagerCommand] {
        guard let settings else { return [] }
        switch event.name {
            case ManagerEvent.windowDetected, ManagerEvent.windowArrived:
                guard let window = event.windowId else { return [] }
                if event.name == ManagerEvent.windowArrived, hops.remove(window) != nil { return [] }
                return DwindleRules.split(window: window, on: event.workspace, in: state)
            case ManagerEvent.bindingTriggered:
                guard let binding = event.fields["binding"] else { return [] }
                // a hop that was sent and never seen arriving (there was no workspace that way) must not swallow a later arrival
                hops.removeAll()
                if let direction = settings.moveKeys[binding] {
                    let move = DwindleRules.move(direction, in: state)
                    if let window = move.hop { hops.insert(window) }
                    return move.commands
                }
                if let direction = settings.focusKeys[binding] { return DwindleRules.focus(direction, in: state) }
                return binding == settings.tidyKey ? DwindleRules.tidy(in: state) : []
            default:
                return []
        }
    }
}
