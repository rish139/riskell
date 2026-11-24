// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import Foundation
@testable import DwindleAerospaceExt

/// The part of AeroSpace the dwindle scripts act on: its tiling tree and the commands that change it, translated from its source, so a
/// test can run one of our command lines and look at the tree it leaves behind. Only what the scripts reach is here: tiles (no accordion),
/// no sizes, no fullscreen and no mouse, one display unless a test puts a workspace on another monitor.
///
/// Normalization decides the shape a script leaves, so it follows AeroSpace's own call sites: once before a line runs and after every
/// command in it (`Shell.run` calls `refreshModel`, and `Workspace.normalizeContainers` is part of it).
final class AeroSpaceModel {
    /// The id of the window the manager has focused; nil on an empty workspace.
    private(set) var focusedWindowId: Int?
    private(set) var focusedWorkspaceName: String?

    /// A display wider than it is tall is what AeroSpace makes a new workspace's root container from (`default-root-container-orientation`
    /// is `auto`).
    private let landscape: Bool
    private var workspaces: [String: WorkspaceNode] = [:]
    private var windows: [Int: WindowNode] = [:]

    init(landscape: Bool = true) {
        self.landscape = landscape
    }

    // MARK: the tree, from outside

    /// A new window arriving on a workspace: a tiling window lands right after the workspace's most recently used one, and at the end of
    /// the tree when that window is not in a tiling container (AeroSpace's `unbindAndGetBindingDataForNewTilingWindow`).
    func addWindow(_ id: Int, to workspace: String) throws {
        guard windows[id] == nil else { throw ModelError.unsupported("window \(id) is already there") }
        let window = WindowNode(id)
        windows[id] = window
        placeAsNewTilingWindow(window, on: self.workspace(workspace))
    }

    /// A workspace with no window on it, as AeroSpace's persistent workspaces are: it is on `monitor` (the only one unless a test says
    /// otherwise) and takes part in `next` and `prev` while it is empty.
    func addWorkspace(_ name: String, on monitor: Int = 1) {
        _ = workspace(name, on: monitor)
    }

    /// A window closing: it leaves the tree and, when it was on the focused workspace, that workspace's most recently used window takes
    /// the focus (AeroSpace's `garbageCollect`). The tree is then normalized.
    func close(_ id: Int) throws {
        guard let window = windows[id] else { throw ModelError.unsupported("window \(id) is not there") }
        closeWindow(window)
        normalize()
    }

    /// Focuses a window. The tree remembers it as the most recent child of every container above it, which is what a later placement
    /// reads (AeroSpace's `setFocus`).
    func focus(_ id: Int) throws {
        guard let window = windows[id], let workspace = window.nodeWorkspace else {
            throw ModelError.unsupported("window \(id) is not there")
        }
        setFocus(to: window, on: workspace)
    }

    // MARK: a tree, as test support

    /// Fills a workspace with a tree of rows and columns, as test support: a container holds any number of members, so a test can start
    /// from a layout of its own, which no command line has to be able to make. The windows named in the tree are new ones, and the first
    /// of them takes the focus.
    func build(_ tree: Tile, on name: String) throws {
        for id in tree.leaves where windows[id] != nil {
            throw ModelError.unsupported("window \(id) is already there")
        }
        let workspace = workspace(name)
        let root: ContainerNode
        switch tree {
            case .window(let id):
                root = ContainerNode(orientation: landscape ? .h : .v)
                let window = WindowNode(id)
                windows[id] = window
                window.bind(to: root, index: bindLast)
            case .split(let axis, let children):
                root = ContainerNode(orientation: axis == .row ? .h : .v)
                for child in children {
                    node(of: child).bind(to: root, index: bindLast)
                }
        }
        workspace.root.unbindFromParent()
        root.bind(to: workspace, index: bindLast)
        workspace.root = root
        if let first = tree.leaves.first {
            try focus(first)
        }
    }

    private func node(of tile: Tile) -> Node {
        switch tile {
            case .window(let id):
                let window = WindowNode(id)
                windows[id] = window
                return window
            case .split(let axis, let children):
                let container = ContainerNode(orientation: axis == .row ? .h : .v)
                for child in children {
                    node(of: child).bind(to: container, index: bindLast)
                }
                return container
        }
    }

    // MARK: running a command line

