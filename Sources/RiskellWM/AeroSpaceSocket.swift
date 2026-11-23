import Foundation

/// AeroSpace's socket protocol, as bytes and values (nothing here opens a socket). Both sides first send their protocol version as a
/// 4-byte little-endian integer; after that every message either way is a frame: a 4-byte little-endian length, then UTF-8 JSON.
/// A request is answered by one frame; `subscribe` is answered by a stream of event frames until the connection closes.
extension AeroSpace {
    public static let protocolVersion: UInt32 = 1

    /// The events riskell subscribes to. `binding-triggered` comes before the binding's commands run, so a keypress can be answered
    /// without asking AeroSpace whether anything changed.
    public static let subscribedEvents = ["focus-changed", "focused-workspace-changed", "window-detected", "focused-monitor-changed",
                                          "binding-triggered"]

    /// The format string of the window query: exactly the fields riskell reads.
    public static let windowFormat = "%{window-id}%{window-title}%{app-name}%{app-pid}%{app-bundle-id}%{workspace}"
        + "%{workspace-is-focused}%{workspace-is-visible}%{window-layout}%{window-parent-container-layout}%{window-is-fullscreen}%{monitor-id}"
    /// The workspace query also prints the monitor, which says which workspaces hide each other when the focus moves, and the layout of
    /// the workspace's top container, which a hook that reshapes the tree reads.
    public static let workspaceFormat = "%{workspace}%{workspace-is-focused}%{workspace-is-visible}%{monitor-id}"
        + "%{workspace-root-container-layout}"

    public static let windowQuery = ["list-windows", "--all", "--json", "--format", windowFormat]
    public static let workspaceQuery = ["list-workspaces", "--all", "--json", "--format", workspaceFormat]
    public static let focusedWindowQuery = ["list-windows", "--focused", "--json", "--format", "%{window-id}"]
    /// Every mode's bindings: notation to the commands it runs, as one JSON object.
    public static let bindingTableQuery = ["config", "--get", "mode", "--json"]
    public static let subscribeArgs = ["subscribe"] + subscribedEvents

    public static func socketPath(user: String) -> String { "/tmp/bobko.aerospace-\(user).sock" }

    // MARK: framing
    /// The 4 bytes each side sends first.
    public static var handshake: Data { le32(protocolVersion) }

    /// True when the peer's 4 bytes are a protocol version riskell speaks.
    public static func accepts(handshake d: Data) -> Bool { d.count == 4 && readLE32(d, at: d.startIndex) == protocolVersion }

    /// One message: length prefix and payload.
    public static func frame(_ payload: Data) -> Data { le32(UInt32(payload.count)) + payload }

    /// A request frame. `stdin` is empty and no workspace is named: riskell passes ids as arguments. `window` is the request's target
    /// window, which AeroSpace gives to commands that take no `--window-id` (its `test` reads it).
    public static func request(_ args: [String], window: Int? = nil) -> Data {
        let obj: [String: Any] = ["args": args, "stdin": "", "windowId": window.map { $0 as Any } ?? NSNull(), "workspace": NSNull()]
        let json = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return frame(json)
    }

    /// Splits a byte stream into frames. Feed it whatever the socket delivered; it keeps a partial frame for the next call.
    public struct FrameReader {
        /// Larger than any answer riskell asks for; a length beyond it means the stream is not in step and `broken` is set.
        public static let limit = 64 * 1024 * 1024
        private var buffer = Data()
        public private(set) var broken = false
        public init() {}

