import Foundation

/// Puts the folder of the `risk` link on PATH, for the case where it is not there already. A clearly marked block is appended to the shell
/// start-up files after a backup: ~/.zshrc (macOS's login shell, created when missing), and ~/.bash_profile, ~/.bashrc and fish's
/// config.fish only when they exist, so no file is created for a shell the user does not use. `--uninstall` removes the block again.
enum ShellPath {
    static let begin = "# >>> riskell >>>"
    static let end = "# <<< riskell <<<"

    /// The start-up files the block goes into.
    static func files(_ paths: Paths) -> [URL] {
        let fm = FileManager.default
        var out = [paths.home.appendingPathComponent(".zshrc")]
        for name in [".bash_profile", ".bashrc", ".config/fish/config.fish"] where fm.fileExists(atPath: paths.home.appendingPathComponent(name).path) {
            out.append(paths.home.appendingPathComponent(name))
        }
        return out
    }

    private static func shown(_ dir: URL, _ paths: Paths) -> String {
        dir.path.hasPrefix(paths.home.path + "/") ? "$HOME" + dir.path.dropFirst(paths.home.path.count) : dir.path
    }

    static func block(for file: URL, dir: URL, paths: Paths) -> String {
        let line = file.lastPathComponent == "config.fish" ? "fish_add_path \(shown(dir, paths))" : "export PATH=\"\(shown(dir, paths)):$PATH\""
        return "\(begin)\n# added by the riskell installer so that `risk` works in a new terminal; remove this block to undo\n\(line)\n\(end)\n"
    }

    static func present(in file: URL) -> Bool {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains(begin)
    }

    /// Adds the block to each start-up file that does not have it. A file that existed is copied to `<name>.bak-riskell-<time>` first.
    /// Returns what was done, as lines for the log.
    @discardableResult
    static func add(dir: URL, paths: Paths) -> [String] {
        let fm = FileManager.default
        var lines: [String] = []
        let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date()) }()
        for file in files(paths) {
            if present(in: file) { lines.append("\(file.lastPathComponent): already has it"); continue }
            let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if fm.fileExists(atPath: file.path) { try? fm.copyItem(at: file, to: URL(fileURLWithPath: file.path + ".bak-riskell-" + stamp)) }
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = old + (old.isEmpty || old.hasSuffix("\n\n") ? "" : old.hasSuffix("\n") ? "\n" : "\n\n") + block(for: file, dir: dir, paths: paths)
            do { try text.write(to: file, atomically: true, encoding: .utf8); lines.append("added \(shown(dir, paths)) to PATH in ~/\(relative(file, paths))") }
            catch { lines.append("could not write ~/\(relative(file, paths))") }
        }
        return lines
    }

    /// Takes the block out of every start-up file that has it, with the blank line that was added before it.
    @discardableResult
    static func remove(paths: Paths) -> [String] {
        var lines: [String] = []
        let candidates = [".zshrc", ".bash_profile", ".bashrc", ".config/fish/config.fish"].map { paths.home.appendingPathComponent($0) }
        for file in candidates {
            guard let text = try? String(contentsOf: file, encoding: .utf8), let b = text.range(of: begin), let e = text.range(of: end) else { continue }
            var start = b.lowerBound
            var stop = e.upperBound
            if stop < text.endIndex, text[stop] == "\n" { stop = text.index(after: stop) }
            if start > text.startIndex, text[text.index(before: start)] == "\n", text.index(before: start) > text.startIndex, text[text.index(start, offsetBy: -2)] == "\n" { start = text.index(before: start) }
            var out = text
            out.removeSubrange(start..<stop)
            if (try? out.write(to: file, atomically: true, encoding: .utf8)) != nil { lines.append("removed the PATH block from ~/\(relative(file, paths))") }
        }
        return lines
    }

    private static func relative(_ file: URL, _ paths: Paths) -> String { String(file.path.dropFirst(paths.home.path.count + 1)) }
}