    /// Runs one line of AeroSpace's shell language as the rules send it: commands separated by `;`, each an `||` chain of `&&` chains.
    /// Returns the exit code of the line: 0 for success, 1 when the last `test` was false, 2 for a failure. Quotes and parentheses are
    /// not supported.
    @discardableResult
    func run(_ line: String, on focusedWindow: Int) throws -> Int32 {
        normalize()
        var code: Int32 = 0
        for command in line.split(separator: ";") {
            code = try runOr(String(command), on: focusedWindow)
        }
        return code
    }

    // MARK: what the tests read

    /// A workspace's tree as text: a container is its orientation letter and its children in order, so `h[1, v[2, h[3, 4]]]` is a row of
    /// window 1 and a column of 2 and a row of 3 and 4. Floating windows follow as `floating[...]` when there are any.
    func tree(of workspace: String) -> String? {
        guard let workspace = workspaces[workspace] else { return nil }
        var text = workspace.root.text()
        if let floating = workspace.floating, !floating.children.isEmpty {
            text += " floating[" + floating.children.map { $0.text() }.joined(separator: ", ") + "]"
        }
        return text
    }

    /// Every window, in id order, which is the order in which they were made.
    var windowIds: [Int] { windows.keys.sorted() }

    /// Every workspace, in name order.
    var workspaceNames: [String] { workspaces.keys.sorted() }

    func workspaceName(of id: Int) -> String? { windows[id]?.nodeWorkspace?.name }

    func isFloating(_ id: Int) -> Bool { windows[id]?.parent is FloatingNode }

    /// A workspace's root layout in AeroSpace's words: `h_tiles` or `v_tiles`.
    func rootLayout(of workspace: String) -> String? { workspaces[workspace]?.root.orientation.tiles }

    /// The monitor the workspace is assigned to: every workspace has one, an empty one too, and `next` and `prev` only go between the
    /// workspaces of one monitor.
    func monitor(of workspace: String) -> Int? { workspaces[workspace]?.monitor }

    /// The workspace a name makes, if it is not there yet: AeroSpace's `Workspace.get(byName:)` does the same.
    /// The workspace a name makes, if it is not there yet: AeroSpace's `Workspace.get(byName:)` does the same.
    private func workspace(_ name: String, on monitor: Int = 1) -> WorkspaceNode {
        if let workspace = workspaces[name] { return workspace }
        let workspace = WorkspaceNode(name: name, orientation: landscape ? .h : .v, monitor: monitor)
        workspaces[name] = workspace
        return workspace
    }

    /// The workspaces of one monitor, by name: what `next` and `prev` walk (`getNextPrevWorkspace`), empty workspaces included.
    private func workspaceNames(on monitor: Int) -> [String] {
        workspaces.values.filter { $0.monitor == monitor }.map(\.name).sorted()
    }

    /// The workspace the manager has focused, if any: what a command without a target window acts on.
    private var focusedWorkspace: WorkspaceNode? { focusedWorkspaceName.flatMap { workspaces[$0] } }

    // MARK: the shell

    private func runOr(_ text: String, on focusedWindow: Int) throws -> Int32 {
        var code: Int32 = 2
        for command in text.split(separator: "||") {
            code = try runAnd(String(command), on: focusedWindow)
            if code == 0 { break }
        }
        return code
    }

    private func runAnd(_ text: String, on focusedWindow: Int) throws -> Int32 {
        var code: Int32 = 0
        for command in text.split(separator: "&&") {
            code = try runCommand(String(command), on: focusedWindow)
            if code != 0 { break }
        }
        return code
    }

    private func runCommand(_ text: String, on focusedWindow: Int) throws -> Int32 {
        let parsed = try Parsed(text)
        let target = resolve(parsed, on: focusedWindow)
        // AeroSpace normalizes after every command, whatever its exit code.
        defer { normalize() }
        return try perform(parsed, target: target)
    }

