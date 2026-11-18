import Foundation

/// The payloads the parsers are tested on, read from `fixtures/` next to this file. `#filePath` keeps them out of the package's resources,
/// so a fixture is exactly the file a maintainer records (Tests/wm/README.md says how) and `swift build` needs nothing extra.
enum Fixtures {
    enum Error: Swift.Error { case unexpected(String) }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures", isDirectory: true)

    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }

    static func text(_ name: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) }
}
