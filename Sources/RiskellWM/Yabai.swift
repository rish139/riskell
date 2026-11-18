import Foundation

/// yabai's wire format: three `yabai -m query` streams (displays, spaces, windows), each a JSON array with kebab-case keys.
public enum Yabai {
    // MARK: wire types (only the fields riskell reads)
    public struct Frame: Decodable, Equatable { public let x: Double; public let y: Double; public let w: Double; public let h: Double }

    public struct Display: Decodable, Equatable { public let index: Int; public let frame: Frame }

    public struct Space: Decodable, Equatable {
        public let index: Int; public let display: Int
        public let hasFocus: Bool; public let isVisible: Bool; public let isNativeFullscreen: Bool
        enum CodingKeys: String, CodingKey {
            case index, display, hasFocus = "has-focus", isVisible = "is-visible", isNativeFullscreen = "is-native-fullscreen"
        }
    }

    public struct Window: Decodable, Equatable {
        public let id: Int; public let pid: Int; public let app: String?; public let title: String?; public let space: Int
        public let display: Int; public let hasFocus: Bool; public let isMinimized: Bool; public let isFloating: Bool; public let frame: Frame
        enum CodingKeys: String, CodingKey {
            case id, pid, app, title, space, display, frame
            case hasFocus = "has-focus", isMinimized = "is-minimized", isFloating = "is-floating"
        }
    }

    /// One query round: the display the bars live on, the rail, the windows and their frames.
    public struct Snapshot: Equatable {
        public let display: Int
        public let spaces: [SpaceInfo]
        public let windows: [WinInfo]
        public let frames: [Int: WinFrame]
    }

    /// Decodes the three streams. nil when any of them is not the JSON yabai prints: one failed query, not a half state.
    public static func parse(displays: Data, spaces: Data, windows: Data) -> Snapshot? {
        let dec = JSONDecoder()
        guard let allDisplays = try? dec.decode([Display].self, from: displays),
              let allSpaces = try? dec.decode([Space].self, from: spaces),
              let allWins = try? dec.decode([Window].self, from: windows) else { return nil }
        // the bars live on the main display: the one whose origin is the global origin (yabai's own numbering may put another first)
        let main = allDisplays.first { $0.frame.x == 0 && $0.frame.y == 0 }?.index ?? 1
        let shownSpaces = allSpaces.filter { $0.display == main }.sorted { $0.index < $1.index }
        let wins = allWins.filter { $0.display == main && $0.space > 0 && !$0.isMinimized }
        var count: [Int: Int] = [:]
        for w in wins { count[w.space, default: 0] += 1 }
        let rail = shownSpaces.map {
            SpaceInfo(id: $0.index, sid: 0, focused: $0.hasFocus, visible: $0.isVisible, windows: count[$0.index] ?? 0,
                      fullscreen: $0.isNativeFullscreen)
        }
        let info = wins.map { WinInfo(id: $0.id, pid: $0.pid, app: $0.app ?? "", title: $0.title ?? "", space: $0.space, focused: $0.hasFocus) }
        var frames: [Int: WinFrame] = [:]
        for w in wins {
            frames[w.id] = WinFrame(rect: CGRect(x: w.frame.x, y: w.frame.y, width: w.frame.w, height: w.frame.h), placed: true,
                                    floating: w.isFloating, rank: w.hasFocus ? 0 : 99)
        }
        return Snapshot(display: main, spaces: rail, windows: info, frames: frames)
    }
}