    /// The exit code of one command, on the target `resolveTargetOrReportError` picks: `--window-id`, then `--workspace`, then the window
    /// the request names, then the focused window.
    private func perform(_ parsed: Parsed, target: Target?) throws -> Int32 {
        switch parsed.name {
            case "test":
                return try test(parsed, target: target)
            case "test-not":
                // the same test with its two answers swapped; a test that could not be made is still a failure (`TestNotCommand`)
                let code = try test(parsed, target: target)
                return code == ModelCode.succ ? ModelCode.testFalse : code == ModelCode.testFalse ? ModelCode.succ : ModelCode.fail
            case "focus":
                if let raw = parsed.flags["--dfs-index"] {
                    // the window at that place in the focused workspace's own tree, in tree order (`FocusCommand`, `.dfsIndex`)
                    guard parsed.words.isEmpty,
                          let index = Int(raw), let workspace = focusedWorkspace,
                          workspace.root.windows.indices.contains(index) else { return ModelCode.fail }
                    setFocus(to: workspace.root.windows[index], on: workspace)
                    return ModelCode.succ
                }
                guard parsed.words.isEmpty else {
                    throw ModelError.unsupported("focus '\(parsed.words.joined(separator: " "))' (only --window-id and --dfs-index)")
                }
                guard let window = target?.window, let workspace = window.nodeWorkspace else { return ModelCode.fail }
                setFocus(to: window, on: workspace)
                return ModelCode.succ
            case "workspace":
                // `workspace NAME`: the focus goes to that workspace, and to its most recently used window when it has one
                guard let name = parsed.words.first else { return ModelCode.fail }
                guard focusedWorkspaceName != name else { return ModelCode.succ }
                let next = workspace(name)
                setFocus(to: next.mostRecentWindow, on: next)
                return ModelCode.succ
            case "join-with":
                guard let window = target?.window else { return ModelCode.fail }
                return joinWith(window, direction: try parsed.direction())
            case "swap":
                guard let window = target?.window else { return ModelCode.fail }
                return swap(window, direction: try parsed.direction())
            case "move":
                guard let window = target?.window else { return ModelCode.fail }
                return try move(window, direction: parsed.direction(), parsed: parsed)
            case "layout":
                return try layout(parsed, target: target)
            case "flatten-workspace-tree":
                guard let workspace = target?.workspace else { return ModelCode.fail }
                let windows = workspace.root.windows
                for window in windows {
                    window.bind(to: workspace.root, index: bindLast)
                }
                return ModelCode.succ
            case "balance-sizes":
                // Sizes do not change the shape of the tree.
                return target == nil ? ModelCode.fail : ModelCode.succ
            case "close":
                guard let window = target?.window else { return ModelCode.fail }
                closeWindow(window)
                return ModelCode.succ
            case "move-node-to-workspace":
                // AeroSpace's parser refuses this before it runs anything, and with it the whole expression
                if parsed.flags["--window-id"] != nil, let word = parsed.words.first, word == "next" || word == "prev" {
                    throw ModelError.unsupported("--window-id is incompatible with (next|prev)")
                }
                guard let window = target?.window else { return ModelCode.fail }
                return moveToWorkspace(window, parsed)
            default:
                throw ModelError.unsupported("command '\(parsed.name)'")
        }
    }

    private func resolve(_ parsed: Parsed, on focusedWindow: Int) -> Target? {
        if let raw = parsed.flags["--window-id"] {
            guard let id = Int(raw), let window = windows[id], let workspace = window.nodeWorkspace else { return nil }
            return Target(window: window, workspace: workspace)
        }
        if let name = parsed.flags["--workspace"] {
            let workspace = self.workspace(name)
            return Target(window: workspace.mostRecentWindow, workspace: workspace)
        }
        if let window = windows[focusedWindow], let workspace = window.nodeWorkspace {
            return Target(window: window, workspace: workspace)
        }
        guard let id = focusedWindowId, let window = windows[id], let workspace = window.nodeWorkspace else { return nil }
        return Target(window: window, workspace: workspace)
    }

    // MARK: commands

    /// `<var> = <value>`: exit 0 when they are equal, 1 when not, 2 when the variable cannot be expanded.
    private func test(_ parsed: Parsed, target: Target?) throws -> Int32 {
        guard parsed.words.count == 3, parsed.words[1] == "=" else {
            throw ModelError.unsupported("test '\(parsed.words.joined(separator: " "))' (only '<var> = <value>')")
        }
        guard let target, let value = try expand(parsed.words[0], target: target) else { return ModelCode.fail }
        return value == parsed.words[2] ? ModelCode.succ : ModelCode.testFalse
    }

