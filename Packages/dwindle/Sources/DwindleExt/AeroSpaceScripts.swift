// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

/// The command lines the rules send, in AeroSpace's own language. They all live here, so the text that has to match AeroSpace's own
/// parser and its layout code is in one place.
enum AeroSpaceScripts {
    /// A split for the window that has just appeared. AeroSpace tests the window's parent container itself: in a row it joins the
    /// window to the one on its left, in a column to the one above, and a floating window or an accordion does neither.
    static let split = "test %{window-parent-container-layout} = h_tiles && join-with left"
        + " || test %{window-parent-container-layout} = v_tiles && join-with up"

    /// The tidy, in one line: flatten the workspace into one container, lay that container out the way the display is (a row on a wide
    /// display, a column on a tall one), float every window but the first away, then bring them back in order (each made tiling, and joined
    /// to the one before it in the direction that alternates), and finally even out the sizes. The float-and-tile round trip is what puts
    /// the windows in id order: the flatten keeps the order the tree had. Two windows cannot alternate, and need no join; the flatten alone
    /// would leave them in whatever order the tree had, so they get the round trip too.
    static func tidy(workspace: String, root: RootOrientation, windows: [Int]) -> String {
        var lines = ["flatten-workspace-tree --workspace \(workspace)",
                     "layout --workspace \(workspace) --root \(root.tiles)"]
        if windows.count > 1 {
            lines += windows.dropFirst().map { "layout --window-id \($0) floating" }
            for (i, id) in windows.dropFirst().enumerated() {
                let index = i + 2
                lines.append("layout --window-id \(id) tiling")
                if index > 2 { lines.append("join-with --window-id \(id) \(root.joinDirection(index))") }
            }
        }
        lines.append("balance-sizes --workspace \(workspace)")
        return lines.joined(separator: "; ")
    }
}
