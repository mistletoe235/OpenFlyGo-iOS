import XCTest
@testable import DJIVLNiOS

@MainActor
final class PhoneCaptureRetentionTests: XCTestCase {
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