    /// The `%{...}` variables the scripts use. A variable the model does not know is an error, not a silent false.
    private func expand(_ variable: String, target: Target) throws -> String? {
        switch variable {
            case "%{window-parent-container-layout}", "%{window-layout}":
                guard let window = target.window else { return nil }
                guard let parent = window.parent else { return nil }
                if parent is FloatingNode { return "floating" }
                guard let container = parent as? ContainerNode else { return nil }
                return container.orientation.tiles
            case "%{workspace}":
                // the workspace the window is on when the command runs, so that it follows the window to another workspace
                return target.workspace.name
            case "%{workspace-root-container-layout}":
                return target.workspace.root.orientation.tiles
            default:
                throw ModelError.unsupported("interpolation '\(variable)'")
        }
    }

    /// A join: the window and the neighbour in that direction get a container of their own, laid out across the direction
    /// (`JoinWithCommand`).
    private func joinWith(_ window: WindowNode, direction: Cardinal) -> Int32 {
        guard let (parent, ownIndex) = window.closestParent(in: direction) else { return ModelCode.fail }
        let neighbour = parent.children[ownIndex + direction.focusOffset]
        let place = neighbour.detach()
        let container = ContainerNode(orientation: parent.orientation.opposite)
        container.bind(to: parent, index: place.index)
        window.unbindFromParent()
        neighbour.bind(to: container, index: 0)
        window.bind(to: container, index: direction.isPositive ? 0 : bindLast)
        return ModelCode.succ
    }

    /// A swap: the two windows trade places (`SwapCommand` with a direction).
    private func swap(_ window: WindowNode, direction: Cardinal) -> Int32 {
        guard let (parent, ownIndex) = window.closestParent(in: direction) else { return ModelCode.fail }
        guard let other = parent.children[ownIndex + direction.focusOffset].window(snappedTo: direction.opposite) else {
            return ModelCode.fail
        }
        swapWindows(window, other)
        return ModelCode.succ
    }

    /// A move (`MoveCommand`): a window trades places with a neighbour window, goes into a neighbouring container, out into the parent
    /// container, or over the workspace boundary.
    private func move(_ window: WindowNode, direction: Cardinal, parsed: Parsed) throws -> Int32 {
        let boundaries = parsed.flags["--boundaries"] ?? "workspace"
        guard boundaries == "workspace" else { throw ModelError.unsupported("--boundaries \(boundaries) (one display only)") }
        let action = parsed.flags["--boundaries-action"] ?? "create-implicit-container"
        switch action {
            case "stop", "fail", "create-implicit-container": break
            default: throw ModelError.unsupported("--boundaries-action \(action)")
        }
        guard let parent = window.parent as? ContainerNode else { return ModelCode.fail }
        if parent is FloatingNode { return ModelCode.fail } // moving a floating window is not supported by AeroSpace either
        let siblingIndex = window.ownIndex.map { $0 + direction.focusOffset } ?? 0
        if parent.orientation == direction.orientation, parent.children.indices.contains(siblingIndex) {
            let sibling = parent.children[siblingIndex]
            if let container = sibling as? ContainerNode {
                return deepMoveIn(window, into: container, direction)
            }
            window.unbindFromParent()
            window.bind(to: parent, index: siblingIndex)
            return ModelCode.succ
        }
        return try moveOut(window, direction, action: action)
    }

    private func deepMoveIn(_ window: WindowNode, into container: ContainerNode, _ direction: Cardinal) -> Int32 {
        var target: Node = container
        while let current = target as? ContainerNode, current.orientation != direction.orientation {
            guard let next = current.mostRecentChild else { return ModelCode.fail }
            target = next
        }
        if let container = target as? ContainerNode {
            window.bind(to: container, index: 0)
        } else {
            guard let parent = target.parent, let index = target.ownIndex else { return ModelCode.fail }
            window.bind(to: parent, index: index + 1)
        }
        return ModelCode.succ
    }

    /// Out of the inner-most container laid out in that direction: into the container above it when there is one, over the workspace
    /// boundary otherwise.
    private func moveOut(_ window: WindowNode, _ direction: Cardinal, action: String) throws -> Int32 {
        let innermost = window.parents.first { node in
            guard let parent = node.parent else { return true }
            guard let container = parent as? ContainerNode, !(container is FloatingNode) else { return true }
            return container.orientation == direction.orientation
        } as? ContainerNode
        guard let innermost else { return ModelCode.fail }
        if let parent = innermost.parent as? ContainerNode, !(parent is FloatingNode) {
            window.bind(to: parent, index: (innermost.ownIndex ?? 0) + direction.insertionOffset)
            return ModelCode.succ
        }
        switch action {
            case "stop": return ModelCode.succ
            case "fail": return ModelCode.fail
            default: break
        }
        guard let workspace = innermost.nodeWorkspace else { return ModelCode.fail }
        let previousRoot = workspace.root
        previousRoot.unbindFromParent()
        let root = ContainerNode(orientation: direction.orientation)
        root.bind(to: workspace, index: 0)
        workspace.root = root
        previousRoot.bind(to: root, index: 0)
        window.bind(to: root, index: direction.insertionOffset)
        return ModelCode.succ
    }

