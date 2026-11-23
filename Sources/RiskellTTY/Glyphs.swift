import Foundation

/// The marks the command line draws with: one set in Unicode, one in plain ASCII for a terminal that cannot show more.
///
/// Nothing here is a colour or a width: a glyph is one cell of text, and the kit decides when to use the plain set.
public struct Glyphs: Equatable {
    public var ok: String
    public var warn: String
    public var crit: String
    public var note: String
    public var arrow: String
    public var dot: String
    public var ring: String
    public var ruleChar: String
    public var gauge: String
    public var logoStrip: String
    public var islandTop: String
    public var islandBottom: String

    public init(ok: String, warn: String, crit: String, note: String, arrow: String, dot: String, ring: String,
                ruleChar: String, gauge: String, logoStrip: String, islandTop: String, islandBottom: String) {
        self.ok = ok
        self.warn = warn
        self.crit = crit
        self.note = note
        self.arrow = arrow
        self.dot = dot
        self.ring = ring
        self.ruleChar = ruleChar
        self.gauge = gauge
        self.logoStrip = logoStrip
        self.islandTop = islandTop
        self.islandBottom = islandBottom
    }

    /// ✓ ! ✗ · ↳ ● ○ ─ ━ ▐▌ ▄ ▀
    public static let unicode = Glyphs(ok: "✓", warn: "!", crit: "✗", note: "·", arrow: "↳", dot: "●", ring: "○",
                                       ruleChar: "─", gauge: "━", logoStrip: "▐▌", islandTop: "▄", islandBottom: "▀")

    /// + ! x . > * o - = || _ -
    public static let ascii = Glyphs(ok: "+", warn: "!", crit: "x", note: ".", arrow: ">", dot: "*", ring: "o",
                                     ruleChar: "-", gauge: "=", logoStrip: "||", islandTop: "_", islandBottom: "-")

    /// The plain set only when something asks for it: RISKELL_ASCII is set, the terminal is `dumb`, or a locale names something that is
    /// not UTF-8 (LC_ALL, else LC_CTYPE, else LANG). With no locale named at all there is no one to ask, so the set is Unicode, which is
    /// what macOS prints without one.
    public static func detect(env: [String: String] = ProcessInfo.processInfo.environment) -> Glyphs {
        if let forced = env["RISKELL_ASCII"], !forced.isEmpty { return .ascii }
        if (env["TERM"] ?? "").lowercased() == "dumb" { return .ascii }
        guard let locale = [env["LC_ALL"], env["LC_CTYPE"], env["LANG"]].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return .unicode
        }
        return locale.uppercased().contains("UTF-8") ? .unicode : .ascii
    }
}
