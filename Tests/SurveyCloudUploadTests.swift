import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import DJIVLNiOS

final class SurveyCloudUploadTests: XCTestCase {
    func testConfiguredLiveServiceSessionAndPreview() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let endpoint = environment["OPENFLYSCAN_LIVE_ENDPOINT"],
              let token = environment["OPENFLYSCAN_LIVE_TOKEN"],
              let reference = environment["OPENFLYSCAN_LIVE_SESSION"], !token.isEmpty else {
            throw XCTSkip("Set live service environment to run this opt-in check")
        }
        let client = SurveyCloudClient(connection: try SurveyCloudConnection(
            endpoint: endpoint, sessionID: reference, token: token))
        let session = try await client.createUploadSession(.init(
            name: "OpenFlyScan API check - no flight", horizontalFOV: 70, takeoffASL: 25, minimumInterval: 2))
        do {
            let data = try await client.download("/api/sessions/\(session.id)", maximumBytes: 1_048_576)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let config = try XCTUnwrap(root["config"] as? [String: Any])
            XCTAssertEqual(config["mission_schema_version"] as? Int, 13)
            XCTAssertEqual(config["recapture_flight_mode"] as? String, "STOP_AND_CAPTURE")
        } catch {
            _ = try? await client.uploadSession(session.id, action: "cancel")
            throw error
        }
        let cancelled = try await client.uploadSession(session.id, action: "cancel")
        XCTAssertEqual(cancelled.phase, "cancelled")
        let result = try await client.result()
        XCTAssertEqual(result.mission?.safeToExecute, false)
        let raw = try await client.mission(result)
        XCTAssertFalse(try SurveyCloudClient.validateMission(raw).waypoints.isEmpty)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func photo(_ root: URL, gps: Bool = true) throws -> URL {
        let bytes = CameraFrame.simulator(sequence: 1).jpeg
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = gps ? [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 121.5, kCGImagePropertyGPSLongitudeRef: "E",
            kCGImagePropertyGPSAltitude: 25.0, kCGImagePropertyGPSAltitudeRef: 0
        ]] : [:]
        CGImageDestinationAddImageFromSource(destination, source, 0, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file = root.appendingPathComponent(UUID().uuidString + ".jpg")
        try (data as Data).write(to: file)
        return file
    }

    private var configuration: SurveyUploadConfiguration {
        .init(name: "upload test", horizontalFOV: 70, takeoffASL: 5, minimumInterval: 2)
    }

    private func manifest() -> SurveyUploadManifest {
        .init(endpoint: "https://upload.example", sessionID: "session_123", configuration: configuration)
    }

