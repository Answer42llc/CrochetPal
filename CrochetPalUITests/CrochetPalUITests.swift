import XCTest

final class CrochetPalUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testImportURLAndExecuteFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        app.buttons["addProject"].tap()
        let urlField = app.textFields["https://example.com/pattern"]
        XCTAssertTrue(urlField.waitForExistence(timeout: 2))
        urlField.tap()
        urlField.typeText("https://example.com/pattern")
        let importButton = app.buttons["Import URL"]
        importButton.tap()

        let importSheetDismissed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: importButton
        )
        wait(for: [importSheetDismissed], timeout: 10)

        let projectTitle = app.staticTexts["Mouse Cat Toy"]
        XCTAssertTrue(projectTitle.waitForExistence(timeout: 10))
        let projectCell = app.collectionViews.cells.element(boundBy: 0)
        projectCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["executeProject"].tap()

        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 2))
        app.buttons["Continue"].tap()
        app.buttons["Undo"].tap()
    }

    func testImportSampleImageFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        app.buttons["addProject"].tap()
        let sampleButton = app.buttons["Use Sample Image"]
        XCTAssertTrue(sampleButton.waitForExistence(timeout: 2))
        sampleButton.tap()

        let importSheetDismissed = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: sampleButton
        )
        wait(for: [importSheetDismissed], timeout: 10)
        XCTAssertTrue(app.staticTexts["Mouse Cat Toy"].waitForExistence(timeout: 10))
    }
}
