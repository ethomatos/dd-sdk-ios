/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import XCTest
@testable import Datadog

class DataUploadWorkerTests: XCTestCase {
    private let uploaderQueue = DispatchQueue(label: "dd-tests-uploader", target: .global(qos: .utility))

    lazy var dateProvider = RelativeDateProvider(advancingBySeconds: 1)
    lazy var orchestrator = FilesOrchestrator(
        directory: temporaryDirectory,
        performance: StoragePerformanceMock.writeEachObjectToNewFileAndReadAllFiles,
        dateProvider: dateProvider
    )
    lazy var writer = FileWriter(
        dataFormat: .mockWith(prefix: "[", suffix: "]"),
        orchestrator: orchestrator
    )
    lazy var reader = FileReader(
        dataFormat: .mockWith(prefix: "[", suffix: "]"),
        orchestrator: orchestrator
    )

    override func setUp() {
        super.setUp()
        temporaryDirectory.create()
    }

    override func tearDown() {
        temporaryDirectory.delete()
        super.tearDown()
    }

    // MARK: - Data Uploads

    func testItUploadsAllData() {
        let server = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200)))
        let dataUploader = DataUploader(
            httpClient: HTTPClient(session: server.getInterceptedURLSession()),
            requestBuilder: .mockAny()
        )

        // Given
        writer.write(value: ["k1": "v1"])
        writer.write(value: ["k2": "v2"])
        writer.write(value: ["k3": "v3"])

        // When
        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: dataUploader,
            uploadConditions: DataUploadConditions.alwaysUpload(),
            delay: DataUploadDelay(performance: UploadPerformanceMock.veryQuick),
            featureName: .mockAny()
        )

        // Then
        let recordedRequests = server.waitAndReturnRequests(count: 3)
        XCTAssertTrue(recordedRequests.contains { $0.httpBody == #"[{"k1":"v1"}]"#.utf8Data })
        XCTAssertTrue(recordedRequests.contains { $0.httpBody == #"[{"k2":"v2"}]"#.utf8Data })
        XCTAssertTrue(recordedRequests.contains { $0.httpBody == #"[{"k3":"v3"}]"#.utf8Data })

        worker.cancelSynchronously()

        XCTAssertEqual(try temporaryDirectory.files().count, 0)
    }

    func testGivenDataToUpload_whenUploadFinishesAndDoesNotNeedToBeRetried_thenDataIsDeleted() {
        let startUploadExpectation = self.expectation(description: "Upload has started")

        var mockDataUploader = DataUploaderMock(uploadStatus: .mockWith(needsRetry: false))
        mockDataUploader.onUpload = { startUploadExpectation.fulfill() }

        // Given
        writer.write(value: ["key": "value"])
        XCTAssertEqual(try temporaryDirectory.files().count, 1)

        // When
        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: mockDataUploader,
            uploadConditions: .alwaysUpload(),
            delay: DataUploadDelay(performance: UploadPerformanceMock.veryQuickInitialUpload),
            featureName: .mockAny()
        )

        wait(for: [startUploadExpectation], timeout: 0.5)
        worker.cancelSynchronously()

        // Then
        XCTAssertEqual(try temporaryDirectory.files().count, 0, "When upload finishes with `needsRetry: false`, data should be deleted")
    }

    func testGivenDataToUpload_whenUploadFinishesAndNeedsToBeRetried_thenDataIsPreserved() {
        let startUploadExpectation = self.expectation(description: "Upload has started")

        var mockDataUploader = DataUploaderMock(uploadStatus: .mockWith(needsRetry: true))
        mockDataUploader.onUpload = { startUploadExpectation.fulfill() }

        // Given
        writer.write(value: ["key": "value"])
        XCTAssertEqual(try temporaryDirectory.files().count, 1)

        // When
        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: mockDataUploader,
            uploadConditions: .alwaysUpload(),
            delay: DataUploadDelay(performance: UploadPerformanceMock.veryQuickInitialUpload),
            featureName: .mockAny()
        )

        wait(for: [startUploadExpectation], timeout: 0.5)
        worker.cancelSynchronously()

        // Then
        XCTAssertEqual(try temporaryDirectory.files().count, 1, "When upload finishes with `needsRetry: true`, data should be preserved")
    }

    // MARK: - Upload Interval Changes

    func testWhenThereIsNoBatch_thenIntervalIncreases() {
        let delayChangeExpectation = expectation(description: "Upload delay is increased")
        let mockDelay = MockDelay { command in
            if case .increase = command {
                delayChangeExpectation.fulfill()
            } else {
                XCTFail("Wrong command is sent!")
            }
        }

        // When
        XCTAssertEqual(try temporaryDirectory.files().count, 0)

        let server = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200)))
        let dataUploader = DataUploader(
            httpClient: HTTPClient(session: server.getInterceptedURLSession()),
            requestBuilder: .mockAny()
        )
        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: dataUploader,
            uploadConditions: DataUploadConditions.neverUpload(),
            delay: mockDelay,
            featureName: .mockAny()
        )

        // Then
        server.waitFor(requestsCompletion: 0)
        waitForExpectations(timeout: 1, handler: nil)
        worker.cancelSynchronously()
    }

    func testWhenBatchFails_thenIntervalIncreases() {
        let delayChangeExpectation = expectation(description: "Upload delay is increased")
        let mockDelay = MockDelay { command in
            if case .increase = command {
                delayChangeExpectation.fulfill()
            } else {
                XCTFail("Wrong command is sent!")
            }
        }

        // When
        writer.write(value: ["k1": "v1"])

        let server = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 500)))
        let dataUploader = DataUploader(
            httpClient: HTTPClient(session: server.getInterceptedURLSession()),
            requestBuilder: .mockAny()
        )
        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: dataUploader,
            uploadConditions: DataUploadConditions.alwaysUpload(),
            delay: mockDelay,
            featureName: .mockAny()
        )

        // Then
        server.waitFor(requestsCompletion: 1)
        waitForExpectations(timeout: 1, handler: nil)
        worker.cancelSynchronously()
    }

    func testWhenBatchSucceeds_thenIntervalDecreases() {
        let delayChangeExpectation = expectation(description: "Upload delay is decreased")
        let mockDelay = MockDelay { command in
            if case .decrease = command {
                delayChangeExpectation.fulfill()
            } else {
                XCTFail("Wrong command is sent!")
            }
        }

        // When
        writer.write(value: ["k1": "v1"])

        let server = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200)))
        let dataUploader = DataUploader(
            httpClient: HTTPClient(session: server.getInterceptedURLSession()),
            requestBuilder: .mockAny()
        )
        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: dataUploader,
            uploadConditions: DataUploadConditions.alwaysUpload(),
            delay: mockDelay,
            featureName: .mockAny()
        )

        // Then
        server.waitFor(requestsCompletion: 1)
        waitForExpectations(timeout: 2, handler: nil)
        worker.cancelSynchronously()
    }

    // MARK: - Notifying Upload Progress

    func testWhenDataIsBeingUploaded_itPrintsUploadProgressInformation() {
        let previousUserLogger = userLogger
        defer { userLogger = previousUserLogger }

        let mockUserLoggerOutput = LogOutputMock()
        userLogger = .mockWith(logOutput: mockUserLoggerOutput)

        // Given
        writer.write(value: ["key": "value"])

        let randomUploadStatus: DataUploadStatus = .mockRandom()
        let randomFeatureName: String = .mockRandom()

        // When
        let startUploadExpectation = self.expectation(description: "Upload has started")
        var mockDataUploader = DataUploaderMock(uploadStatus: randomUploadStatus)
        mockDataUploader.onUpload = { startUploadExpectation.fulfill() }

        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: mockDataUploader,
            uploadConditions: .alwaysUpload(),
            delay: DataUploadDelay(performance: UploadPerformanceMock.veryQuickInitialUpload),
            featureName: randomFeatureName
        )

        wait(for: [startUploadExpectation], timeout: 0.5)
        worker.cancelSynchronously()

        // Then
        let expectedSummary = randomUploadStatus.needsRetry ? "not delivered, will be retransmitted" : "accepted, won't be retransmitted"
        XCTAssertEqual(mockUserLoggerOutput.allRecordedLogs.count, 2)

        XCTAssertEqual(
            mockUserLoggerOutput.allRecordedLogs[0].message,
            "⏳ (\(randomFeatureName)) Uploading batch...",
            "Batch start information should be printed to `userLogger`. All captured logs:\n\(mockUserLoggerOutput.dumpAllRecordedLogs())"
        )

        XCTAssertEqual(
            mockUserLoggerOutput.allRecordedLogs[1].message,
            "   → (\(randomFeatureName)) \(expectedSummary): \(randomUploadStatus.userDebugDescription)",
            "Batch completion information should be printed to `userLogger`. All captured logs:\n\(mockUserLoggerOutput.dumpAllRecordedLogs())"
        )
    }

    func testWhenDataIsBeingUploaded_itPrintsUnauthoriseMessage_toUserLogger() {
        let previousUserLogger = userLogger
        defer { userLogger = previousUserLogger }

        let mockUserLoggerOutput = LogOutputMock()
        userLogger = .mockWith(logOutput: mockUserLoggerOutput)

        // Given
        writer.write(value: ["key": "value"])

        let randomUploadStatus: DataUploadStatus = .mockWith(error: .unauthorized)

        // When
        let startUploadExpectation = self.expectation(description: "Upload has started")
        var mockDataUploader = DataUploaderMock(uploadStatus: randomUploadStatus)
        mockDataUploader.onUpload = { startUploadExpectation.fulfill() }

        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: mockDataUploader,
            uploadConditions: .alwaysUpload(),
            delay: DataUploadDelay(performance: UploadPerformanceMock.veryQuickInitialUpload),
            featureName: .mockRandom()
        )

        wait(for: [startUploadExpectation], timeout: 0.5)
        worker.cancelSynchronously()

        // Then
        XCTAssertEqual(mockUserLoggerOutput.allRecordedLogs.count, 3)

        XCTAssertEqual(
            mockUserLoggerOutput.allRecordedLogs[2].message,
            "⚠️ The client token you provided seems to be invalid.",
            "An error should be printed to `userLogger`. All captured logs:\n\(mockUserLoggerOutput.dumpAllRecordedLogs())"
        )
    }

    func testWhenDataIsBeingUploaded_itPrintsHTTPErrorMessage_toTelemetry() {
        // Given
        let mockTelemetry = TelemetryMock()

        writer.write(value: ["key": "value"])
        let randomUploadStatus: DataUploadStatus = .mockWith(error: .httpError(statusCode: 500))

        // When
        let startUploadExpectation = self.expectation(description: "Upload has started")
        var mockDataUploader = DataUploaderMock(uploadStatus: randomUploadStatus)
        mockDataUploader.onUpload = { startUploadExpectation.fulfill() }

        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: mockDataUploader,
            uploadConditions: .alwaysUpload(),
            delay: DataUploadDelay(performance: UploadPerformanceMock.veryQuickInitialUpload),
            featureName: .mockRandom(),
            telemetry: mockTelemetry
        )

        wait(for: [startUploadExpectation], timeout: 0.5)
        worker.cancelSynchronously()

        // Then
        XCTAssertEqual(mockTelemetry.errors.count, 1)

        XCTAssertEqual(
            mockTelemetry.errors.first?.message,
            "Data upload finished with status code: 500",
            "An error should be send to internal telemetry. \(mockTelemetry)"
        )
    }

    func testWhenDataIsBeingUploaded_itPrintsNetworkErrorMessage_toTelemetry() {
        // Given
        let mockTelemetry = TelemetryMock()

        writer.write(value: ["key": "value"])
        let randomUploadStatus: DataUploadStatus = .mockWith(error: .networkError(error: .mockAny()))

        // When
        let startUploadExpectation = self.expectation(description: "Upload has started")
        var mockDataUploader = DataUploaderMock(uploadStatus: randomUploadStatus)
        mockDataUploader.onUpload = { startUploadExpectation.fulfill() }

        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: mockDataUploader,
            uploadConditions: .alwaysUpload(),
            delay: DataUploadDelay(performance: UploadPerformanceMock.veryQuickInitialUpload),
            featureName: .mockRandom(),
            telemetry: mockTelemetry
        )

        wait(for: [startUploadExpectation], timeout: 0.5)
        worker.cancelSynchronously()

        // Then
        XCTAssertEqual(mockTelemetry.errors.count, 1)

        XCTAssertEqual(
            mockTelemetry.errors.first?.message,
            #"Data upload finished with error - Error Domain=abc Code=0 "(null)""#,
            "An error should be send to internal telemetry. \(mockTelemetry)"
        )
    }

    // MARK: - Tearing Down

    func testWhenCancelled_itPerformsNoMoreUploads() {
        // Given
        let server = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200)))
        let dataUploader = DataUploader(
            httpClient: HTTPClient(session: server.getInterceptedURLSession()),
            requestBuilder: .mockAny()
        )
        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: dataUploader,
            uploadConditions: DataUploadConditions.neverUpload(),
            delay: MockDelay(),
            featureName: .mockAny()
        )

        // When
        worker.cancelSynchronously()

        // Then
        writer.write(value: ["k1": "v1"])

        server.waitFor(requestsCompletion: 0)
    }

    func testItFlushesAllData() {
        let server = ServerMock(delivery: .success(response: .mockResponseWith(statusCode: 200)))
        let dataUploader = DataUploader(
            httpClient: HTTPClient(session: server.getInterceptedURLSession()),
            requestBuilder: .mockAny()
        )
        let worker = DataUploadWorker(
            queue: uploaderQueue,
            fileReader: reader,
            dataUploader: dataUploader,
            uploadConditions: DataUploadConditions.alwaysUpload(),
            delay: DataUploadDelay(performance: UploadPerformanceMock.veryQuick),
            featureName: .mockAny()
        )

        // Given
        writer.write(value: ["k1": "v1"])
        writer.write(value: ["k2": "v2"])
        writer.write(value: ["k3": "v3"])

        // When
        worker.flushSynchronously()

        // Then
        XCTAssertEqual(try temporaryDirectory.files().count, 0)

        let recordedRequests = server.waitAndReturnRequests(count: 3)
        XCTAssertTrue(recordedRequests.contains { $0.httpBody == #"[{"k1":"v1"}]"#.utf8Data })
        XCTAssertTrue(recordedRequests.contains { $0.httpBody == #"[{"k2":"v2"}]"#.utf8Data })
        XCTAssertTrue(recordedRequests.contains { $0.httpBody == #"[{"k3":"v3"}]"#.utf8Data })

        worker.cancelSynchronously()
    }
}

struct MockDelay: Delay {
    enum Command {
        case increase, decrease
    }

    var callback: ((Command) -> Void)?
    let current: TimeInterval = 0.1

    mutating func decrease() {
        callback?(.decrease)
        callback = nil
    }
    mutating func increase() {
        callback?(.increase)
        callback = nil
    }
}

private extension DataUploadConditions {
    static func alwaysUpload() -> DataUploadConditions {
        return DataUploadConditions(
            batteryStatus: BatteryStatusProviderMock.mockWith(
                status: BatteryStatus(state: .full, level: 100, isLowPowerModeEnabled: false) // always upload
            ),
            networkConnectionInfo: NetworkConnectionInfoProviderMock(
                networkConnectionInfo: NetworkConnectionInfo(
                    reachability: .yes, // always upload
                    availableInterfaces: [.wifi],
                    supportsIPv4: true,
                    supportsIPv6: true,
                    isExpensive: false,
                    isConstrained: false
                )
            )
        )
    }

    static func neverUpload() -> DataUploadConditions {
        return DataUploadConditions(
            batteryStatus: BatteryStatusProviderMock.mockWith(
                status: BatteryStatus(state: .unplugged, level: 0, isLowPowerModeEnabled: true) // never upload
            ),
            networkConnectionInfo: NetworkConnectionInfoProviderMock(
                networkConnectionInfo: NetworkConnectionInfo(
                    reachability: .no, // never upload
                    availableInterfaces: [.cellular],
                    supportsIPv4: true,
                    supportsIPv6: false,
                    isExpensive: true,
                    isConstrained: true
                )
            )
        )
    }
}
