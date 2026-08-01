import Foundation
import XCTest
@testable import QuickPi

final class PanelSizingTests: XCTestCase {
    func testResultPanelRetainsMinimumVisibleContentHeight() {
        let constraints = panelHeightConstraints(
            inputHeight: 154,
            slashCommandMenuHeight: 0,
            showsResultPanel: true,
            resultContentHeight: 20,
            maximumHeight: 900
        )

        XCTAssertEqual(constraints.minimum, 395)
        XCTAssertEqual(constraints.target, 395)
    }

    func testResultPanelUsesRequestedHeightAboveMinimum() {
        let constraints = panelHeightConstraints(
            inputHeight: 154,
            slashCommandMenuHeight: 0,
            showsResultPanel: true,
            resultContentHeight: 520,
            maximumHeight: 900
        )

        XCTAssertEqual(constraints.minimum, 395)
        XCTAssertEqual(constraints.target, 674)
    }

    func testCommandMenuAndCompactPanelUseTheirOwnMinimumHeights() {
        let commandConstraints = panelHeightConstraints(
            inputHeight: 154,
            slashCommandMenuHeight: 185,
            showsResultPanel: true,
            resultContentHeight: 520,
            maximumHeight: 900
        )
        let compactConstraints = panelHeightConstraints(
            inputHeight: 154,
            slashCommandMenuHeight: 0,
            showsResultPanel: false,
            resultContentHeight: 520,
            maximumHeight: 900
        )

        XCTAssertEqual(commandConstraints.minimum, 339)
        XCTAssertEqual(commandConstraints.target, 339)
        XCTAssertEqual(compactConstraints.minimum, 154)
        XCTAssertEqual(compactConstraints.target, 154)
    }

    func testPanelHeightIsCappedByAvailableScreenHeight() {
        let constraints = panelHeightConstraints(
            inputHeight: 154,
            slashCommandMenuHeight: 0,
            showsResultPanel: true,
            resultContentHeight: 520,
            maximumHeight: 300
        )

        XCTAssertEqual(constraints.minimum, 300)
        XCTAssertEqual(constraints.target, 300)
    }
}
