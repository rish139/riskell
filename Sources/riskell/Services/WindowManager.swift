import Foundation
import RiskellKit

/// What the bars need from a window manager: its workspaces and windows land in the Store, and these few actions go back to it.
/// Workspaces are numbers (OmniWM's workspace number); windows are CGWindowIDs.
protocol WindowManager: AnyObject {
    var name: String { get }
    func start()
    func stop()
    /// Something outside the WM's own feed suggests the state changed (a system Space change); a WM that pushes its state may ignore it.
    func requestRefresh()
    func focus(space: Int)
    func focus(window id: Int)
    func close(window id: Int)
    func move(window id: Int, toSpace space: Int)
    /// Into the workspace after the last one the rail shows.
    func moveToNewSpace(window id: Int, after count: Int)
    /// Where each window sits (for the overview); a WM that cannot say returns nothing and the overview lays windows out itself.
    func windowFrames() -> [Int: WinFrame]
    /// true when riskell's own 3-finger swipe switches the workspace (the WM's gesture is off), so the rail needs no prediction.
    var ownsSwipe: Bool { get }
    /// Make room for the bars that are on (the manager's outer gaps); a manager that cannot is left alone and windows may sit under the bars.
    func reserve(_ config: Config)
    /// The manager's own gestures that would act on riskell's 3-finger touches, as labels for the Compat pills (empty: none, or it cannot say).
    var gestureConflicts: [String] { get }
}

extension WindowManager {
    func windowFrames() -> [Int: WinFrame] { [:] }
    var ownsSwipe: Bool { false }
    func reserve(_ config: Config) {}
    var gestureConflicts: [String] { [] }
}

enum WM {
    /// The window manager riskell talks to, created once at start (main.swift).
    static var shared: WindowManager?

    /// The backend named by `wm` in config.json: "omniwm", "yabai" or "aerospace" (both experimental), "command" (the user's own scripts, see docs/WM-COMMAND.md),
    /// "none", or "auto" (the default: OmniWM when it is installed, otherwise none).
    /// A name with no backend yet falls back to none, and says so in the log.
    static func make(store: Store) -> WindowManager {
        let choice = (AppConfig.shared.wm ?? "auto").lowercased()
        switch choice {
        case "omniwm": return Omni(store: store)
        case "yabai": return Yabai(store: store)      // experimental, unverified
        case "aerospace": return AeroSpace(store: store)      // experimental, unverified
        case "none": return NoWM(store: store)
        case "command": return CommandWM(store: store)      // idle (one log line) until wmCommand.state is set, which config reload picks up
        case "auto": return Compat.omniwmNow() != nil ? Omni(store: store) : NoWM(store: store)
        default:
            print("wm: no backend for \"\(choice)\" yet, running without a window manager"); fflush(stdout)
            return NoWM(store: store)
        }
    }
}
