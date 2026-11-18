import XCTest
@testable import RiskellWM

final class RiskellWMTests: XCTestCase {
    func testTargetIsWired() {
        XCTAssertTrue(RiskellWM.ready)
    }
}