    /// `LayoutCommand`: a container's layout, or a window floating or back in the tiling tree.
    private func layout(_ parsed: Parsed, target: Target?) throws -> Int32 {
        guard let target else { return ModelCode.fail }
        // AeroSpace's parser refuses these two forms too.
        if parsed.flags["--window-id"] != nil, parsed.flags["--workspace"] != nil {
            throw ModelError.unsupported("layout with both --window-id and --workspace")
        }
        if parsed.flags["--workspace"] != nil, parsed.flags["--root"] == nil {
            throw ModelError.unsupported("layout --workspace without --root")
        }
        let node: Node
        if parsed.flags["--root"] != nil {
            node = target.workspace.root
        } else {
            guard let parent = target.window?.parent else { return ModelCode.fail }
            node = parent
        }
        guard !parsed.words.isEmpty else { throw ModelError.unsupported("layout without a layout") }
        for description in parsed.words where !knownLayouts.contains(description) {
            throw ModelError.unsupported("layout '\(description)' (accordion is not modelled)")
        }
        let requested = parsed.words.first { !matches($0, node: node) } ?? parsed.words[0]
        if matches(requested, node: node) {
            return parsed.flags["--fail-if-noop"] != nil ? ModelCode.fail : ModelCode.succ
        }
        switch requested {
            case "tiling":
                guard let window = target.window else { return ModelCode.fail }
                if node is FloatingNode {
                    window.unbindFromParent()
                    placeAsNewTilingWindow(window, on: target.workspace)
                }
                return ModelCode.succ
            case "floating":
                guard let window = target.window else { return ModelCode.fail }
                window.bind(to: target.workspace.floatingContainer, index: bindLast)
                return ModelCode.succ
            default:
                guard let container = node as? ContainerNode, !(container is FloatingNode) else { return ModelCode.fail }
                container.changeOrientation(orientation(of: requested) ?? container.orientation)
                return ModelCode.succ
        }
    }

    private func matches(_ description: String, node: Node) -> Bool {
        let container = node is FloatingNode ? nil : node as? ContainerNode
        switch description {
            case "tiling", "tiles": return container != nil
            case "floating": return node is FloatingNode
            case "h_tiles", "horizontal": return container?.orientation == .h
            case "v_tiles", "vertical": return container?.orientation == .v
            default: return false
        }
    }

    private func orientation(of description: String) -> Orientation? {
        switch description {
            case "h_tiles", "horizontal": .h
            case "v_tiles", "vertical": .v
            default: nil
        }
    }

    /// `move-node-to-workspace [--window-id W] [--focus-follows-window] next|prev|NAME`: the window goes to the end of the target's tiling
    /// tree. `next` and `prev` are the workspaces after and before the window's own on its monitor, empty ones included and by name, and
    /// there is none beyond the last and the first (`getNextPrevWorkspace`, no wrap-around).
    private func moveToWorkspace(_ window: WindowNode, _ parsed: Parsed) -> Int32 {
        guard let word = parsed.words.first else { return ModelCode.fail }
        let target: WorkspaceNode
        switch word {
            case "next", "prev":
                guard let here = window.nodeWorkspace else { return ModelCode.fail }
                let names = workspaceNames(on: here.monitor)
                guard let index = names.firstIndex(of: here.name) else { return ModelCode.fail }
                let other = index + (word == "next" ? 1 : -1)
                guard names.indices.contains(other) else { return ModelCode.fail }
                target = workspace(names[other])
            default:
                target = workspace(word)
        }
        if window.nodeWorkspace === target {
            return parsed.flags["--fail-if-noop"] != nil ? ModelCode.fail : ModelCode.succ
        }
        let container = window.parent is FloatingNode ? target.floatingContainer : target.root
        window.bind(to: container, index: bindLast)
        if parsed.flags["--focus-follows-window"] != nil {
            setFocus(to: window, on: target)
        }
        return ModelCode.succ
    }

