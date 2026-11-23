import Foundation

/// AeroSpace's socket protocol, as bytes and values (nothing here opens a socket). Both sides first send their protocol version as a
/// 4-byte little-endian integer; after that every message either way is a frame: a 4-byte little-endian length, then UTF-8 JSON.
/// A request is answered by one frame; `subscribe` is answered by a stream of event frames until the connection closes.
extension AeroSpace {
    public static let protocolVersion: UInt32 = 1

    /// The events riskell subscribes to.
    public static let subscribedEvents = ["focus-changed", "focused-workspace-changed", "window-detected", "focused-monitor-changed"]

    /// The format string of the window query: exactly the fields riskell reads.
    public static let windowFormat = "%{window-id}%{window-title}%{app-name}%{app-pid}%{app-bundle-id}%{workspace}"
        + "%{workspace-is-focused}%{workspace-is-visible}%{window-layout}%{window-parent-container-layout}%{window-is-fullscreen}%{monitor-id}"
    public static let workspaceFormat = "%{workspace}%{workspace-is-focused}%{workspace-is-visible}"

    public static let windowQuery = ["list-windows", "--all", "--json", "--format", windowFormat]
    public static let workspaceQuery = ["list-workspaces", "--all", "--json", "--format", workspaceFormat]
    public static let focusedWindowQuery = ["list-windows", "--focused", "--json", "--format", "%{window-id}"]
    public static let subscribeArgs = ["subscribe"] + subscribedEvents

    public static func socketPath(user: String) -> String { "/tmp/bobko.aerospace-\(user).sock" }

    // MARK: framing
    /// The 4 bytes each side sends first.
    public static var handshake: Data { le32(protocolVersion) }

    /// True when the peer's 4 bytes are a protocol version riskell speaks.
    public static func accepts(handshake d: Data) -> Bool { d.count == 4 && readLE32(d, at: d.startIndex) == protocolVersion }

    /// One message: length prefix and payload.
    public static func frame(_ payload: Data) -> Data { le32(UInt32(payload.count)) + payload }

    /// A request frame. `stdin` is empty and no window or workspace is named: riskell passes ids as arguments.
    public static func request(_ args: [String]) -> Data {
        let obj: [String: Any] = ["args": args, "stdin": "", "windowId": NSNull(), "workspace": NSNull()]
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
        /// An event riskell does not use (`mode-changed`, `binding-triggered`, ...), by name.
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
        default: return .other(name)
        }
    }

    // MARK: queries
    /// One row of `list-windows` as `windowFormat` prints it.
    public struct WindowRow: Decodable, Equatable {
        public let windowId: Int; public let title: String?; public let app: String?; public let pid: Int?; public let bundleId: String?
        public let workspace: String; public let layout: String?; public let parentLayout: String?; public let fullscreen: Bool?; public let monitor: Int?
        enum CodingKeys: String, CodingKey {
            case windowId = "window-id", title = "window-title", app = "app-name", pid = "app-pid", bundleId = "app-bundle-id", workspace
            case layout = "window-layout", parentLayout = "window-parent-container-layout", fullscreen = "window-is-fullscreen", monitor = "monitor-id"
        }
        public var floating: Bool { parentLayout == "floating" || layout == "floating" }
    }

    /// One row of `list-workspaces` as `workspaceFormat` prints it.
    public struct WorkspaceRow: Decodable, Equatable {
        public let workspace: String; public let focused: Bool?; public let visible: Bool?
        enum CodingKeys: String, CodingKey { case workspace, focused = "workspace-is-focused", visible = "workspace-is-visible" }
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

    /// Decodes the stdout of the two queries. nil when either is not the JSON AeroSpace prints: one failed query, not a half state.
    public static func parse(workspaceRows: String, windowRows: String) -> State? {
        let dec = JSONDecoder()
        guard let ws = try? dec.decode([WorkspaceRow].self, from: Data(workspaceRows.utf8)),
              let wins = try? dec.decode([WindowRow].self, from: Data(windowRows.utf8)) else { return nil }
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

    /// The window id in the stdout of `focusedWindowQuery` (an empty list, or nothing, when no window has focus).
    public static func parse(focusedWindow stdout: String) -> Int? {
        struct Row: Decodable { let id: Int; enum CodingKeys: String, CodingKey { case id = "window-id" } }
        return (try? JSONDecoder().decode([Row].self, from: Data(stdout.utf8)))?.first?.id
    }
}
