/*
* Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
* This product includes software developed at Datadog (https://www.datadoghq.com/).
* Copyright 2019-2020 Datadog, Inc.
*/

import XCTest

@testable import App

class CTProjectTests: XCTestCase {
    func testCallingLogicThatLoadsSDK() throws {
        let viewController = ViewController()
        viewController.viewDidLoad()
        XCTAssertNotNil(viewController.view)
    }
}