    // MARK: focus and closing

    private func setFocus(to window: WindowNode?, on workspace: WorkspaceNode) {
        if focusedWorkspaceName != workspace.name {
            focusedWindowId.flatMap { windows[$0] }?.markAsMostRecentChild()
        }
        focusedWindowId = window?.id
        focusedWorkspaceName = workspace.name
        window?.markAsMostRecentChild()
    }

    private func closeWindow(_ window: WindowNode) {
        windows.removeValue(forKey: window.id)
        let workspace = window.unbindFromParent()?.parent.nodeWorkspace
        if let workspace, workspace.name == focusedWorkspaceName {
            setFocus(to: workspace.mostRecentWindow ?? workspace.anyWindow, on: workspace)
        }
    }

    // MARK: normalization

    private func normalize() {
        for workspace in workspaces.values {
            workspace.normalize()
        }
    }

    /// A new tiling window lands right after the workspace's most recently used window, and at the end of the tree when that window is
    /// floating or the workspace is empty (AeroSpace's `unbindAndGetBindingDataForNewTilingWindow`).
    private func placeAsNewTilingWindow(_ window: WindowNode, on workspace: WorkspaceNode) {
        if let mru = workspace.mostRecentWindow, let parent = mru.parent as? ContainerNode, !(parent is FloatingNode),
           let index = mru.ownIndex {
            window.bind(to: parent, index: index + 1)
        } else {
            window.bind(to: workspace.root, index: bindLast)
        }
    }

    private func swapWindows(_ first: WindowNode, _ second: WindowNode) {
        if first === second { return }
        let secondPlace = second.detach()
        let firstPlace = first.detach()
        second.bind(to: firstPlace.parent, index: firstPlace.index)
        first.bind(to: secondPlace.parent, index: secondPlace.index)
    }
}

// MARK: the shapes of the tree

/// AeroSpace's exit codes, as far as a script sees them.
private enum ModelCode {
    static let succ: Int32 = 0
    static let testFalse: Int32 = 1
    static let fail: Int32 = 2
}

/// AeroSpace's `INDEX_BIND_LAST`: append to the end.
private let bindLast = -1

/// The layouts `layout` knows.
private let knownLayouts: Set<String> = ["tiles", "h_tiles", "v_tiles", "horizontal", "vertical", "tiling", "floating"]

/// Which way a container lays its children out: `h` in a row, `v` in a column.
enum Orientation {
    case h, v

    var opposite: Orientation { self == .h ? .v : .h }
    var letter: String { self == .h ? "h" : "v" }

    /// Its layout in AeroSpace's words: what `--root` takes and `%{window-parent-container-layout}` reports.
    var tiles: String { letter + "_tiles" }
}

/// A cardinal direction, as `join-with`, `move` and `swap` name it.
enum Cardinal: String {
    case left, down, up, right

    var orientation: Orientation { self == .up || self == .down ? .v : .h }
    var isPositive: Bool { self == .down || self == .right }
    var insertionOffset: Int { isPositive ? 1 : 0 }
    var focusOffset: Int { isPositive ? 1 : -1 }

    var opposite: Cardinal {
        switch self {
            case .left: .right
            case .down: .up
            case .up: .down
            case .right: .left
        }
    }
}

/// Where a node sat in its parent when it was detached.
struct Binding {
    let parent: Node
    let index: Int
}

/// What a command acts on, as `resolveTargetOrReportError` picks it.
private struct Target {
    let window: WindowNode?
    let workspace: WorkspaceNode
}

/// One node of a tree: a window, a container or a workspace.
class Node {
    fileprivate(set) var children: [Node] = []
    fileprivate(set) weak var parent: Node?
    /// The children this node last worked with, most recent first, as AeroSpace's `MruStack` keeps them. Where a new window lands, and
    /// which window a workspace focuses.
    fileprivate(set) var mruChildren: [Node] = []

    var ownIndex: Int? { parent?.children.firstIndex { $0 === self } }
    var parents: [Node] { parent.map { [$0] + $0.parents } ?? [] }
    var parentsWithSelf: [Node] { [self] + parents }
    var nodeWorkspace: WorkspaceNode? { self as? WorkspaceNode ?? parent?.nodeWorkspace }

    /// A container with a workspace for a parent is the workspace's root tiling container: a lone child leaves it in place.
    var isRootContainer: Bool { parent is WorkspaceNode }

