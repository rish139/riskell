import Foundation

/// The four numbers OmniWM's `[gaps.outer]` takes, in points: the room the bars take.
public enum Gaps {
    public struct Outer: Equatable {
        public var left: Double
        public var right: Double
        public var bottom: Double
        public var top: Double

        public init(left: Double, right: Double, bottom: Double, top: Double) {
            self.left = left; self.right = right; self.bottom = bottom; self.top = top
        }
    }

    /// `settings.toml` with the four `[gaps.outer]` keys set to `want`, formatted `%.1f`. nil when every one of them already holds that
    /// value, so the caller has nothing to write (and makes no backup). Only a value changes: a comment stays on its line, key order and
    /// every line's own ending are kept, a key that is not in the section is not added, and nothing outside `[gaps.outer]` is touched.
    public static func rewrite(text: String, want: Outer) -> String? {
        let values: [(String, Double)] = [("left", want.left), ("right", want.right), ("bottom", want.bottom), ("top", want.top)]
        // split on LF only, so a CRLF file keeps its CR on each line and gets it back on the lines that change
        var lines = text.components(separatedBy: "\n"), inOuter = false, changed = false
        for i in lines.indices {
            let ending = lines[i].hasSuffix("\r") ? "\r" : ""
            let body = ending.isEmpty ? lines[i] : String(lines[i].dropLast())
            let t = body.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inOuter = t == "[gaps.outer]"; continue }
            guard inOuter, let eq = t.firstIndex(of: "=") else { continue }
            let key = t[..<eq].trimmingCharacters(in: .whitespaces)
            guard let w = values.first(where: { $0.0 == key }) else { continue }
            let rest = t[t.index(after: eq)...]
            let hash = rest.firstIndex(of: "#")                  // a comment after the value stays on the line
            let current = String(rest[..<(hash ?? rest.endIndex)]).trimmingCharacters(in: .whitespaces)
            let value = String(format: "%.1f", w.1)
            if current != value {
                let comment = hash.map { " " + rest[$0...] } ?? ""
                lines[i] = "\(key) = \(value)\(comment)\(ending)"
                changed = true
            }
        }
        guard changed else { return nil }
        return lines.joined(separator: "\n")
    }
}
