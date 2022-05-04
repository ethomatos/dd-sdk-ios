/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import HTTPServerMock
import XCTest

private extension ExampleApplication {
    func tapNoOpButton() {
        buttons["No-op Button"].tap()
    }

    func tapShowUITableView() {
        buttons["Show UITableView"].tap()
    }

    func tapTableViewItem(atIndex index: Int) {
        tables.staticTexts["Item \(index)"].tap()
    }

    func tapShowUICollectionView() {
        buttons["Show UICollectionView"].tap()
    }

    func tapCollectionViewItem(atIndex index: Int) {
        collectionViews.staticTexts["Item \(index)"].tap()
    }

    func tapShowVariousUIControls() {
        buttons["Show various UIControls"].tap()
    }

    func tapTextField() {
        tables.cells
            .containing(.staticText, identifier: "UITextField")
            .children(matching: .textField).element
            .tap()
    }

    func enterTextUsingKeyboard(_ text: String) {
        // NOTE: RUMM-740 iOS 13 Swipe typing feature presents its onboarding
        // That blocks the keyboard with a Continue button
        // it must be tapped first to get the real keyboard
        let swipeTypingContinueButton = buttons["Continue"]
        if swipeTypingContinueButton.exists {
            swipeTypingContinueButton.tap()
        }
        text.forEach { letter in
            keys[String(letter)].tap()
        }
    }

    func dismissKeyboard() {
        // tap in the middle of the screen
        coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
            .tap()
    }

    func tapStepperPlusButton() {
        tables.buttons["Increment"].tap()
    }

    func moveSlider(to position: CGFloat) {
        tables.sliders["50%"].adjust(toNormalizedSliderPosition: position)
    }

    func tapSegmentedControlSegment(label: String) {
        tables.buttons[label].tap()
    }

    func tapNavigationBarButton(named barButtonIdentifier: String) {
        navigationBars["Example.RUMTASVariousUIControllsView"]
            .buttons[barButtonIdentifier]
            .tap()
    }
}

class RUMTapActionScenarioTests: IntegrationTests, RUMCommonAsserts {
    func testRUMTapActionScenario() throws {
        // Server session recording RUM events send to `HTTPServerMock`.
        let rumServerSession = server.obtainUniqueRecordingSession()

        let app = ExampleApplication()
        app.launchWith(
            testScenarioClassName: "RUMTapActionScenario",
            serverConfiguration: HTTPServerMockConfiguration(
                rumEndpoint: rumServerSession.recordingURL
            )
        )

        app.tapNoOpButton()
        app.tapShowUITableView()
        app.tapTableViewItem(atIndex: 4)
        app.tapShowUICollectionView()
        app.tapCollectionViewItem(atIndex: 14)
        app.tapShowVariousUIControls()
        app.tapTextField()
        app.enterTextUsingKeyboard("foo")
        app.dismissKeyboard()
        app.tapStepperPlusButton()
        app.moveSlider(to: 0.25)
        app.tapSegmentedControlSegment(label: "B")
        app.tapNavigationBarButton(named: "Search")
        app.tapNavigationBarButton(named: "Share")
        app.tapNavigationBarButton(named: "Back")

        try app.endRUMSession()

        // Get RUM Sessions with expected number of View visits
        let recordedRUMRequests = try rumServerSession.pullRecordedRequests(timeout: dataDeliveryTimeout) { requests in
            try RUMSessionMatcher.singleSession(from: requests)?.hasEnded() ?? false
        }

        assertRUM(requests: recordedRUMRequests)

        let session = try XCTUnwrap(RUMSessionMatcher.singleSession(from: recordedRUMRequests))
        sendCIAppLog(session)

        XCTAssertEqual(session.viewVisits[0].name, "MenuView")
        XCTAssertEqual(session.viewVisits[0].path, "Example.RUMTASScreen1ViewController")
        XCTAssertEqual(session.viewVisits[0].actionEvents.count, 3)
        XCTAssertEqual(session.viewVisits[0].actionEvents[0].action.type, .applicationStart)
        XCTAssertGreaterThan(session.viewVisits[0].actionEvents[0].action.loadingTime!, 0)
        XCTAssertEqual(session.viewVisits[0].actionEvents[1].action.target?.name, "UIButton")
        XCTAssertEqual(session.viewVisits[0].actionEvents[2].action.target?.name, "UIButton(Show UITableView)")

        XCTAssertEqual(session.viewVisits[1].name, "TableView")
        XCTAssertEqual(session.viewVisits[1].path, "Example.RUMTASTableViewController")
        XCTAssertEqual(session.viewVisits[1].actionEvents.count, 1)
        XCTAssertEqual(
            session.viewVisits[1].actionEvents[0].action.target?.name,
            "UITableViewCell(Item 4)"
        )

        XCTAssertEqual(session.viewVisits[2].name, "MenuView")
        XCTAssertEqual(session.viewVisits[2].path, "Example.RUMTASScreen1ViewController")
        XCTAssertEqual(session.viewVisits[2].actionEvents.count, 1)
        XCTAssertEqual(session.viewVisits[2].actionEvents[0].action.target?.name, "UIButton(Show UICollectionView)")

        XCTAssertEqual(session.viewVisits[3].name, "CollectionView")
        XCTAssertEqual(session.viewVisits[3].path, "Example.RUMTASCollectionViewController")
        XCTAssertEqual(session.viewVisits[3].actionEvents.count, 1)
        XCTAssertEqual(
            session.viewVisits[3].actionEvents[0].action.target?.name,
            "Example.RUMTASCollectionViewCell(Item 14)"
        )

        XCTAssertEqual(session.viewVisits[4].name, "MenuView")
        XCTAssertEqual(session.viewVisits[4].path, "Example.RUMTASScreen1ViewController")
        XCTAssertEqual(session.viewVisits[4].actionEvents.count, 1)
        XCTAssertEqual(session.viewVisits[4].actionEvents[0].action.target?.name, "UIButton(Show various UIControls)")

        XCTAssertEqual(session.viewVisits[5].name, "UIControlsView")
        XCTAssertEqual(session.viewVisits[5].path, "Example.RUMTASVariousUIControllsViewController")
        XCTAssertEqual(session.viewVisits[5].actionEvents.count, 7)
        let targetNames = session.viewVisits[5].actionEvents.compactMap { $0.action.target?.name }
        XCTAssertEqual(targetNames[0], "UITextField")
        XCTAssertEqual(targetNames[1], "UIStepper")
        XCTAssertEqual(targetNames[2], "UISlider")
        XCTAssertEqual(targetNames[3], "UISegmentedControl")
        XCTAssertEqual(targetNames[4], "_UIButtonBarButton(Search)")
        XCTAssertEqual(targetNames[5], "_UIButtonBarButton(Share)")
        XCTAssert(targetNames[6].contains("_UIButtonBarButton"), "Target name should be either _UIButtonBarButton (iOS 13) or _UIButtonBarButton(BackButton) (iOS 14)") // back button

        XCTAssertEqual(session.viewVisits[6].name, "MenuView")
        XCTAssertEqual(session.viewVisits[6].path, "Example.RUMTASScreen1ViewController")
        XCTAssertEqual(session.viewVisits[6].actionEvents.count, 0)
    }
}
