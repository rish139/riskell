import Foundation

/// Every request to AeroSpace makes it lay out the visible windows and refresh what every app holds, so the backend asks only when the
/// events do not already say what changed. An event that names a window or a workspace is applied to the rows of the last query and those
/// rows are parsed again, which is exactly what a query would have answered; anything else asks AeroSpace again.
extension AeroSpace {
    /// AeroSpace's bindings by mode, notation to the commands it runs, as `config --get mode --json` prints them.
    public typealias Bindings = [String: [String: String]]

    /// The commands that move the focus or switch a workspace. The focus-changed and focused-workspace-changed events that follow such a
    /// binding say what changed, so nothing has to be asked.
    public static let navigationCommands: Set<String> = ["focus", "workspace", "workspace-back-and-forth", "focus-monitor",
                                                         "focus-back-and-forth", "mode"]

    /// The commands that cannot move a window or a workspace: they change nothing the rows could be older than, so the events that follow
    /// their binding say whatever did change. `reload-config`, `trigger-binding` and `enable` are not here: they run something else that
    /// can move a window, so a binding of theirs still asks for the rows.
    public static let quietCommands: Set<String> = ["volume", "echo", "move-mouse", "test", "true", "false", "exec-and-forget"]

    /// What riskell learned. Only the first two carry enough to edit the rows; `activation` says an app came forward, which can mean
    /// nothing at all, and the rest has to be asked for.
    public enum Change: Equatable {
        case focus(windowId: Int?, workspace: String?)
        case focusedWorkspace(String?)
        /// A keybinding fired, before its commands run.
        case binding(mode: String?, binding: String?)
        /// An app was activated; the window server says whether anything went away.
        case activation
        /// A window appeared, the focused monitor changed, an app launched or quit, or nothing is known yet.
        case refresh
    }

    public enum Decision: Equatable {
        /// Publish these rows: the parse of them is what the bar shows.
        case apply(Rows)
        /// Ask AeroSpace again.
        case refresh
        /// Ask AeroSpace again, and apply nothing to these rows in the meantime: a binding riskell does not understand, or a
        /// non-navigation one, may have changed something the rows cannot say.
        case staleRefresh
        /// Read the binding table again, then ask for the rows: a binding fired that the table cannot explain.
        case readBindings
    }

    /// What to do with an event, given the rows of the last query and the binding table.
    public static func decide(_ change: Change, rows: Rows?, bindings: Bindings?, stale: Bool) -> Decision {
        switch change {
            case .refresh:
                return .refresh
            case .activation:
                // nothing to edit: an app coming forward is no change unless a window went away, which the caller checks
                guard let rows, !stale else { return .refresh }
                return .apply(rows)
            case .binding(let mode, let binding):
                guard let rows else { return .refresh }
                guard let mode, let binding, let table = bindings, let script = table[mode]?[binding] else { return .readBindings }
                return changesNothing(script) ? .apply(rows) : .staleRefresh
            case .focus(let windowId, let workspace):
                guard let rows, !stale, let name = workspace, rows.workspaces.contains(where: { $0.workspace == name }) else { return .refresh }
                // a window focused on another workspace than the event names means the rows are older than the event
                if let id = windowId, !rows.windows.contains(where: { $0.windowId == id && $0.workspace == name }) { return .refresh }
                return .apply(focusing(rows, on: name))
            case .focusedWorkspace(let workspace):
                guard let rows, !stale, let name = workspace, rows.workspaces.contains(where: { $0.workspace == name }) else { return .refresh }
                return .apply(focusing(rows, on: name))
        }
    }

    /// True when every command in a binding only moves the focus, switches a workspace, or changes neither (see `navigationCommands`
    /// and `quietCommands`). Nothing else has to be asked after such a binding.
    public static func changesNothing(_ script: String) -> Bool {
        guard let names = commandNames(script) else { return false }
        return !names.isEmpty && names.allSatisfy { navigationCommands.contains($0) || quietCommands.contains($0) }
    }

    /// True when every command in a binding is one of `navigationCommands`.
    public static func isNavigation(_ script: String) -> Bool {
        guard let names = commandNames(script) else { return false }
        return !names.isEmpty && names.allSatisfy { navigationCommands.contains($0) }
    }

    /// The first word of every command in a binding, or nil when the script is none of the plain form: a pipe into another command, a
    /// compound (`&&`, `||`) or a grouping. The script is AeroSpace's own shell description, so a command ends at `;` or a newline and its
    /// name is never quoted (quoted words hold their separators).
    private static func commandNames(_ script: String) -> [String]? {
        var names: [String] = []
        var word = "", inWord = false, atName = true, quoted = false, quote: Character = " "
        for c in script {
            if quoted {
                if c == quote { quoted = false } else { word.append(c) }
                continue
            }
            switch c {
                case "'", "\"": quoted = true; quote = c; inWord = true
                case ";", "\n":
                    if inWord && atName { names.append(word) }
                    word = ""; inWord = false; atName = true
                case "|", "&", "(", ")":
                    return nil
                default:
                    if c.isWhitespace {
                        if inWord, atName { names.append(word); atName = false }
                        word = ""; inWord = false
                    } else {
                        word.append(c); inWord = true
                    }
            }
        }
        if inWord && atName { names.append(word) }
        return names
    }

    /// The rows after a focus change the event already names: that workspace is the focused one and shows, the workspaces beside it on
    /// the same monitor hide, and workspaces on other monitors keep the visible flag they had. Window rows follow their workspace. A
    /// workspace whose monitor the query did not report hides nothing: another monitor's flags are never guessed away.
    static func focusing(_ rows: Rows, on name: String) -> Rows {
        var out = rows
        let monitor = out.workspaces.first { $0.workspace == name }?.monitor
        var flags: [String: (focused: Bool, visible: Bool)] = [:]
        for i in out.workspaces.indices {
            let here = out.workspaces[i].workspace == name
            out.workspaces[i].focused = here
            if here {
                out.workspaces[i].visible = true
            } else if let m = out.workspaces[i].monitor, m == monitor {
                out.workspaces[i].visible = false
            }
            flags[out.workspaces[i].workspace] = (out.workspaces[i].focused ?? false, out.workspaces[i].visible ?? false)
        }
        for i in out.windows.indices {
            guard let f = flags[out.windows[i].workspace] else { continue }
            out.windows[i].workspaceFocused = f.focused
            out.windows[i].workspaceVisible = f.visible
        }
        return out
    }
}