    private func client() throws -> SurveyCloudClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadURLProtocol.self]
        return SurveyCloudClient(connection: try .init(endpoint: "https://upload.example", sessionID: "session_123", token: "unit-token"), configuration: config)
    }

    func testCreateDeclaresOnlySupportedSchemaAndValidatesConfiguration() async throws {
        UploadURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/sessions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-token")
            let body = try! JSONSerialization.jsonObject(with: UploadURLProtocol.body(request)) as! [String: Any]
            XCTAssertEqual(body["supported_mission_schemas"] as? [Int], [13, 14])
            XCTAssertEqual(body["recapture_flight_mode"] as? String, "STOP_AND_CAPTURE")
            XCTAssertEqual(body["takeoff_absolute_altitude_m"] as? Double, 5)
            return (201, "{\"id\":\"session_123\",\"sealed\":false}")
        }
        let session = try await client().createUploadSession(configuration)
        XCTAssertEqual(session.id, "session_123")
        var invalid = configuration
        invalid.horizontalFOV = .nan
        XCTAssertThrowsError(try invalid.payload())
        invalid = configuration
        invalid.minimumInterval = 0
        XCTAssertThrowsError(try invalid.payload())
        invalid = configuration
        invalid.takeoffASL = nil
        let body = try JSONSerialization.jsonObject(with: invalid.payload()) as! [String: Any]
        XCTAssertNil(body["takeoff_absolute_altitude_m"])
    }

    func testUploadUsesStableSequenceAndAcceptsDuplicateAcknowledgement() async throws {
        let root = try directory()
        let file = try photo(root)
        let store = SurveyUploadStore(root: root.appendingPathComponent("queue"))
        try await store.begin(manifest())
        let value = try await store.enqueue(file: file, headers: nil, sessionID: "session_123", sourceID: "one")
        let job = try XCTUnwrap(value.jobs.first)
        UploadURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/sessions/session_123/images/0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Latitude"), "31.2")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Capture-View"))
            XCTAssertGreaterThan(UploadURLProtocol.body(request).count, 128)
            return (200, "{\"duplicate\":true,\"image\":{\"sequence\":42}}")
        }
        let data = try await store.data(for: job, sessionID: "session_123")
        try await client().uploadImage(sessionID: "session_123", job: job, bytes: data)
    }

    func testDurableQueueKeepsFailuresAndDeletesOnlyAcknowledgedCopies() async throws {
        let root = try directory()
        let file = try photo(root)
        let path = root.appendingPathComponent("queue")
        let store = SurveyUploadStore(root: path)
        try await store.begin(manifest())
        let queued = try await store.enqueue(file: file, headers: nil, sessionID: "session_123", sourceID: "one")
        let duplicate = try await store.enqueue(file: file, headers: nil, sessionID: "session_123", sourceID: "one")
        XCTAssertEqual(duplicate.jobs.count, 1)
        let restored = SurveyUploadStore(root: path)
        let snapshot = try await restored.load()
        XCTAssertEqual(snapshot?.pendingCount, 1)
        let job = try XCTUnwrap(queued.jobs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent(job.filename).path))
        let confirmed = try await restored.acknowledge(job, sessionID: "session_123")
        XCTAssertEqual(confirmed.pendingCount, 0)
        XCTAssertGreaterThan(confirmed.revision, queued.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.appendingPathComponent(job.filename).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let raw = try String(contentsOf: path.appendingPathComponent("session.json"))
        XCTAssertFalse(raw.contains("unit-token"))
        XCTAssertFalse(raw.contains("Authorization"))
        do { _ = try await restored.enqueue(file: file, headers: nil, sessionID: "different", sourceID: "other"); XCTFail() }
        catch { XCTAssertTrue(error is SurveyCloudError) }
        _ = try await restored.markClosed(sessionID: "session_123")
        do { _ = try await restored.enqueue(file: file, headers: nil, sessionID: "session_123", sourceID: "two"); XCTFail() }
        catch { XCTAssertTrue(error is SurveyCloudError) }
    }

    func testHistoryMissingGPSAndQueueOverflowAreNotSilentlyUploaded() async throws {
        let root = try directory()
        XCTAssertThrowsError(try SurveyUploadImage.inspect(photo(root, gps: false), supplied: nil))
        let store = SurveyUploadStore(root: root.appendingPathComponent("queue"), maximumQueueBytes: 1)
        try await store.begin(manifest())
        do { _ = try await store.enqueue(file: photo(root), headers: nil, sessionID: "session_123", sourceID: "one"); XCTFail() }
        catch { XCTAssertTrue(error is SurveyCloudError) }
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot?.jobs.count, 0)
    }

    func testLiveUploadRejectsStaleAndSimulatorTelemetry() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.positionSource = "DJI GPS"
        telemetry.flightStateTimestamp = now
        telemetry.simulatorActive = false
        let file = URL(fileURLWithPath: "/unused")
        var record = SurveyFrameCaptureRecord(frame: .simulator(sequence: 1, date: now), missionID: "test",
            reason: "capture", telemetry: telemetry, executionLegIndex: 0, waypointIndex: 0, imageURL: file, metadataURL: file)
        let headers = try SurveyUploadImage.liveHeaders(record, view: .forwardOblique, now: now)
        XCTAssertEqual(headers["X-Capture-View"], "FORWARD_OBLIQUE")
        XCTAssertEqual(headers["X-Altitude-Source"], "takeoff_asl_plus_relative")
        XCTAssertNil(headers["X-Camera-Pitch"])
        record.telemetry.simulatorActive = true
        XCTAssertThrowsError(try SurveyUploadImage.liveHeaders(record, view: .nadir, now: now))
        record.telemetry.simulatorActive = false
        record.telemetry.flightStateTimestamp = now.addingTimeInterval(-3)
        XCTAssertThrowsError(try SurveyUploadImage.liveHeaders(record, view: .nadir, now: now))
    }

    func testSurveyDownlinkPreservesWideAndPortraitAspectRatios() {
        let wide = SurveyUploadImage.previewSize(width: 3840, height: 2160)
        XCTAssertEqual(wide.width, 1920)
        XCTAssertEqual(wide.height, 1080)
        let portrait = SurveyUploadImage.previewSize(width: 1080, height: 1920)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
        let photo = SurveyUploadImage.previewSize(width: 1440, height: 1080)
        XCTAssertEqual(photo.width, 1440)
        XCTAssertEqual(photo.height, 1080)
    }

    func testRemoteSessionIdentityAndAuthorizationRemainEnforced() async throws {
        UploadURLProtocol.handler = { _ in (401, "denied") }
        do { _ = try await client().uploadSession("session_123"); XCTFail() }
        catch { guard case SurveyCloudError.http(401) = error else { return XCTFail("wrong error") } }
        UploadURLProtocol.handler = { _ in (200, "{\"id\":\"different\"}") }
        do { _ = try await client().uploadSession("session_123", action: "finalize"); XCTFail() }
        catch { XCTAssertTrue(error is SurveyCloudError) }
        do { _ = try await client().uploadSession("../evil"); XCTFail() }
        catch { XCTAssertTrue(error is SurveyCloudError) }
    }

    @MainActor
    func testControllerRestoresPausedAndCannotFinalizePendingQueue() async throws {
        let root = try directory()
        let path = root.appendingPathComponent("queue")
        let store = SurveyUploadStore(root: path)
        try await store.begin(manifest())
        _ = try await store.enqueue(file: photo(root), headers: nil, sessionID: "session_123", sourceID: "one")
        let controller = SurveyCloudUploadController(root: path)
        for _ in 0..<100 where !controller.ready { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(controller.ready)
        XCTAssertTrue(controller.paused)
        XCTAssertFalse(controller.liveEnabled)
        XCTAssertFalse(controller.canFinalize)
        await controller.finalize()
        XCTAssertFalse(controller.manifest?.finalized == true)
        XCTAssertEqual(controller.manifest?.pendingCount, 1)
    }

    @MainActor
    func testFailedUploadRetainsDataAndHistoryBatchCannotChangeSessions() async throws {
        let root = try directory()
        let path = root.appendingPathComponent("queue")
        let file = try photo(root)
        let store = SurveyUploadStore(root: path)
        try await store.begin(manifest())
        _ = try await store.enqueue(file: file, headers: nil, sessionID: "session_123", sourceID: "one")
        UploadURLProtocol.handler = { request in
            request.httpMethod == "PUT" ? (401, "denied") : (200, "{\"id\":\"session_123\",\"sealed\":false}")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadURLProtocol.self]
        let controller = SurveyCloudUploadController(root: path,
            clientFactory: { SurveyCloudClient(connection: $0, configuration: config) }, tokenLoader: { _ in "unit-token" })
        for _ in 0..<100 where !controller.ready { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.resume()
        for _ in 0..<200 where controller.uploading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(controller.paused)
        XCTAssertEqual(controller.manifest?.pendingCount, 1)
        XCTAssertFalse(controller.canFinalize)
        XCTAssertEqual(controller.beginPhotoImport(), "session_123")
        XCTAssertNil(controller.beginPhotoImport())
        await controller.clearLocal()
        XCTAssertNotNil(controller.manifest)
        await controller.importFiles([file], expectedSessionID: "other_session")
        XCTAssertEqual(controller.manifest?.jobs.count, 1)
        controller.finishPhotoImport()
        XCTAssertFalse(controller.historyImporting)
        let restored = SurveyUploadStore(root: path)
        let snapshot = try await restored.load()
        XCTAssertEqual(snapshot?.pendingCount, 1)
    }

    func testConcurrentEnqueueAndAcknowledgementPreserveBothUpdates() async throws {
        let root = try directory()
        let file = try photo(root)
        let store = SurveyUploadStore(root: root.appendingPathComponent("queue"))
        try await store.begin(manifest())
        let value = try await store.enqueue(file: file, headers: nil, sessionID: "session_123", sourceID: "one")
        let job = try XCTUnwrap(value.jobs.first)
        async let enqueue = store.enqueue(file: file, headers: nil, sessionID: "session_123", sourceID: "two")
        async let acknowledge = store.acknowledge(job, sessionID: "session_123")
        _ = try await (enqueue, acknowledge)
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot?.jobs.count, 2)
        XCTAssertEqual(snapshot?.pendingCount, 1)
        XCTAssertEqual(snapshot?.jobs.first?.uploaded, true)
    }

    @MainActor
    func testLiveAndHistoricalIntakeCannotOverlap() async throws {
        let root = try directory()
        let path = root.appendingPathComponent("queue")
        let store = SurveyUploadStore(root: path)
        try await store.begin(manifest())
        let controller = SurveyCloudUploadController(root: path)
        for _ in 0..<100 where !controller.ready { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.setLive(true)
        XCTAssertTrue(controller.liveEnabled)
        XCTAssertNil(controller.beginPhotoImport())
        await controller.importFiles([try photo(root)], expectedSessionID: "session_123")
        XCTAssertEqual(controller.manifest?.jobs.count, 0)
        XCTAssertTrue(controller.status.contains("关闭实时采集"))
        controller.setLive(false)
        XCTAssertEqual(controller.beginPhotoImport(), "session_123")
        controller.setLive(true)
        XCTAssertFalse(controller.liveEnabled)
        controller.finishPhotoImport()
    }

    @MainActor
    func testCorruptManifestIsPreservedUntilExplicitClear() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("session.json")
        try Data("invalid json".utf8).write(to: file)
        let controller = SurveyCloudUploadController(root: root)
        for _ in 0..<100 where !controller.loadFailed { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(controller.loadFailed)
        XCTAssertFalse(controller.ready)
        XCTAssertEqual(try String(contentsOf: file), "invalid json")
        await controller.clearLocal()
        XCTAssertTrue(controller.ready)
        XCTAssertFalse(controller.loadFailed)
        XCTAssertNil(controller.manifest)
    }

    @MainActor
    func testTransientUploadRetriesSameSequenceAndStopsAfterBudget() async throws {
        let root = try directory()
        let path = root.appendingPathComponent("queue")
        let store = SurveyUploadStore(root: path)
        try await store.begin(manifest())
        _ = try await store.enqueue(file: photo(root), headers: nil, sessionID: "session_123", sourceID: "one")
        var uploadPaths: [String] = []
        UploadURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                uploadPaths.append(request.url!.path)
                return (503, "temporarily unavailable")
            }
            return (200, "{\"id\":\"session_123\",\"sealed\":false}")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadURLProtocol.self]
        let controller = SurveyCloudUploadController(root: path,
            clientFactory: { SurveyCloudClient(connection: $0, configuration: config) }, tokenLoader: { _ in "unit-token" })
        for _ in 0..<100 where !controller.ready { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.resume()
        for _ in 0..<800 where controller.uploading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(uploadPaths, Array(repeating: "/api/sessions/session_123/images/0", count: 3))
        XCTAssertTrue(controller.paused)
        XCTAssertFalse(controller.uploading)
        XCTAssertEqual(controller.manifest?.pendingCount, 1)
        let snapshot = try await store.load()
        let job = try XCTUnwrap(snapshot?.jobs.first)
        let bytes = try await store.data(for: job, sessionID: "session_123")
        XCTAssertEqual(bytes.count, job.bytes)
    }

    @MainActor
    func testControllerUploadsThenExplicitlyFinalizesWithoutAutoSubmit() async throws {
        let root = try directory()
        let path = root.appendingPathComponent("queue")
        let store = SurveyUploadStore(root: path)
        try await store.begin(manifest())
        _ = try await store.enqueue(file: photo(root), headers: nil, sessionID: "session_123", sourceID: "one")
        var finalized = false
        UploadURLProtocol.handler = { request in
            if request.httpMethod == "PUT" { return (201, "{\"duplicate\":false,\"image\":{\"sequence\":0}}") }
            if request.url?.path.hasSuffix("/finalize") == true { finalized = true }
            return (200, "{\"id\":\"session_123\",\"sealed\":\(finalized)}")
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadURLProtocol.self]
        let controller = SurveyCloudUploadController(root: path,
            clientFactory: { SurveyCloudClient(connection: $0, configuration: config) }, tokenLoader: { _ in "unit-token" })
        for _ in 0..<100 where !controller.ready { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.resume()
        for _ in 0..<200 where controller.uploading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(controller.manifest?.pendingCount, 0)
        XCTAssertFalse(finalized)
        XCTAssertTrue(controller.canFinalize)
        await controller.finalize()
        XCTAssertTrue(finalized)
        XCTAssertTrue(controller.manifest?.finalized == true)
        XCTAssertFalse(controller.canAdd)
    }
}

private final class UploadURLProtocol: URLProtocol {
    static var handler: (URLRequest) -> (Int, String) = { _ in (500, "unconfigured") }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
