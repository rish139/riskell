import Foundation

/// Every path the installer touches, derived from one home directory so tests can use a scratch HOME.
struct Paths {
    let home: URL

    init(home: String) {
        self.home = URL(fileURLWithPath: home)
    }

    static func fromEnvironment() -> Paths {
        Paths(home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    }

    func configDir() -> URL { home.appendingPathComponent(".config/riskell") }
    func config() -> URL { configDir().appendingPathComponent("config.json") }
    func layout() -> URL { configDir().appendingPathComponent("layout.json") }
    func gestureBackup() -> URL { configDir().appendingPathComponent("gesture-backup.json") }
    func log() -> URL { home.appendingPathComponent(".cache/riskell/riskell.log") }
    func socket() -> URL { home.appendingPathComponent(".cache/riskell/ev.sock") }
    func agentPlist(_ label: String) -> URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    func localBin() -> URL { home.appendingPathComponent(".local/bin") }
}

/// The config.json merge: the installer owns a few keys and sets or removes them; every other key is left as it was.
enum ConfigIO {
    static let ownedKeys = ["wm", "theme", "location", "usage", "gestures", "scale"]

    /// nil = the file is missing. A file that is not a JSON object is an error.
    static func readObject(_ url: URL) -> Result<[String: Any]?, Error> {
        guard let data = try? Data(contentsOf: url) else { return .success(nil) }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) { return .success([:]) }
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(SetupError("\(url.lastPathComponent) is not a JSON object"))
            }
            return .success(obj)
        } catch {
            return .failure(SetupError("\(url.lastPathComponent) is not valid JSON"))
        }
    }

    /// Sets each owned key to its value, or removes it for nil. Every other key of `existing` keeps its place.
    static func merge(_ existing: [String: Any]?, owned: [(String, Any?)]) -> [String: Any] {
        var out = existing ?? [:]
        for (key, value) in owned {
            if let v = value { out[key] = v } else { out.removeValue(forKey: key) }
        }
        return out
    }

    /// Pretty, sorted, newline-terminated: the way riskell's own files look.
    static func pretty(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// Copies an existing file to `<name>.bak-<timestamp>` (with a counter if that name is taken). Nil when there was no file.
    static func backup(_ url: URL) throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let base = url.path + ".bak-" + timestamp()
        var target = URL(fileURLWithPath: base)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = URL(fileURLWithPath: "\(base)-\(n)")
            n += 1
        }
        try fm.copyItem(at: url, to: target)
        return target
    }

    /// Writes through a temporary file and a rename, so no reader sees half a file.
    static func writeAtomic(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = URL(fileURLWithPath: url.path + ".tmp-\(getpid())")
        try text.write(to: tmp, atomically: false, encoding: .utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

struct SetupError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
