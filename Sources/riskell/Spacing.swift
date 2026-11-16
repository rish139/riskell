import Foundation
import RiskellKit

/// Spacing and size (config.json `spacing`). Each value is optional: absent is the default, and a value outside its range is clamped.
/// The `G` constants edgeGap, radius, r and cardRadius read these (design units), and the window gap feeds Layout.swift's gaps.
struct Spacing: Codable, Equatable {
    /// Bar to screen edge, design units. Default 8, range 4...24.
    var edgeGap: Double?
    /// Room between a bar and the tiled windows, design units. Default 6, range 0...24.
    var windowGap: Double?
    /// Corner roundness, design units. Default 11, range 6...18.
    var radius: Double?

    static let edgeDefault = 8.0, windowDefault = 6.0, radiusDefault = 11.0
    static let edgeRange = 4.0...24.0, windowRange = 0.0...24.0, radiusRange = 6.0...18.0

    var edge: CGFloat { CGFloat(min(Self.edgeRange.upperBound, max(Self.edgeRange.lowerBound, edgeGap ?? Self.edgeDefault))) }
    var window: CGFloat { CGFloat(min(Self.windowRange.upperBound, max(Self.windowRange.lowerBound, windowGap ?? Self.windowDefault))) }
    var corner: CGFloat { CGFloat(min(Self.radiusRange.upperBound, max(Self.radiusRange.lowerBound, radius ?? Self.radiusDefault))) }

    /// The values in force: the file's `spacing`, or the defaults.
    static var current: Spacing { AppConfig.shared.spacing ?? Spacing() }
}

extension AppConfig {
    /// Saves `spacing` in config.json (the other keys kept). Like setTheme: a file that cannot be read is never overwritten.
    static func setSpacing(_ s: Spacing) {
        shared.spacing = s
        let value = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s))
        patch("spacing", value)
        // live: the views rebuild (the same epoch as a theme change) and the windows are re-fitted and their gaps re-sent. The watcher then sees
        // nothing new in the file (shared already holds it).
        ThemeState.shared.epoch += 1
        Config.shared.onGeometry?()
    }

    /// Saves `scale` in config.json; nil removes the key (automatic scale). Scale.factor is read at launch, so the change applies on restart.
    static func setScale(_ v: Double?) {
        shared.scale = v
        patch("scale", v as Any?)
    }

    /// Read-modify-write of one key of config.json. A nil value removes the key.
    private static func patch(_ key: String, _ value: Any?) {
        var obj: [String: Any] = [:]
        if let d = try? Data(contentsOf: url) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            obj = o
        }
        obj[key] = value
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
    }
}