        public mutating func feed(_ bytes: Data) -> [Data] {
            guard !broken else { return [] }
            buffer.append(bytes)
            var out: [Data] = []
            while buffer.count >= 4 {
                let n = Int(AeroSpace.readLE32(buffer, at: buffer.startIndex))
                if n > FrameReader.limit { broken = true; buffer.removeAll(); break }
                guard buffer.count >= 4 + n else { break }
                let s = buffer.startIndex + 4
                out.append(Data(buffer[s..<s + n]))
                buffer.removeSubrange(buffer.startIndex..<s + n)
            }
            return out
        }
    }

    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]) }
    public static func readLE32(_ d: Data, at i: Data.Index) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    // MARK: answers
    public struct Answer: Decodable, Equatable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public init(exitCode: Int32, stdout: String, stderr: String) { self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr }
    }

    /// The answer to one request. nil when the frame is not an answer (an event frame, or malformed).
    public static func parse(answer frame: Data) -> Answer? { try? JSONDecoder().decode(Answer.self, from: frame) }

    // MARK: events
    public enum Event: Equatable {
        case focusChanged(windowId: Int?, workspace: String?)
        case focusedWorkspaceChanged(workspace: String?, previous: String?)
        case windowDetected(windowId: Int?, workspace: String?, bundleId: String?, appName: String?)
        case focusedMonitorChanged
        /// A keybinding fired: AeroSpace reports it before it runs the binding's commands.
        case bindingTriggered(mode: String?, binding: String?)
        /// An event riskell does not use (`mode-changed`, ...), by name.
        case other(String)
    }

    /// One frame of the subscription. nil when it carries no `_event` (the reply that opens the stream, a malformed frame).
    public static func parse(event frame: Data) -> Event? {
        guard let o = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any], let name = o["_event"] as? String else { return nil }
        func int(_ k: String) -> Int? { (o[k] as? NSNumber)?.intValue }
        func str(_ k: String) -> String? { o[k] as? String }
        switch name {
        case "focus-changed": return .focusChanged(windowId: int("windowId"), workspace: str("workspace"))
        case "focused-workspace-changed": return .focusedWorkspaceChanged(workspace: str("workspace"), previous: str("prevWorkspace"))
        case "window-detected": return .windowDetected(windowId: int("windowId"), workspace: str("workspace"), bundleId: str("appBundleId"), appName: str("appName"))
        case "focused-monitor-changed": return .focusedMonitorChanged
        case "binding-triggered": return .bindingTriggered(mode: str("mode"), binding: str("binding"))
        default: return .other(name)
        }
    }

    /// One event frame as a hook is handed it: its name and its fields, the values as text under AeroSpace's own names. Every field the
    /// frame carries is kept, so a hook reads what AeroSpace said and not only what the bar uses.
    public struct EventFields: Equatable {
        public let name: String
        public let fields: [String: String]
        public init(name: String, fields: [String: String]) { self.name = name; self.fields = fields }
    }

    /// One event frame's name and fields. nil when it carries no `_event` (the reply that opens the stream, a malformed frame).
    public static func parse(eventFields frame: Data) -> EventFields? {
        guard let o = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any], let name = o["_event"] as? String else { return nil }
        var fields: [String: String] = [:]
        for (k, v) in o where k != "_event" {
            switch v {
                case let s as String: fields[k] = s
                case let n as NSNumber: fields[k] = n.stringValue
                default: break
            }
        }
        return EventFields(name: name, fields: fields)
    }

    // MARK: eval
    /// One argument as AeroSpace's shell lexer reads it back (Sources/AppBundle/shell/shellLexer.swift there): bare while it holds
    /// nothing the lexer reserves, inside quotes otherwise. Quotes are literal inside quotes, so a word holding both kinds cannot be
    /// written back at all; riskell passes only fixed arguments and numbers.
    public static func quoted(_ arg: String) -> String {
        // the characters the lexer reserves, plus `;`, which ends a command there
        let reserved: Set<Character> = ["(", ")", "$", "~", "&", "?", "*", "!", "\\", "|", "<", ">", "`", "'", "\"", "#", "\n", ";"]
        let bare = !arg.isEmpty && !arg.contains { $0.isWhitespace || reserved.contains($0) }
        return bare ? arg : (arg.contains("'") && !arg.contains("\"") ? "\"\(arg)\"" : "'\(arg)'")
    }

    /// The arguments of one `eval`: AeroSpace runs the `;`-separated commands in order and answers with their stdout joined, so a
    /// command and the queries that read back what it did cost one request instead of one each. `scripts` are commands already in
    /// AeroSpace's language (a hook's own script lines), placed after the plain `commands`. AeroSpace's `;` keeps the exit code of the
    /// last command, so a script that fails on purpose costs neither the ones after it nor the queries at the end.
    public static func evalArgs(_ commands: [[String]], scripts: [String] = [], queries: [[String]] = []) -> [String] {
        let parts = commands.map { $0.map(quoted).joined(separator: " ") } + scripts + queries.map { $0.map(quoted).joined(separator: " ") }
        return ["eval", parts.joined(separator: "; ")]
    }

    /// The top-level JSON values in a stdout, in order: one `eval` can carry several queries, and their answers follow one another with
    /// nothing between them (not even a newline that could be relied on). Brackets inside a string, escapes and all, are skipped; text
    /// that is not a value (a command's own plain output, say) is skipped up to the next `[` or `{`. A value still open at the end is
    /// dropped, and nothing after it is read: the stream was cut, not answered.
    public static func jsonValues(_ stdout: String) -> [String] {
        let chars = Array(stdout)
        var values: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "[" || chars[i] == "{" else { i += 1; continue }
            var depth = 0, inString = false, escaped = false, j = i
            while j < chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "[" || c == "{" {
                    depth += 1
                } else if c == "]" || c == "}" {
                    depth -= 1
                    if depth == 0 { values.append(String(chars[i...j])); i = j; break }
                }
                j += 1
            }
            if j == chars.count { return values }
            i += 1
        }
        return values
    }

    // MARK: rows
    /// One row of `list-windows` as `windowFormat` prints it.
    public struct WindowRow: Decodable, Equatable {
        public let windowId: Int; public let title: String?; public let app: String?; public let pid: Int?; public let bundleId: String?
        public let workspace: String; public let layout: String?; public let parentLayout: String?; public let fullscreen: Bool?; public let monitor: Int?
        /// The flags its workspace had when the query ran. A local update edits these to follow their workspace.
        public var workspaceFocused: Bool?; public var workspaceVisible: Bool?
        enum CodingKeys: String, CodingKey {
            case windowId = "window-id", title = "window-title", app = "app-name", pid = "app-pid", bundleId = "app-bundle-id", workspace
            case workspaceFocused = "workspace-is-focused", workspaceVisible = "workspace-is-visible"
            case layout = "window-layout", parentLayout = "window-parent-container-layout", fullscreen = "window-is-fullscreen", monitor = "monitor-id"
        }
        public init(windowId: Int, workspace: String, title: String? = nil, app: String? = nil, pid: Int? = nil, bundleId: String? = nil,
                    workspaceFocused: Bool? = nil, workspaceVisible: Bool? = nil, layout: String? = nil, parentLayout: String? = nil,
                    fullscreen: Bool? = nil, monitor: Int? = nil) {
            self.windowId = windowId; self.workspace = workspace; self.title = title; self.app = app; self.pid = pid; self.bundleId = bundleId
            self.workspaceFocused = workspaceFocused; self.workspaceVisible = workspaceVisible
            self.layout = layout; self.parentLayout = parentLayout; self.fullscreen = fullscreen; self.monitor = monitor
        }
        /// A monitor AeroSpace cannot name is printed as the string `"NULL-MONITOR-ID"` (a display just went away), so it reads as none
        /// rather than failing the whole answer.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            windowId = try c.decode(Int.self, forKey: .windowId)
            workspace = try c.decode(String.self, forKey: .workspace)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            app = try c.decodeIfPresent(String.self, forKey: .app)
            pid = try c.decodeIfPresent(Int.self, forKey: .pid)
            bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
            workspaceFocused = try c.decodeIfPresent(Bool.self, forKey: .workspaceFocused)
            workspaceVisible = try c.decodeIfPresent(Bool.self, forKey: .workspaceVisible)
            layout = try c.decodeIfPresent(String.self, forKey: .layout)
            parentLayout = try c.decodeIfPresent(String.self, forKey: .parentLayout)
            fullscreen = try c.decodeIfPresent(Bool.self, forKey: .fullscreen)
            monitor = (try? c.decodeIfPresent(Int.self, forKey: .monitor)) ?? nil
        }
        /// The layout strings of a container that holds its windows in the tiling tree.
        public static let tilingLayouts: Set<String> = ["h_tiles", "v_tiles", "h_accordion", "v_accordion"]
        /// In the tiling tree: its parent container is a tiling or accordion one. A minimised window, a native-fullscreen one, a window of
        /// a hidden app and a popup are not, whatever their own layout string says.
        public var tiling: Bool { (parentLayout ?? layout).map(WindowRow.tilingLayouts.contains) ?? false }
        /// Outside the tiling tree as the bar draws it: a window the manager floats (a dialog among them).
        public var floating: Bool { parentLayout == "floating" || layout == "floating" }
    }

    /// One row of `list-workspaces` as `workspaceFormat` prints it.
    public struct WorkspaceRow: Decodable, Equatable {
        public let workspace: String; public var focused: Bool?; public var visible: Bool?; public let monitor: Int?
        /// The layout of its top container: `h_tiles`, `v_tiles`, `h_accordion` or `v_accordion`.
        public let rootLayout: String?
        enum CodingKeys: String, CodingKey {
            case workspace, focused = "workspace-is-focused", visible = "workspace-is-visible", monitor = "monitor-id"
            case rootLayout = "workspace-root-container-layout"
        }
        public init(workspace: String, focused: Bool? = nil, visible: Bool? = nil, monitor: Int? = nil, rootLayout: String? = nil) {
            self.workspace = workspace; self.focused = focused; self.visible = visible; self.monitor = monitor; self.rootLayout = rootLayout
        }
        /// As a window row: a monitor AeroSpace cannot name prints as `"NULL-MONITOR-ID"` and reads as none.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workspace = try c.decode(String.self, forKey: .workspace)
            focused = try c.decodeIfPresent(Bool.self, forKey: .focused)
            visible = try c.decodeIfPresent(Bool.self, forKey: .visible)
            rootLayout = try c.decodeIfPresent(String.self, forKey: .rootLayout)
            monitor = (try? c.decodeIfPresent(Int.self, forKey: .monitor)) ?? nil
        }
    }

    /// The rows a refresh is published from: the two queries' answers, exactly as AeroSpace printed them. Everything the bar shows is a
    /// parse of these, so an event that already says what changed edits the rows and is parsed again instead of asking AeroSpace.
    public struct Rows: Equatable {
        public var workspaces: [WorkspaceRow]
        public var windows: [WindowRow]
        public init(workspaces: [WorkspaceRow], windows: [WindowRow]) { self.workspaces = workspaces; self.windows = windows }
    }

    /// One refresh: its rows, and on the first one after connecting the focused window and the binding table.
    public struct Refresh: Equatable {
        public var rows: Rows
        public var focusedWindow: Int?
        public var bindings: Bindings?
        public init(rows: Rows, focusedWindow: Int? = nil, bindings: Bindings? = nil) {
            self.rows = rows; self.focusedWindow = focusedWindow; self.bindings = bindings
        }
    }

    /// What the overview needs of a window besides `WinInfo`: its place in the list of its workspace and whether it floats.
    public struct Item: Equatable {
        public let id: Int; public let space: Int; public let floating: Bool
        public init(id: Int, space: Int, floating: Bool) { self.id = id; self.space = space; self.floating = floating }
    }

    /// One refresh decoded from the two queries. The focused window is not in it: the queries do not say, the event stream does.
    public struct State: Equatable {
        public var spaces: [SpaceInfo]
        public var windows: [WinInfo]
        public var items: [Item]
    }

    /// The bar's state, parsed from rows: a query's answer, or those rows after a local update edited them. The focused window is not
    /// in it: the queries never say which one has focus, the event stream does.
    public static func parse(rows: Rows) -> State {
        let ws = rows.workspaces, wins = rows.windows
        var count: [String: Int] = [:]
        for w in wins { count[w.workspace, default: 0] += 1 }
        let used = railUsed(windowSpaces: wins.compactMap { Int($0.workspace) },
                              focused: ws.first { $0.focused ?? false }.flatMap { Int($0.workspace) })
        // only numeric workspace names are rail entries (above five, only while in use); the number is the id
        let rail = ws.compactMap { r -> SpaceInfo? in
            guard let n = Int(r.workspace), n <= alwaysShown || used.contains(n) else { return nil }
            let focused = r.focused ?? false
            return SpaceInfo(id: n, focused: focused, visible: (r.visible ?? false) || focused, windows: count[r.workspace] ?? 0, fullscreen: false)
        }.sorted { $0.id < $1.id }
        var info: [WinInfo] = [], items: [Item] = []
        for w in wins {
            guard let space = Int(w.workspace) else { continue }
            info.append(WinInfo(id: w.windowId, pid: w.pid ?? 0, app: w.app ?? "", title: w.title ?? "", space: space, focused: false))
            items.append(Item(id: w.windowId, space: space, floating: w.floating))
        }
        return State(spaces: rail, windows: info, items: items)
    }

    /// Decodes the stdout of the two queries. nil when either is not the JSON AeroSpace prints: one failed query, not a half state.
    public static func parse(workspaceRows: String, windowRows: String) -> State? {
        guard let ws = decode([WorkspaceRow].self, workspaceRows), let wins = decode([WindowRow].self, windowRows) else { return nil }
        return parse(rows: Rows(workspaces: ws, windows: wins))
    }

    /// The rows of one refresh, from the stdout of its `eval`. The two queries' answers are the last two values, so a command before
    /// them (and, on the first refresh after connecting, the focused-window query and the binding table) can fail without taking them
    /// away. nil when the stdout does not hold both answers.
    public static func parse(refresh stdout: String, seed: Bool) -> Refresh? {
        let values = jsonValues(stdout)
        guard values.count >= 2,
              let ws = decode([WorkspaceRow].self, values[values.count - 2]),
              let wins = decode([WindowRow].self, values[values.count - 1]) else { return nil }
        let before = values.dropLast(2)
        // the seed's own asks come before the queries; a missing one only leaves that piece of the seed unanswered
        let focused = seed ? before.last.flatMap { parse(focusedWindow: $0) } : nil
        let bindings = seed ? before.dropLast().last.flatMap { parse(bindings: $0) } : nil
        return Refresh(rows: Rows(workspaces: ws, windows: wins), focusedWindow: focused, bindings: bindings)
    }

    /// The binding table as `config --get mode --json` prints it: mode, notation, the commands it runs.
    public static func parse(bindings stdout: String) -> Bindings? {
        struct Mode: Decodable { let binding: [String: String]? }
        return decode([String: Mode].self, stdout)?.mapValues { $0.binding ?? [:] }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// The window id in the stdout of `focusedWindowQuery` (an empty list, or nothing, when no window has focus).
    public static func parse(focusedWindow stdout: String) -> Int? {
        struct Row: Decodable { let id: Int; enum CodingKeys: String, CodingKey { case id = "window-id" } }
        return (try? JSONDecoder().decode([Row].self, from: Data(stdout.utf8)))?.first?.id
    }
}
