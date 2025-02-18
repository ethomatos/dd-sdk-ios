/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
@testable import Datadog

class RUMUserActionScopeTests: XCTestCase {
    private let output = RUMEventOutputMock()
    private let randomServiceName: String = .mockRandom()
    private lazy var dependencies: RUMScopeDependencies = .mockWith(
        serviceName: randomServiceName,
        eventOutput: output
    )
    private let parent = RUMContextProviderMock(
        context: .mockWith(
            rumApplicationID: "rum-123",
            sessionID: .mockRandom(),
            activeViewID: .mockRandom(),
            activeViewPath: "FooViewController",
            activeViewName: "FooViewName",
            activeUserActionID: .mockRandom()
        )
    )

    func testDefaultContext() {
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .swipe,
            attributes: [:],
            startTime: .mockAny(),
            dateCorrection: .zero,
            isContinuous: .mockAny()
        )

        XCTAssertEqual(scope.context.rumApplicationID, parent.context.rumApplicationID)
        XCTAssertEqual(scope.context.sessionID, parent.context.sessionID)
        XCTAssertEqual(scope.context.activeViewID, try XCTUnwrap(parent.context.activeViewID))
        XCTAssertEqual(scope.context.activeViewPath, try XCTUnwrap(parent.context.activeViewPath))
        XCTAssertEqual(scope.context.activeUserActionID, try XCTUnwrap(parent.context.activeUserActionID))
    }

    func testGivenActiveUserAction_whenViewIsStopped_itSendsUserActionEvent() throws {
        let scope = RUMViewScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            identity: mockView,
            attributes: [:],
            startTime: Date()
        )
        XCTAssertTrue(scope.process(command: RUMStartViewCommand.mockWith(identity: mockView)))
        let mockUserActionCmd = RUMAddUserActionCommand.mockAny()
        XCTAssertTrue(scope.process(command: mockUserActionCmd))
        XCTAssertFalse(scope.process(command: RUMStopViewCommand.mockWith(identity: mockView)))

        let recordedActionEvents = try output.recordedEvents(ofType: RUMActionEvent.self)
        XCTAssertEqual(recordedActionEvents.count, 1)
        let recordedAction = try XCTUnwrap(recordedActionEvents.last)
        XCTAssertEqual(recordedAction.action.type.rawValue, String(describing: mockUserActionCmd.actionType))
        XCTAssertEqual(recordedAction.dd.session?.plan, .plan1, "All RUM events should use RUM Lite plan")
        XCTAssertEqual(recordedAction.source, .ios)
        XCTAssertEqual(recordedAction.service, randomServiceName)
    }

    func testGivenCustomSource_whenActionIsSent_itSendsCustomSource() throws {
        let customSource = String.mockAnySource()
        let scope = RUMViewScope.mockWith(
            parent: parent,
            dependencies: dependencies.replacing(
                source: customSource
            ),
            identity: mockView,
            attributes: [:],
            startTime: Date()
        )
        XCTAssertTrue(scope.process(command: RUMStartViewCommand.mockWith(identity: mockView)))
        let mockUserActionCmd = RUMAddUserActionCommand.mockAny()
        XCTAssertTrue(scope.process(command: mockUserActionCmd))
        XCTAssertFalse(scope.process(command: RUMStopViewCommand.mockWith(identity: mockView)))

        let recordedActionEvents = try output.recordedEvents(ofType: RUMActionEvent.self)
        let recordedAction = try XCTUnwrap(recordedActionEvents.last)
        XCTAssertEqual(recordedAction.source, RUMActionEvent.Source(rawValue: customSource))
    }

    // MARK: - Continuous User Action

    func testWhenContinuousUserActionEnds_itSendsActionEvent() throws {
        var currentTime: Date = .mockDecember15th2019At10AMUTC()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .swipe,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: true
        )

        currentTime.addTimeInterval(1)

        XCTAssertFalse(
            scope.process(
                command: RUMStopUserActionCommand(
                    time: currentTime,
                    attributes: ["foo": "bar"],
                    actionType: .swipe,
                    name: nil
                )
            )
        )

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).first)
        XCTAssertEqual(event.date, Date.mockDecember15th2019At10AMUTC().timeIntervalSince1970.toInt64Milliseconds)
        XCTAssertEqual(event.application.id, scope.context.rumApplicationID)
        XCTAssertEqual(event.session.id, scope.context.sessionID.toRUMDataFormat)
        XCTAssertEqual(event.session.type, .user)
        XCTAssertEqual(event.view.id, parent.context.activeViewID?.toRUMDataFormat)
        XCTAssertEqual(event.view.url, "FooViewController")
        XCTAssertEqual(event.view.name, "FooViewName")
        XCTAssertEqual(event.action.id, scope.actionUUID.toRUMDataFormat)
        XCTAssertEqual(event.action.type, .swipe)
        XCTAssertEqual(event.action.loadingTime, 1_000_000_000)
        XCTAssertEqual(event.action.resource?.count, 0)
        XCTAssertEqual(event.action.error?.count, 0)
        XCTAssertEqual(event.context?.contextInfo as? [String: String], ["foo": "bar"])
        XCTAssertEqual(event.source, .ios)
        XCTAssertEqual(event.service, randomServiceName)
    }

    func testWhenContinuousUserActionExpires_itSendsActionEvent() throws {
        var currentTime: Date = .mockDecember15th2019At10AMUTC()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .swipe,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: true
        )

        let expirationInterval = RUMUserActionScope.Constants.continuousActionMaxDuration

        currentTime = .mockDecember15th2019At10AMUTC(addingTimeInterval: expirationInterval * 0.5)
        XCTAssertTrue(scope.process(command: RUMCommandMock(time: currentTime)), "Continuous User Action should not expire after \(expirationInterval * 0.5)s")

        currentTime = .mockDecember15th2019At10AMUTC(addingTimeInterval: expirationInterval * 2.0)
        XCTAssertFalse(scope.process(command: RUMCommandMock(time: currentTime)), "Continuous User Action should expire after \(expirationInterval)s")

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).first)
        XCTAssertEqual(event.action.loadingTime, 10_000_000_000, "Loading time should not exceed expirationInterval")
    }

    func testWhileContinuousUserActionIsActive_itTracksCompletedResources() throws {
        var currentTime: Date = .mockDecember15th2019At10AMUTC()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .scroll,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: true
        )

        currentTime.addTimeInterval(0.5)

        XCTAssertTrue(
            scope.process(
                command: RUMStartResourceCommand.mockWith(resourceKey: "/resource/1", time: currentTime)
            )
        )

        XCTAssertTrue(
            scope.process(
                command: RUMStartResourceCommand.mockWith(resourceKey: "/resource/2", time: currentTime)
            )
        )

        currentTime.addTimeInterval(0.5)

        XCTAssertTrue(
            scope.process(
                command: RUMStopResourceCommand.mockWith(resourceKey: "/resource/1", time: currentTime)
            )
        )

        XCTAssertTrue(
            scope.process(
                command: RUMStopResourceWithErrorCommand.mockWithErrorObject(resourceKey: "/resource/2", time: currentTime)
            )
        )

        XCTAssertFalse(
            scope.process(
                command: RUMStopUserActionCommand.mockWith(time: currentTime, actionType: .scroll)
            )
        )

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).last)
        XCTAssertEqual(event.action.resource?.count, 1, "User Action should track first successful Resource")
        XCTAssertEqual(event.action.error?.count, 1, "User Action should track second Resource failure as Error")
    }

    func testWhileContinuousUserActionIsActive_itCountsViewErrors() throws {
        var currentTime = Date()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .scroll,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: true
        )

        currentTime.addTimeInterval(0.5)

        XCTAssertTrue(
            scope.process(
                command: RUMAddCurrentViewErrorCommand.mockWithErrorMessage(time: currentTime)
            )
        )

        currentTime.addTimeInterval(1)

        XCTAssertFalse(
            scope.process(
                command: RUMStopUserActionCommand.mockWith(time: currentTime, actionType: .scroll)
            )
        )

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).last)
        XCTAssertEqual(event.action.error?.count, 1)
    }

    func testWhenContinuousUserActionStopsWithName_itChangesItsName() throws {
        var currentTime = Date()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .scroll,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: true
        )

        currentTime.addTimeInterval(0.5)

        XCTAssertTrue(scope.process(command: RUMCommandMock()))

        currentTime.addTimeInterval(1)
        let differentName = String.mockRandom()
        XCTAssertFalse(
            scope.process(
                command: RUMStopUserActionCommand.mockWith(time: currentTime, actionType: .scroll, name: differentName)
            )
        )

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).last)
        XCTAssertEqual(event.action.target?.name, differentName)
    }

    // MARK: - Discrete User Action

    func testWhenDiscreteUserActionTimesOut_itSendsActionEvent() throws {
        var currentTime: Date = .mockDecember15th2019At10AMUTC()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .swipe,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: false
        )

        let timeOutInterval = RUMUserActionScope.Constants.discreteActionTimeoutDuration

        currentTime = .mockDecember15th2019At10AMUTC(addingTimeInterval: timeOutInterval * 0.5)
        XCTAssertTrue(scope.process(command: RUMCommandMock(time: currentTime)), "Discrete User Action should not time out after \(timeOutInterval * 0.5)s")

        currentTime.addTimeInterval(timeOutInterval)
        XCTAssertFalse(scope.process(command: RUMCommandMock(time: currentTime)), "Discrete User Action should time out after \(timeOutInterval)s")

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).first)
        let nanosecondsInSecond: Double = 1_000_000_000
        let actionLoadingTimeInSeconds = Double(try XCTUnwrap(event.action.loadingTime)) / nanosecondsInSecond
        XCTAssertEqual(actionLoadingTimeInSeconds, RUMUserActionScope.Constants.discreteActionTimeoutDuration, accuracy: 0.1)
    }

    func testWhileDiscreteUserActionIsActive_itDoesNotComplete_untilAllTrackedResourcesAreCompleted() throws {
        var currentTime: Date = .mockDecember15th2019At10AMUTC()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .scroll,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: false
        )

        currentTime.addTimeInterval(0.05)

        XCTAssertTrue(
            scope.process(
                command: RUMStartResourceCommand.mockWith(resourceKey: "/resource/1", time: currentTime)
            )
        )

        XCTAssertTrue(
            scope.process(
                command: RUMStartResourceCommand.mockWith(resourceKey: "/resource/2", time: currentTime)
            )
        )

        currentTime.addTimeInterval(RUMUserActionScope.Constants.discreteActionTimeoutDuration)

        XCTAssertTrue(
            scope.process(
                command: RUMStopResourceCommand.mockWith(resourceKey: "/resource/1", time: currentTime)
            ),
            "Discrete User Action should not yet complete as it still has 1 pending Resource"
        )

        XCTAssertTrue(
            scope.process(
                command: RUMStopResourceWithErrorCommand.mockWithErrorObject(resourceKey: "/resource/2", time: currentTime)
            ),
            "Discrete User Action should not yet complete as it haven't reached the time out duration"
        )

        currentTime.addTimeInterval(RUMUserActionScope.Constants.discreteActionTimeoutDuration)

        XCTAssertFalse(
            scope.process(command: RUMCommandMock(time: currentTime)),
            "Discrete User Action should complete as it has no more pending Resources and it reached the timeout duration"
        )

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).last)
        XCTAssertEqual(event.action.resource?.count, 1, "User Action should track first successful Resource")
        XCTAssertEqual(event.action.error?.count, 1, "User Action should track second Resource failure as Error")
    }

    func testWhileDiscreteUserActionIsActive_itCountsViewErrors() throws {
        var currentTime = Date()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .scroll,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: false
        )

        currentTime.addTimeInterval(0.05)

        XCTAssertTrue(
            scope.process(
                command: RUMAddCurrentViewErrorCommand.mockWithErrorMessage(time: currentTime)
            )
        )

        currentTime.addTimeInterval(RUMUserActionScope.Constants.discreteActionTimeoutDuration)

        XCTAssertFalse(
            scope.process(command: RUMCommandMock(time: currentTime)),
            "Discrete User Action should complete as it reached the timeout duration"
        )

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).last)
        XCTAssertEqual(event.action.error?.count, 1)
    }

    // MARK: - Long task actions

    func testWhileDiscreteUserActionIsActive_itCountsLongTasks() throws {
        var currentTime = Date()
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .scroll,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: false
        )

        currentTime.addTimeInterval(0.05)

        XCTAssertTrue(
            scope.process(
                command: RUMAddLongTaskCommand(time: currentTime, attributes: [:], duration: 1.0)
            )
        )

        currentTime.addTimeInterval(RUMUserActionScope.Constants.discreteActionTimeoutDuration)

        XCTAssertFalse(
            scope.process(command: RUMCommandMock(time: currentTime)),
            "Discrete User Action should complete as it reached the timeout duration"
        )

        let event = try XCTUnwrap(output.recordedEvents(ofType: RUMActionEvent.self).last)
        XCTAssertEqual(event.action.longTask?.count, 1)
    }

    // MARK: - Events sending callbacks

    func testGivenUserActionScopeWithEventSentCallback_whenSuccessfullySendingEvent_thenCallbackIsCalled() throws {
        let currentTime: Date = .mockDecember15th2019At10AMUTC()
        var callbackCalled = false
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .tap,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: false,
            onActionEventSent: {
                callbackCalled = true
            }
        )

        XCTAssertFalse(
            scope.process(
                command: RUMStopUserActionCommand(
                    time: currentTime,
                    attributes: ["foo": "bar"],
                    actionType: .tap,
                    name: nil
                )
            )
        )

        XCTAssertNotNil(try output.recordedEvents(ofType: RUMActionEvent.self).first)
        XCTAssertTrue(callbackCalled)
    }

    func testGivenUserActionScopeWithEventSentCallback_whenBypassingSendingEvent_thenCallbackIsNotCalled() {
        // swiftlint:disable trailing_closure
        let eventBuilder = RUMEventBuilder(
            eventsMapper: .mockWith(
                actionEventMapper: { event in
                    nil
                }
            )
        )
        let dependencies: RUMScopeDependencies = .mockWith(eventBuilder: eventBuilder, eventOutput: output)

        let currentTime: Date = .mockDecember15th2019At10AMUTC()
        var callbackCalled = false
        let scope = RUMUserActionScope.mockWith(
            parent: parent,
            dependencies: dependencies,
            name: .mockAny(),
            actionType: .tap,
            attributes: [:],
            startTime: currentTime,
            dateCorrection: .zero,
            isContinuous: false,
            onActionEventSent: {
                callbackCalled = true
            }
        )
        // swiftlint:enable trailing_closure

        XCTAssertFalse(
            scope.process(
                command: RUMStopUserActionCommand(
                    time: currentTime,
                    attributes: ["foo": "bar"],
                    actionType: .tap,
                    name: nil
                )
            )
        )

        XCTAssertNil(try output.recordedEvents(ofType: RUMActionEvent.self).first)
        XCTAssertFalse(callbackCalled)
    }
}
