// The window managers' wire formats, parsed without a window.
//
// Foundation only, on purpose: a payload recorded from a real install is replayed in a test on CI, where no window manager is running.
// Nothing in this target starts a process, opens a socket or reads a screen. Each backend has one entry (`Omni.parse(line:)`,
// `Yabai.parse(displays:spaces:windows:)`, `AeroSpace.parse(workspaces:windows:focusedWindow:focusedWorkspace:visibleWorkspaces:)`,
// `Gaps.rewrite(text:want:)`) that takes the bytes and returns the values; the backends in the app run the processes and keep the state.

import CoreGraphics   // CGRect, for a window's frame; a system framework, not AppKit
import Foundation

/// A workspace as the rail draws it. The backends all produce these, so the app reads one shape whichever manager it talks to.
public struct SpaceInfo: Identifiable, Equatable {
    public let id: Int              // workspace number (OmniWM workspace number)
    public var sid: UInt64          // SkyLight space id (what the system reports as the active space)
    public var focused: Bool
    public var visible: Bool
    public var windows: Int
    public var fullscreen: Bool

    public init(id: Int, sid: UInt64 = 0, focused: Bool, visible: Bool, windows: Int, fullscreen: Bool) {
        self.id = id; self.sid = sid; self.focused = focused; self.visible = visible; self.windows = windows; self.fullscreen = fullscreen
    }
}

/// One window on the bar's display (the workspaces atom and its card).
public struct WinInfo: Equatable, Identifiable {
    public let id: Int
    public var pid: Int
    public var app: String
    public var title: String
    public var space: Int
    public var focused: Bool

    public init(id: Int, pid: Int, app: String, title: String, space: Int, focused: Bool) {
        self.id = id; self.pid = pid; self.app = app; self.title = title; self.space = space; self.focused = focused
    }
}

/// Where a window sits on its workspace, in screen points from the top-left. `placed` is false when the WM only knows its size (OmniWM
/// parks an inactive workspace's windows off screen); the overview then lays it out itself.
/// `rank` is 0 for the most recently focused window.
public struct WinFrame: Equatable {
    public var rect: CGRect
    public var placed: Bool
    public var floating: Bool
    public var rank: Int

    public init(rect: CGRect, placed: Bool, floating: Bool, rank: Int = 99) {
        self.rect = rect; self.placed = placed; self.floating = floating; self.rank = rank
    }
}
