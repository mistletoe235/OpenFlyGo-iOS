import XCTest
@testable import DJIVLNiOS

@MainActor
final class PhoneCaptureRetentionTests: XCTestCase {
    func testFrameWriteBudgetBoundsFloodAndReleasesEachLeaseOnce() throws {
        let budget = SurveyFrameWriteBudget()
        let first = try XCTUnwrap(budget.tryAcquire())
        let second = try XCTUnwrap(budget.tryAcquire())
        for _ in 0..<100_000 { XCTAssertNil(budget.tryAcquire()) }
        XCTAssertEqual(budget.pendingCount, 2)
        first.release()
        first.release()
        XCTAssertEqual(budget.pendingCount, 1)
        let next = try XCTUnwrap(budget.tryAcquire())
        XCTAssertNil(budget.tryAcquire())
        second.release()
        next.release()
        XCTAssertEqual(budget.pendingCount, 0)
    }

    func testSlowImageWriterRejectsFloodBeforeQueueingAndRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "openfly.test.slow-frame-writer")
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        let store = SessionCaptureStore(rootDirectory: root, queue: queue)
        let completed = expectation(description: "two accepted writes complete")
        completed.expectedFulfillmentCount = 2
        let rejected = expectation(description: "flood rejected without queueing")
        rejected.expectedFulfillmentCount = 1_000
        let frame = CameraFrame.simulator(sequence: 1)
        for _ in 0..<2 {
            store.captureSurveyFrame(frame: frame, missionID: "test", telemetry: FlightTelemetry(),
                retainLocally: false, metadata: { _, _ in Data("{}".utf8) }) { result in
                    switch result {
                    case .success(let urls):
                        try? FileManager.default.removeItem(at: urls.0.deletingLastPathComponent())
                    case .failure(let error): XCTFail("Unexpected write failure: \(error)")
                    }
                    completed.fulfill()
                }
        }
        for _ in 0..<1_000 {
            store.captureSurveyFrame(frame: frame, missionID: "test", telemetry: FlightTelemetry(),
                retainLocally: false, metadata: { _, _ in
                    XCTFail("Rejected work must not reach the encoder")
                    return Data()
                }) { result in
                    if case .success = result { XCTFail("Full writer accepted another frame") }
                    rejected.fulfill()
                }
        }
        XCTAssertEqual(store.pendingSurveyFrameWrites, 2)
        queue.resume()
        resumed = true
        await fulfillment(of: [completed, rejected], timeout: 10)
        XCTAssertEqual(store.pendingSurveyFrameWrites, 0)
        let recovered = expectation(description: "next write succeeds")
        store.captureSurveyFrame(frame: frame, missionID: "test", telemetry: FlightTelemetry(),
            retainLocally: false, metadata: { _, _ in Data("{}".utf8) }) { result in
                if case .success(let urls) = result {
                    try? FileManager.default.removeItem(at: urls.0.deletingLastPathComponent())
                } else { XCTFail("Writer did not recover") }
                recovered.fulfill()
            }
        await fulfillment(of: [recovered], timeout: 10)
        XCTAssertEqual(store.pendingSurveyFrameWrites, 0)
    }

    func testImageWriterErrorAlsoReturnsItsBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionCaptureStore(rootDirectory: root)
        let failed = expectation(description: "metadata error returns budget")
        store.captureSurveyFrame(frame: .simulator(sequence: 2), missionID: "test",
            telemetry: FlightTelemetry(), retainLocally: false,
            metadata: { _, _ in throw SurveyFrameWriteError.busy }) { result in
                if case .success = result { XCTFail("Injected metadata failure was ignored") }
                failed.fulfill()
            }
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertEqual(store.pendingSurveyFrameWrites, 0)
    }

    func testRuntimeWaitsForSaveCompletionAndMapReusesItsExecutionOverlay() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try String(contentsOf: root.appendingPathComponent("App/Survey/SurveyRuntimeController.swift"))
        let capture = try XCTUnwrap(runtime.components(separatedBy: "private func capturePostTriggerDownlinkFrame").last)
            .components(separatedBy: "private func pollVirtualFrameCapture")[0]
        XCTAssertTrue(capture.contains("defer { self.postTriggerFrameCapturesPending"))
        XCTAssertTrue(capture.contains("try await withCheckedThrowingContinuation"))
        let map = try String(contentsOf: root.appendingPathComponent("App/Views/SurveyPlannerView.swift"))
        XCTAssertTrue(map.contains("lastROI != roi || context.coordinator.lastMission != mission"))
        XCTAssertTrue(map.contains("if let existing = executionOverlay"))
        XCTAssertTrue(map.contains("overlay.update(start: aircraft, end: target"))
        XCTAssertTrue(map.contains("annotationsByKey"))
    }

    func testAppKeepsForegroundAwakeAndRestoresBackgroundIdleTimer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/DJIVLNiOSApp.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("UIApplication.shared.isIdleTimerDisabled = true"))
        XCTAssertTrue(source.contains("preventAutoLock(\"view appear\")"))
        XCTAssertTrue(source.contains("preventAutoLock(\"scene active\")"))
        XCTAssertTrue(source.contains("preventAutoLock(\"didBecomeActive\")"))
        XCTAssertTrue(source.contains("UIApplication.shared.isIdleTimerDisabled = false"))
        XCTAssertTrue(source.contains("model.enterBackground()"))
        XCTAssertTrue(source.contains("model.enterInactive()"))
    }

    private func temporaryRecord() async throws -> SurveyFrameCaptureRecord {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.positionSource = "DJI GPS"
        telemetry.flightStateTimestamp = now
        telemetry.aircraft = .init(latitude: 31, longitude: 121)
        telemetry.altitude = 30
        let log = EventLog()
        return try await withCheckedThrowingContinuation { continuation in
            log.captureSurveyFrame(frame: .simulator(sequence: 1, date: now),
                mission: ContinuousRecaptureFixture.mission(), reason: "test",
                telemetry: telemetry, executionLegIndex: 2, waypointIndex: 2,
                retainLocally: false) { continuation.resume(with: $0) }
        }
    }

    func testInstallationDefaultsDoNotRequestPhoneCopies() {
        XCTAssertFalse(OpenFlyBuildFeatures.saveSurveyFramesLocally)
        let controller = SurveyCloudUploadController(root: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString))
        XCTAssertFalse(controller.wantsLiveFrames)
    }

    func testTemporaryFrameCanBeQueuedAndDeletedWithoutLosingRetryData() async throws {
        let record = try await temporaryRecord()
        defer { record.removeTemporaryFiles() }
        XCTAssertTrue(record.isTemporary)
        XCTAssertTrue(record.imageURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.imageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.metadataURL.path))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SurveyUploadStore(root: root)
        try await store.begin(.init(endpoint: "https://upload.invalid", sessionID: "session_123",
            configuration: .init(name: "test", horizontalFOV: 70, takeoffASL: 25, minimumInterval: 2)))
        let queued = try await store.enqueue(file: record.imageURL,
            headers: SurveyUploadImage.liveHeaders(record, view: .localOblique),
            sessionID: "session_123", sourceID: "live:test")
        record.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.imageURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.metadataURL.path))
        let job = try XCTUnwrap(queued.jobs.first)
        let bytes = try await store.data(for: job, sessionID: "session_123")
        XCTAssertGreaterThan(bytes.count, 128)
        _ = try await store.acknowledge(job, sessionID: "session_123")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(job.filename).path))
    }

    func testRejectedFrameIsCleanedButRetainedCaptureIsNotDeleted() async throws {
        let record = try await temporaryRecord()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = SurveyCloudUploadController(root: root)
        controller.accept(record, view: .localOblique)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.imageURL.path))
        let retained = try await temporaryRecord()
        defer { retained.removeTemporaryFiles() }
        var protected = retained
        protected.isTemporary = false
        controller.accept(protected, view: .localOblique)
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.imageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.metadataURL.path))
    }
}
