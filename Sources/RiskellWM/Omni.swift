import Foundation

/// OmniWM's wire format: one JSON object per line over its IPC socket, protocol 22. The subscription pushes the whole state on every
/// change, so a line is either an event (with its payload), a failure, or something riskell does not read (a command reply, a malformed
/// line). Decoding a payload is not part of the state: the caller keeps the slices and derives the rail from them.
public enum Omni {
    /// Workspaces the rail always shows (five); later ones appear while they hold windows or focus.
    public static let alwaysShown = 5

    // MARK: wire types (only the fields riskell reads)
    public struct Display: Decodable, Equatable { public let isMain: Bool? }

    public struct Workspace: Decodable, Equatable {
        public let number: Int; public let isFocused: Bool?; public let display: Display?
    }

    public struct Window: Decodable, Equatable {
        public struct App: Decodable, Equatable { public let name: String? }
        public struct WS: Decodable, Equatable { public let number: Int? }
        public struct Frame: Decodable, Equatable {
            public let x: Double; public let y: Double; public let width: Double; public let height: Double
        }
        public let id: String; public let windowId: Int; public let pid: Int?; public let title: String?; public let app: App?
        public let workspace: WS?; public let isFocused: Bool?; public let isScratchpad: Bool?; public let display: Display?
        public let frame: Frame?; public let hiddenReason: String?; public let mode: String?; public let focusRank: Int?
    }

    /// The envelope every line carries. `result.kind` names the event; `ok: false` is the peer reporting an error.
    struct Head: Decodable {
        struct R: Decodable { let kind: String }
        let kind: String; let ok: Bool?; let status: String?; let result: R?
    }

    struct Event<P: Decodable>: Decodable { struct R: Decodable { let payload: P }; let result: R }

    // payload bodies
    struct Workspaces: Decodable { let workspaces: [Workspace] }
    struct Windows: Decodable { let windows: [Window] }
    struct Active: Decodable { struct W: Decodable { let number: Int? }; let workspace: W? }
    struct Focused: Decodable { let window: Window? }

    // MARK: one line
    /// The payload of an event, one case per kind riskell reads.
    public enum Payload: Equatable {
        case workspaces([Workspace])
        case windows([Window])
        case activeWorkspace(Int?)
        case focusedWindow(Int?)
    }

    /// What one line of the subscription says.
    public enum Message: Equatable {
        /// An event. `payload` is nil when the envelope named a kind riskell reads but its payload did not decode: the caller still
        /// needs the kind, because a focus or workspace event is what raises the floating windows back on top.
        case event(kind: String, payload: Payload?)
        /// `ok: false`: OmniWM refused or failed (`status` is its word for it).
        case failure(status: String?)
        /// Not a line riskell acts on: a reply to a command, a kind it does not read, or not JSON at all.
        case ignored
    }

    public static func parse(line: Data) -> Message {
        let dec = JSONDecoder()
        guard let head = try? dec.decode(Head.self, from: line) else { return .ignored }
        if head.ok == false { return .failure(status: head.status) }
        guard head.kind == "event", let kind = head.result?.kind else { return .ignored }
        switch kind {
        case "workspaces":
            guard let p = try? dec.decode(Event<Workspaces>.self, from: line) else { return .event(kind: kind, payload: nil) }
            return .event(kind: kind, payload: .workspaces(p.result.payload.workspaces))
        case "windows":
            guard let p = try? dec.decode(Event<Windows>.self, from: line) else { return .event(kind: kind, payload: nil) }
            return .event(kind: kind, payload: .windows(p.result.payload.windows))
        case "active-workspace":
            guard let p = try? dec.decode(Event<Active>.self, from: line) else { return .event(kind: kind, payload: nil) }
            return .event(kind: kind, payload: .activeWorkspace(p.result.payload.workspace?.number))
        case "focused-window":
            guard let p = try? dec.decode(Event<Focused>.self, from: line) else { return .event(kind: kind, payload: nil) }
            return .event(kind: kind, payload: .focusedWindow(p.result.payload.window?.windowId))
        default:
            return .ignored
        }
    }

    // MARK: the rules that turn a state into the rail
    /// A workspace that names no display counts as the main one (the field is optional in OmniWM's payload).
    public static func mainDisplayWorkspaces(_ all: [Workspace]) -> [Workspace] {
        all.filter { $0.display?.isMain ?? true }
    }

    /// The focus OmniWM's state implies: the active workspace, else the first focused one on the main display.
    public static func focus(_ all: [Workspace], active: Int?) -> Int? {
        let main = mainDisplayWorkspaces(all)
        return active ?? main.first { $0.isFocused == true }?.number
    }

    /// The windows riskell counts and draws: not a scratchpad, on the main display, and on a workspace it knows the number of.
    public static func shownWindows(_ all: [Window]) -> [Window] {
        all.filter { !($0.isScratchpad ?? false) && ($0.display?.isMain ?? true) && $0.workspace?.number != nil }
    }

    /// At least half of `r` is on a screen of `screen` points. OmniWM parks a hidden window past the edge of the screen, and that is not
    /// a place the overview can draw.
    public static func mostlyOnScreen(_ r: CGRect, screen: CGSize) -> Bool {
        let s = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        let i = s.intersection(r)
        return !i.isNull && i.width * i.height >= 0.5 * r.width * r.height
    }

    /// The rail: workspaces 1...N, N = the five that always existed, or more while a later one holds windows or focus.
    public static func rail(spaces all: [Workspace], windows: [Window], focus: Int?) -> [SpaceInfo] {
        var count: [Int: Int] = [:]
        for w in shownWindows(windows) { count[w.workspace?.number ?? 0, default: 0] += 1 }
        let shown = max(Omni.alwaysShown, count.keys.max() ?? 0, focus ?? 0)
        return mainDisplayWorkspaces(all).filter { $0.number <= shown }.sorted { $0.number < $1.number }.map {
            SpaceInfo(id: $0.number, sid: 0, focused: $0.number == focus, visible: $0.number == focus,
                      windows: count[$0.number] ?? 0, fullscreen: false)
        }
    }

    /// The windows behind the rail and the overview (already `shownWindows` filtered). A window is focused while OmniWM reports a focused
    /// window and it is that one; with no report at all the window's own flag is the answer.
    public static func windowInfos(_ all: [Window], focused: Int?) -> [WinInfo] {
        all.compactMap { w in
            guard let space = w.workspace?.number else { return nil }
            return WinInfo(id: w.windowId, pid: w.pid ?? 0, app: w.app?.name ?? "", title: w.title ?? "", space: space,
                           focused: focused.map { $0 == w.windowId } ?? (w.isFocused ?? false))
        }
    }
}
