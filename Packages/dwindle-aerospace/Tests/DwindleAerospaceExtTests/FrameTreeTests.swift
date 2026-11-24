// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright 2026 Rishabh Tiwari

import XCTest
@testable import DwindleAerospaceExt

private func rect(_ id: Int, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Slot {
    Slot(id: id, x0: x0, y0: y0, x1: x1, y1: y1)
}

final class FrameTreeTests: XCTestCase {
    func testLoneWindowHasNoSplit() {
        XCTAssertEqual(FrameTree.read([rect(1, 0, 0, 100, 100)], rootAxis: .row, tolerance: 4),
                       .tree(.window(1)))
    }

    func testTwoSideBySide() {
        let slots = [rect(1, 0, 0, 100, 100), rect(2, 107, 0, 207, 100)]
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4),
                       .tree(.split(.row, [.window(1), .window(2)])))
    }

    func testTwoStacked() {
        let slots = [rect(1, 0, 0, 100, 100), rect(2, 0, 107, 100, 207)]
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .column, tolerance: 4),
                       .tree(.split(.column, [.window(1), .window(2)])))
    }

    func testChainOfFourOnAWideDisplay() {
        // a | (b / (c | d)) with 7-unit gaps and unequal sizes
        let slots = [
            rect(1, 0, 0, 300, 500),
            rect(2, 307, 0, 1000, 200),
            rect(3, 307, 207, 600, 500),
            rect(4, 607, 207, 1000, 500),
        ]
        let expected = Tile.split(.row, [
            .window(1),
            .split(.column, [
                .window(2),
                .split(.row, [.window(3), .window(4)]),
            ]),
        ])
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4), .tree(expected))
        XCTAssertEqual(expected.leaves, [1, 2, 3, 4])
        XCTAssertTrue(expected.isBinary)
    }

    func testChainOfFourOnATallDisplay() {
        // a / (b | (c / d)) with 7-unit gaps and unequal sizes
        let slots = [
            rect(1, 0, 0, 500, 300),
            rect(2, 0, 307, 200, 1000),
            rect(3, 207, 307, 500, 600),
            rect(4, 207, 607, 500, 1000),
        ]
        let expected = Tile.split(.column, [
            .window(1),
            .split(.row, [
                .window(2),
                .split(.column, [.window(3), .window(4)]),
            ]),
        ])
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .column, tolerance: 4), .tree(expected))
        XCTAssertEqual(expected.leaves, [1, 2, 3, 4])
        XCTAssertTrue(expected.isBinary)
    }

    func testMiddlePairMakesThreeChildrenAndIsNotBinary() {
        // a | (b / c) | d: the pair sits between two windows
        let slots = [
            rect(1, 0, 0, 200, 500),
            rect(2, 207, 0, 700, 250),
            rect(3, 207, 257, 700, 500),
            rect(4, 707, 0, 1000, 500),
        ]
        let expected = Tile.split(.row, [
            .window(1),
            .split(.column, [.window(2), .window(3)]),
            .window(4),
        ])
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4), .tree(expected))
        XCTAssertEqual(expected.leaves, [1, 2, 3, 4])
        XCTAssertFalse(expected.isBinary)
    }

    func testWindowsSmallerThanTheirSlotsStillSplit() {
        // wide gaps: each window leaves most of its slot empty
        let slots = [rect(1, 10, 10, 100, 490), rect(2, 400, 10, 490, 490)]
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4),
                       .tree(.split(.row, [.window(1), .window(2)])))
    }

    func testOverlapWithinToleranceStillCuts() {
        // 2-unit overlap, tolerance 4
        let slots = [rect(1, 0, 0, 100, 100), rect(2, 98, 0, 198, 100)]
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4),
                       .tree(.split(.row, [.window(1), .window(2)])))
    }

    func testOverlapBeyondToleranceIsUnreadable() {
        // 10-unit overlap, tolerance 4
        let slots = [rect(1, 0, 0, 100, 100), rect(2, 90, 0, 190, 100)]
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4), .unreadable)
    }

    func testIdenticalRectanglesAreUnreadable() {
        let slots = [rect(1, 0, 0, 100, 100), rect(2, 0, 0, 100, 100), rect(3, 0, 0, 100, 100)]
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4), .unreadable)
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .column, tolerance: 4), .unreadable)
    }

    func testTwoByTwoGridFollowsTheRootAxis() {
        let slots = [
            rect(1, 0, 0, 100, 100),
            rect(2, 107, 0, 207, 100),
            rect(3, 0, 107, 100, 207),
            rect(4, 107, 107, 207, 207),
        ]
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4),
                       .tree(.split(.row, [
                           .split(.column, [.window(1), .window(3)]),
                           .split(.column, [.window(2), .window(4)]),
                       ])))
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .column, tolerance: 4),
                       .tree(.split(.column, [
                           .split(.row, [.window(1), .window(2)]),
                           .split(.row, [.window(3), .window(4)]),
                       ])))
    }

    func testDuplicatedIdsAreUnreadable() {
        let slots = [rect(1, 0, 0, 100, 100), rect(1, 107, 0, 207, 100)]
        XCTAssertEqual(FrameTree.read(slots, rootAxis: .row, tolerance: 4), .unreadable)
    }

    func testEmptyIsUnreadable() {
        XCTAssertEqual(FrameTree.read([], rootAxis: .row, tolerance: 4), .unreadable)
    }

    func testLeavesFollowScreenOrder() {
        let tree = Tile.split(.row, [
            .window(1),
            .split(.column, [.window(2), .window(3)]),
            .window(4),
        ])
        XCTAssertEqual(tree.leaves, [1, 2, 3, 4])
        XCTAssertEqual(Tile.window(9).leaves, [9])
        XCTAssertTrue(Tile.window(9).isBinary)
        XCTAssertTrue(Tile.split(.row, [.window(1), .window(2)]).isBinary)
        XCTAssertFalse(tree.isBinary)
    }

    func testSixteenWindowsReadManyTimes() {
        let slots = (0..<16).map { rect($0 + 1, Double($0 * 100), 0, Double($0 * 100 + 90), 500) }
        for _ in 0..<10_000 {
            _ = FrameTree.read(slots, rootAxis: .row, tolerance: 4)
        }
    }
}