    var mostRecentChild: Node? { mruChildren.first ?? children.last }

    /// The window AeroSpace would call the most recent here: down the most recent children only, so nil when that branch holds none
    /// (`mostRecentWindowRecursive`).
    var mostRecentWindow: WindowNode? {
        if let window = self as? WindowNode { return window }
        return mostRecentChild?.mostRecentWindow
    }

    /// Any window below this, in tree order: what an empty container is known by.
    var anyWindow: WindowNode? {
        if let window = self as? WindowNode { return window }
        for child in children {
            if let window = child.anyWindow { return window }
        }
        return nil
    }

    /// The tiling windows below this, in tree order: the order `flatten-workspace-tree` keeps (`allLeafWindowsRecursive`).
    var windows: [WindowNode] {
        if let window = self as? WindowNode { return [window] }
        return children.flatMap { $0.windows }
    }

    func markAsMostRecentChild() {
        guard let parent else { return }
        parent.mruChildren.removeAll { $0 === self }
        parent.mruChildren.insert(self, at: 0)
        parent.markAsMostRecentChild()
    }

    /// Puts this node in a parent, at `index` or at the end for `bindLast`. A binding node is remembered as the most recent child, so a
    /// later window lands after it.
    func bind(to newParent: Node, index: Int) {
        unbindFromParent()
        newParent.children.insert(self, at: index == bindLast ? newParent.children.count : index)
        parent = newParent
        markAsMostRecentChild()
    }

    @discardableResult
    func unbindFromParent() -> Binding? {
        guard let parent, let index = ownIndex else { return nil }
        parent.children.remove(at: index)
        parent.mruChildren.removeAll { $0 === self }
        self.parent = nil
        return Binding(parent: parent, index: index)
    }

    /// Leaves the parent it is in, and says where it was.
    func detach() -> Binding {
        guard let place = unbindFromParent() else { fatalError("This node is not in a tree") }
        return place
    }

    /// The tree as text, the way `tree(of:)` prints it.
    func text() -> String {
        if let window = self as? WindowNode { return String(window.id) }
        guard let container = self as? ContainerNode else { return "" }
        return container.orientation.letter + "[" + container.children.map { $0.text() }.joined(separator: ", ") + "]"
    }

    /// The closest ancestor, this node included, whose parent holds children in that direction (`closestParent`).
    func closestParent(in direction: Cardinal) -> (parent: ContainerNode, ownIndex: Int)? {
        let innermost = parentsWithSelf.first { node in
            guard let parent = node.parent as? ContainerNode, !(parent is FloatingNode) else { return true }
            return parent.orientation == direction.orientation
                && (node.ownIndex.map { parent.children.indices.contains($0 + direction.focusOffset) } ?? true)
        }
        guard let innermost, let parent = innermost.parent as? ContainerNode, !(parent is FloatingNode) else { return nil }
        return innermost.ownIndex.map { (parent, $0) }
    }

    /// The window in this subtree that a focus in that direction would reach (`findLeafWindowRecursive(snappedTo:)`).
    func window(snappedTo direction: Cardinal) -> WindowNode? {
        if let window = self as? WindowNode { return window }
        guard let container = self as? ContainerNode else { return nodeWorkspace?.root.window(snappedTo: direction) }
        if container.orientation == direction.orientation {
            return (direction.isPositive ? container.children.last : container.children.first)?.window(snappedTo: direction)
        }
        return container.mostRecentChild?.window(snappedTo: direction)
    }
}

/// A window: a leaf of the tree, known by the id the scripts name it with.
final class WindowNode: Node {
    let id: Int

    init(_ id: Int) {
        self.id = id
    }
}

/// A container: its children are laid out along its orientation. Every container is tiles, because no script the model serves uses an
/// accordion.
class ContainerNode: Node {
    fileprivate(set) var orientation: Orientation

    init(orientation: Orientation) {
        self.orientation = orientation
    }

    /// Takes an orientation. The containers above it take the opposite one, alternating: AeroSpace does the same walk when nested
    /// containers must differ.
    func changeOrientation(_ target: Orientation) {
        if orientation == target { return }
        var next = target
        for node in parentsWithSelf {
            guard let container = node as? ContainerNode else { continue }
            container.orientation = next
            next = next.opposite
        }
    }
}

/// Where a workspace keeps its floating windows: outside the tiling tree, so a join or a move leaves them alone.
final class FloatingNode: ContainerNode {}

