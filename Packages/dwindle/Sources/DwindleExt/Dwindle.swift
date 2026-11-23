// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import RiskellKit

/// Dwindle tiling for AeroSpace: the workspace's tiling tree stays binary, a new window splits the focused one in half, and the
/// split directions alternate, as Hyprland's dwindle layout does. AeroSpace keeps doing the layout; this only sends it the joins it
/// would not make by itself, and the tidy that puts a workspace back into one chain.
///
/// It has nothing to do between events: riskell calls `commands(for:in:)` on its window-manager queue, which returns the commands
/// for the request it is about to send, so the windows are laid out once and nothing wakes up on its own.
public final class Dwindle: Behaviour, ManagerHook {
    public static let id = "dwindle"
    /// Only AeroSpace places a new window right after the most recently used one, and leaves a join to its own script.
    public static let manager: String? = "aerospace"

    public var events: Set<String> {
        [ManagerEvent.windowDetected, ManagerEvent.windowArrived, ManagerEvent.bindingTriggered]
    }

    /// The binding that tidies the workspace, read once when the behaviour starts. A text setting is not in the settings card, so it is set
    /// in the package's settings file.
    private static let defaultTidyKey = "alt-shift-t"

    /// What the behaviour reads. Built whole in `start`, before riskell registers it as a hook, and never changed after: the queue that
    /// calls `commands(for:in:)` only reads it, and a settings change stops the behaviour (so riskell's queue stops calling it) before it
    /// starts again with a new one.
    private struct Settings {
        let tidyKey: String
    }

    private var settings: Settings?

    public init() {}

    public func start(_ env: Env) -> (() -> Void)? {
        settings = Settings(tidyKey: env.prefs.string("tidyKey", default: Dwindle.defaultTidyKey))
        return nil
    }

    public func commands(for event: ManagerEvent, in state: ManagerState) -> [ManagerCommand] {
        guard let settings else { return [] }
        switch event.name {
            case ManagerEvent.windowDetected, ManagerEvent.windowArrived:
                guard let window = event.windowId else { return [] }
                return DwindleRules.split(window: window, on: event.workspace, in: state)
            case ManagerEvent.bindingTriggered:
                guard event.fields["binding"] == settings.tidyKey else { return [] }
                return DwindleRules.tidy(in: state)
            default:
                return []
        }
    }
}
