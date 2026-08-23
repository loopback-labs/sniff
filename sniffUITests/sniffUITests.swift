//
//  sniffUITests.swift
//  sniffUITests
//
//  Created by Piyushh Bhutoria on 15/01/26.
//

import XCTest

final class sniffUITests: XCTestCase {

    override func setUpWithError() throws {
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
    }

    /// The only coverage of `AppCoordinator.init()` and `AppDelegate` — no unit test constructs
    /// either, so a crash on startup would otherwise pass every test in the suite.
    /// Reaching `runningBackground` counts: Sniff is LSUIElement, so it opens no window.
    @MainActor
    func testAppLaunchesWithoutCrashing() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launch()

        let didReachForeground = app.wait(for: .runningForeground, timeout: 10)
        let didReachBackground = app.wait(for: .runningBackground, timeout: 2)
        XCTAssertTrue(didReachForeground || didReachBackground)
    }
}
