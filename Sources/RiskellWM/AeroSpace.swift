import Foundation

/// AeroSpace's wire format: `list-workspaces` / `list-windows` print JSON (kebab-case keys), while the focused and visible workspace
/// queries print plain text, one workspace name per line.
public enum AeroSpace {
    // MARK: wire types (only the fields riskell reads)
    public struct Workspace: Decodable, Equatable { public let workspace: String }

    public struct Window: Decodable, Equatable {
        public let windowId: Int; public let windowTitle: String?; public let appName: String?; public let appPid: Int?; public let workspace: String
        enum CodingKeys: String, CodingKey {
            case windowId = "window-id", windowTitle = "window-title", appName = "app-name", appPid = "app-pid", workspace
        }
    }

    /// One refresh: the rail and the windows riskell draws.
    public struct Snapshot: Equatable {
        public let spaces: [SpaceInfo]
        public let windows: [WinInfo]
    }

    /// Decodes one refresh. nil when the workspace or the window list is not the JSON AeroSpace prints: one failed query, not a half state.
    /// `focusedWindow` is the separate `list-windows --focused` call, which AeroSpace may answer with nothing at all when no window has
    /// focus; that leaves every window unfocused rather than failing the refresh.
    public static func parse(workspaces: Data, windows: Data, focusedWindow: Data?,
                             focusedWorkspace: [String], visibleWorkspaces: [String]) -> Snapshot? {
        let dec = JSONDecoder()
        guard let allWS = try? dec.decode([Workspace].self, from: workspaces),
              let allWins = try? dec.decode([Window].self, from: windows) else { return nil }
        let focusedWin = focusedWindow.flatMap { try? dec.decode([Window].self, from: $0) }?.first?.windowId
        let focusedName = focusedWorkspace.first
        let visible = Set(visibleWorkspaces)

        // workspaces: only numeric names are rail entries (riskell's rail shows numbers); the number is the id
        var count: [String: Int] = [:]
        for w in allWins { count[w.workspace, default: 0] += 1 }
        let numbered = allWS.compactMap { ws -> (name: String, n: Int)? in Int(ws.workspace).map { (ws.workspace, $0) } }
            .sorted { $0.n < $1.n }
        let rail = numbered.map {
            SpaceInfo(id: $0.n, sid: 0, focused: $0.name == focusedName, visible: visible.contains($0.name) || $0.name == focusedName,
                      windows: count[$0.name] ?? 0, fullscreen: false)
        }
        let info = allWins.compactMap { w -> WinInfo? in
            guard let space = Int(w.workspace) else { return nil }
            return WinInfo(id: w.windowId, pid: w.appPid ?? 0, app: w.appName ?? "", title: w.windowTitle ?? "", space: space,
                           focused: w.windowId == focusedWin)
        }
        return Snapshot(spaces: rail, windows: info)
    }

    /// The non-empty lines of a plain-text call (`list-workspaces --focused` prints names, not JSON). nil when the output is not UTF-8.
    public static func lines(_ text: Data) -> [String]? {
        guard let s = String(data: text, encoding: .utf8) else { return nil }
        return s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