/// A workspace: its tiling tree, its floating windows, and which of the two containers it last worked with.
final class WorkspaceNode: Node {
    let name: String
    /// The monitor it is assigned to, even while it is empty: `next` and `prev` only go between the workspaces of one monitor.
    let monitor: Int
    /// The tiling container. Normalization can give its place to a container that was its only child, which replaces the root.
    fileprivate(set) var root: ContainerNode
    fileprivate(set) var floating: FloatingNode?

    init(name: String, orientation: Orientation, monitor: Int) {
        self.name = name
        self.monitor = monitor
        root = ContainerNode(orientation: orientation)
        super.init()
        root.bind(to: self, index: bindLast)
    }

    /// The container floating windows go to, made when the first one floats: from then on it is the workspace's most recent child,
    /// exactly as AeroSpace's lazily made `floatingWindowsContainer` is.
    var floatingContainer: FloatingNode {
        if let floating { return floating }
        let container = FloatingNode(orientation: .h)
        container.bind(to: self, index: bindLast)
        floating = container
        return container
    }

    /// `Workspace.normalizeContainers`: a container with a single child gives that child its place, a nested container takes the
    /// orientation opposite its parent, and empty containers go.
    func normalize() {
        root.unbindEmptyAndAutoFlatten()
        if let newRoot = children.first(where: { $0 is ContainerNode && !($0 is FloatingNode) }) as? ContainerNode {
            root = newRoot
        }
        root.normalizeOppositeOrientation()
    }
}

extension Node {
    /// A container with one child is unbound and the child takes its place; a container with none is unbound (`unbindEmptyAndAutoFlatten`).
    func unbindEmptyAndAutoFlatten() {
        if children.count == 1, let child = children.first, isRootContainer ? child is ContainerNode : true {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let place = detach()
            child.bind(to: place.parent, index: place.index)
            (child as? ContainerNode)?.unbindEmptyAndAutoFlatten()
            if let mru, mru !== self {
                mru.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? ContainerNode)?.unbindEmptyAndAutoFlatten()
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }

    /// A nested container takes the orientation opposite its parent's (`normalizeOppositeOrientationForNestedContainers`).
    func normalizeOppositeOrientation() {
        if let container = self as? ContainerNode, let parent = container.parent as? ContainerNode,
           parent.orientation == container.orientation {
            container.orientation = container.orientation.opposite
        }
        for child in children {
            child.normalizeOppositeOrientation()
        }
    }
}

/// One command of a line: its name, its positional words and its flags (the value of a switch is the empty text).
private struct Parsed {
    let name: String
    let words: [String]
    let flags: [String: String]

    /// The flags that take a value. Anything else starting with `--`, and quotes and parentheses, are a script the model does not know.
    private static let flagsWithValue: Set<String> = ["--window-id", "--workspace", "--boundaries", "--boundaries-action", "--dfs-index"]
    private static let switches: Set<String> = ["--root", "--fail-if-noop", "--focus-follows-window"]

    init(_ text: String) throws {
        var parts = text.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { throw ModelError.unsupported("an empty command") }
        name = parts.removeFirst()
        var words: [String] = []
        var flags: [String: String] = [:]
        var index = 0
        while index < parts.count {
            let part = parts[index]
            if part.hasPrefix("--") {
                if Parsed.flagsWithValue.contains(part) {
                    guard index + 1 < parts.count else { throw ModelError.unsupported("\(part) without a value") }
                    flags[part] = parts[index + 1]
                    index += 2
                } else if Parsed.switches.contains(part) {
                    flags[part] = ""
                    index += 1
                } else {
                    throw ModelError.unsupported("flag '\(part)'")
                }
            } else if part.contains("(") || part.contains(")") || part.contains("\"") || part.contains("'") {
                throw ModelError.unsupported("quotes and parentheses in '\(text)'")
            } else {
                words.append(part)
                index += 1
            }
        }
        self.words = words
        self.flags = flags
    }

    func direction() throws -> Cardinal {
        guard let word = words.first, let direction = Cardinal(rawValue: word) else {
            throw ModelError.unsupported("direction '\(words.first ?? "")'")
        }
        return direction
    }
}

enum ModelError: Error, CustomStringConvertible {
    case unsupported(String)

    var description: String {
        switch self {
            case .unsupported(let what): "the AeroSpace model does not support \(what)"
        }
    }
}
