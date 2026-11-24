// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import XCTest
@testable import DwindleAerospaceExt

/// The display the trees are laid out on: 1600 by 900 points, with `gap` points between siblings.
private let displayWidth = 1600.0
private let displayHeight = 900.0
private let gap = 7.0

/// Every tree of rows and columns with `leaves` as its windows in screen order: the top container runs along `rootAxis`, every container
/// holds two or more members, and each one takes the axis the container above it does not, so the axes alternate down the tree.
func alternatingTrees(_ leaves: [Int], rootAxis: Axis) -> [Tile] {
    guard leaves.count > 1 else { return leaves.map { .window($0) } }
    let inner: Axis = rootAxis == .row ? .column : .row
    var trees: [Tile] = []
    for parts in compositions(of: leaves) {
        // one subtree for each part, with the axis the container above this one does not have
        var combinations: [[Tile]] = [[]]
        for part in parts {
            let options = alternatingTrees(part, rootAxis: inner)
            combinations = combinations.flatMap { combination in options.map { combination + [$0] } }
        }
        trees += combinations.map { .split(rootAxis, $0) }
    }
    return trees
}

/// Every way of cutting `leaves` into two or more runs of one or more, in screen order.
private func compositions(of leaves: [Int]) -> [[[Int]]] {
    guard leaves.count > 1 else { return [] }
    var result: [[[Int]]] = []
    for cut in 1 ..< leaves.count {
        let head = Array(leaves[..<cut])
        let tail = Array(leaves[cut...])
        result.append([head, tail])
        result += compositions(of: tail).map { [head] + $0 }
    }
    return result
}

/// The tree as the model prints it: `h[1, v[2, 3]]` is a row of window 1 and a column of 2 and 3.
func treeText(_ tile: Tile) -> String {
    switch tile {
        case .window(let id):
            return String(id)
        case .split(let axis, let children):
            return (axis == .row ? "h" : "v") + "[" + children.map(treeText).joined(separator: ", ") + "]"
    }
}

/// Reads back the text the model prints, so that a result can be compared as a tree, axes and all.
func treeReading(_ text: String) -> Tile? {
    var index = 0
    return treeReading(Array(text), &index)
}

private func treeReading(_ characters: [Character], _ index: inout Int) -> Tile? {
    guard index < characters.count else { return nil }
    if characters[index] == "h" || characters[index] == "v" {
        let axis: Axis = characters[index] == "h" ? .row : .column
        index += 2 // the axis letter and its bracket
        var children: [Tile] = []
        while index < characters.count, characters[index] != "]" {
            if characters[index] == "," || characters[index] == " " {
                index += 1 // the separator between two members
            } else if let child = treeReading(characters, &index) {
                children.append(child)
            } else {
                return nil
            }
        }
        guard index < characters.count else { return nil }
        index += 1 // the closing bracket
        return .split(axis, children)
    }
    var digits = ""
    while index < characters.count, characters[index].isNumber {
        digits.append(characters[index])
        index += 1
    }
    guard let id = Int(digits) else { return nil }
    return .window(id)
}

/// The axis a tree's top container runs along. A lone window has none: it is the axis its container would take on a wide display.
func topAxis(of tile: Tile) -> Axis {
    switch tile {
        case .window:
            return .row
        case .split(let axis, _):
            return axis
    }
}

/// The rectangles a tree takes on the display, laid out so that the frames read back as the very same tree: siblings sit `gap` points
/// apart across their container's axis, and each member's share of the space grows with its place in the container. How fast it grows
/// belongs to the container, so two containers of one level do not draw the same picture. The proportions are tried one after another
/// until the reading gives the tree back.
func rectangles(of tile: Tile, file: StaticString = #filePath, line: UInt = #line) -> [Slot] {
    var slots: [Slot] = []
    for seed in 0 ..< 20 {
        slots = layout(tile, seed: seed)
        if FrameTree.read(slots, rootAxis: topAxis(of: tile), tolerance: DwindleRules.frameTolerance) == .tree(tile) {
            return slots
        }
    }
    XCTFail("no proportions lay \(treeText(tile)) out so that the frames read back as it", file: file, line: line)
    return slots
}

private func layout(_ tile: Tile, seed: Int) -> [Slot] {
    var place = seed
    return layout(tile, x0: 0, y0: 0, x1: displayWidth, y1: displayHeight, place: &place)
}

private func layout(_ tile: Tile, x0: Double, y0: Double, x1: Double, y1: Double, place: inout Int) -> [Slot] {
    switch tile {
        case .window(let id):
            return [Slot(id: id, x0: x0, y0: y0, x1: x1, y1: y1)]
        case .split(let axis, let children):
            place += 1
            let slope = 0.15 + Double((place &* 7 &+ place / 3) % 12) * 0.12
            let weights = children.indices.map { 1 + Double($0) * slope }
            let total = weights.reduce(0, +)
            let length = (axis == .row ? x1 - x0 : y1 - y0) - gap * Double(children.count - 1)
            var slots: [Slot] = []
            var start = axis == .row ? x0 : y0
            for (index, child) in children.enumerated() {
                let size = length * weights[index] / total
                if axis == .row {
                    slots += layout(child, x0: start, y0: y0, x1: start + size, y1: y1, place: &place)
                } else {
                    slots += layout(child, x0: x0, y0: start, x1: x1, y1: start + size, place: &place)
                }
                start += size + gap
            }
            return slots
    }
}

/// A model whose workspace holds `tree`, nothing else.
func model(of tree: Tile, workspace: String = "1") throws -> AeroSpaceModel {
    let model = AeroSpaceModel(landscape: topAxis(of: tree) == .row)
    try model.build(tree, on: workspace)
    return model
}
