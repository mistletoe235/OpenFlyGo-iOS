import Foundation
import ImageIO

struct SurveyFrameCaptureRecord: Sendable {
    var frame: CameraFrame
    var missionID: String
    var reason: String
    var telemetry: FlightTelemetry
    var executionLegIndex: Int
    var waypointIndex: Int
    var imageURL: URL
    var metadataURL: URL
    var isTemporary = false

    func removeTemporaryFiles() {
        guard isTemporary else { return }
        let files = FileManager.default
        try? files.removeItem(at: imageURL)
        try? files.removeItem(at: metadataURL)
        let directory = imageURL.deletingLastPathComponent()
        if (try? files.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
            try? files.removeItem(at: directory)
        }
    }
}

final class SurveyFrameWriteBudget: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: SurveyFrameWriteBudget?

        fileprivate init(owner: SurveyFrameWriteBudget) { self.owner = owner }

        func release() {
            lock.lock()
            let previous = owner
            owner = nil
            lock.unlock()
            previous?.finish()
        }

        deinit { release() }
    }

    private let lock = NSLock()
    private let maximumPending: Int
    private var pending = 0

    init(maximumPending: Int = 2) {
        precondition(maximumPending > 0)
        self.maximumPending = maximumPending
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    func tryAcquire() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard pending < maximumPending else { return nil }
        pending += 1
        return Lease(owner: self)
    }

    private func finish() {
        lock.lock()
        pending -= 1
        lock.unlock()
    }
}

enum SurveyFrameWriteError: LocalizedError {
    case busy
    var errorDescription: String? { "手机图像保存队列繁忙，已跳过副本；飞机拍照不受影响" }
}

final class SessionCaptureStore: @unchecked Sendable {
    let directory: URL
    private let queue: DispatchQueue
    private let surveyWrites = SurveyFrameWriteBudget()
    private let logURL: URL
    private var capturedFrames = 0

    var pendingSurveyFrameWrites: Int { surveyWrites.pendingCount }

    init(fileManager: FileManager = .default, rootDirectory: URL? = nil,
         queue: DispatchQueue = DispatchQueue(label: "org.openfly.session-capture", qos: .utility)) {
        self.queue = queue
        let root = rootDirectory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenFlyGo/sessions", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        directory = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        logURL = directory.appendingPathComponent("session.log")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        pruneOldSessions(root: root, keeping: 10, fileManager: fileManager)
    }

    func append(kind: String, message: String, timestamp: Date) {
        queue.async { [logURL] in
            let date = ISO8601DateFormatter().string(from: timestamp)
            let sanitized = message.replacingOccurrences(of: "\n", with: " ")
            guard let data = "\(date) [\(kind)] \(sanitized)\n".data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: logURL) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {}
        }
    }

    func capture(frame: CameraFrame, prompt: String, modelState: [Double]?, result: InferenceResult) {
        queue.async { [self] in
            guard capturedFrames < 500 else { return }
            capturedFrames += 1
            let directory = self.directory
            let images = directory.appendingPathComponent("images", isDirectory: true)
            try? FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            let stamp = Int(frame.capturedAt.timeIntervalSince1970 * 1_000)
            let stem = "VLN_\(stamp)_\(UUID().uuidString.prefix(8))"
            let imageURL = images.appendingPathComponent(stem + (frame.sourceFormat == "png" ? ".png" : ".jpg"))
            let metadataURL = images.appendingPathComponent(stem + ".json")
            do {
                try frame.jpeg.write(to: imageURL, options: .atomic)
                let metadata: [String: Any] = [
                    "captured_at": ISO8601DateFormatter().string(from: frame.capturedAt),
                    "width": frame.width,
                    "height": frame.height,
                    "prompt": prompt,
                    "model_state": modelState as Any? ?? NSNull(),
                    "action": [result.action.forwardMeters, result.action.rightMeters,
                               result.action.upMeters, result.action.stopScore],
                    "yaw_delta_degrees": result.action.yawDegrees,
                    "latency_ms": result.latencyMilliseconds,
                    "replanned": result.replanned,
                    "chunk_remaining": result.chunkRemaining,
                    "stages_ms": result.stages,
                    "predicted_horizon": result.predictedActions.map {
                        [$0.forwardMeters, $0.rightMeters, $0.upMeters, $0.yawDegrees, $0.stopScore]
                    },
                ]
                let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: metadataURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: imageURL)
            }
        }
    }

    func captureSurveyFrame(
        frame: CameraFrame, missionID: String, telemetry: FlightTelemetry, retainLocally: Bool,
        metadata: @escaping @Sendable (_ imageURL: URL, _ metadataURL: URL) throws -> Data,
                            completion: @escaping @Sendable (Result<(URL, URL), Error>) -> Void) {
        guard let lease = surveyWrites.tryAcquire() else {
            completion(.failure(SurveyFrameWriteError.busy))
            return
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("openfly-survey-\(UUID().uuidString)", isDirectory: true)
        queue.async { [directory] in
            do {
                let safeMissionID = missionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                let captures = retainLocally
                    ? directory.appendingPathComponent("survey/\(safeMissionID)", isDirectory: true) : temporary
                try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
                let stamp = Int(frame.capturedAt.timeIntervalSince1970 * 1_000)
                let persistedFrameID = frame.sourceFrameID ?? UInt64(frame.sequence)
                let stem = "SURVEY_\(stamp)_F\(persistedFrameID)"
                let imageURL = captures.appendingPathComponent(stem + (frame.sourceFormat == "png" ? ".png" : ".jpg"))
                let metadataURL = captures.appendingPathComponent(stem + ".json")
                let imageData = SurveyJPEGMetadataWriter.write(frame.jpeg, frame: frame, telemetry: telemetry)
                try imageData.write(to: imageURL, options: .atomic)
                try metadata(imageURL, metadataURL).write(to: metadataURL, options: .atomic)
                DispatchQueue.main.async {
                    defer { lease.release() }
                    completion(.success((imageURL, metadataURL)))
                }
            } catch {
                if !retainLocally { try? FileManager.default.removeItem(at: temporary) }
                DispatchQueue.main.async {
                    defer { lease.release() }
                    completion(.failure(error))
                }
            }
        }
    }

    private func pruneOldSessions(root: URL, keeping limit: Int, fileManager: FileManager) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ), entries.count > limit else { return }
        let sorted = entries.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for url in sorted.dropFirst(limit) { try? fileManager.removeItem(at: url) }
    }
}

private enum SurveyJPEGMetadataWriter {
    static func write(_ jpeg: Data, frame: CameraFrame, telemetry: FlightTelemetry) -> Data {
        guard frame.sourceFormat.lowercased() != "png",
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return jpeg
        }
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var updated = properties
        let captured = frame.capturedAt
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let dateTime = formatter.string(from: captured)
        var exif = (updated[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = dateTime
        exif[kCGImagePropertyExifDateTimeDigitized] = dateTime
        exif[kCGImagePropertyExifSubsecTimeOriginal] = String(format: "%03d", Int(captured.timeIntervalSince1970 * 1_000) % 1_000)
        var tiff = (updated[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFDateTime] = dateTime
        tiff[kCGImagePropertyTIFFSoftware] = "OpenFly Go iOS"
        tiff[kCGImagePropertyTIFFImageDescription] = "DJI video downlink frame; pose sampled from aircraft telemetry at frame receipt"
        updated[kCGImagePropertyExifDictionary] = exif
        updated[kCGImagePropertyTIFFDictionary] = tiff

        let gpsAge = captured.timeIntervalSince(telemetry.flightStateTimestamp)
        let cameraOrientation = CameraOrientationResolver.resolve(
            aircraftHeadingDegrees: telemetry.heading,
            gimbalRollDegrees: telemetry.gimbalRoll,
            gimbalPitchDegrees: telemetry.gimbalPitch,
            absoluteGimbalYawDegrees: telemetry.gimbalYaw,
            relativeGimbalYawDegrees: telemetry.gimbalYawRelativeToAircraftHeading
        )
        var poseComment: [String: Any] = [
            "aircraft_heading_deg": telemetry.heading,
            "gimbal_pitch_deg": telemetry.gimbalPitch,
        ]
        if let value = telemetry.aircraftRoll { poseComment["aircraft_roll_deg"] = value }
        if let value = telemetry.aircraftPitch { poseComment["aircraft_pitch_deg"] = value }
        if let value = telemetry.aircraftYaw { poseComment["aircraft_yaw_deg"] = value }
        if let value = telemetry.gimbalRoll { poseComment["gimbal_roll_deg"] = value }
        if let value = telemetry.gimbalYaw { poseComment["gimbal_yaw_deg_ned"] = value }
        if let value = telemetry.gimbalYawRelativeToAircraftHeading {
            poseComment["gimbal_yaw_relative_to_aircraft_deg"] = value
        }
        if let value = telemetry.gimbalStateTimestamp {
            poseComment["gimbal_state_timestamp_epoch_ms"] = Int64(value.timeIntervalSince1970 * 1_000)
            poseComment["gimbal_age_ms"] = Int64(captured.timeIntervalSince(value) * 1_000)
        }
        if let value = cameraOrientation.rollDegrees { poseComment["camera_roll_deg"] = value }
        if let value = cameraOrientation.pitchDegrees { poseComment["camera_pitch_deg"] = value }
        if let value = cameraOrientation.yawDegrees { poseComment["camera_yaw_deg_true"] = value }
        if let value = cameraOrientation.yawSource { poseComment["camera_yaw_source"] = value }
        if let value = cameraOrientation.yawConsistencyErrorDegrees {
            poseComment["camera_yaw_consistency_error_deg"] = value
        }
        if let data = try? JSONSerialization.data(withJSONObject: poseComment, options: [.sortedKeys]),
           let comment = String(data: data, encoding: .utf8) {
            exif[kCGImagePropertyExifUserComment] = comment
            updated[kCGImagePropertyExifDictionary] = exif
        }
        if telemetry.aircraftLocationValid, gpsAge >= -0.25, gpsAge <= 2,
           telemetry.aircraft.latitude.isFinite, abs(telemetry.aircraft.latitude) <= 90,
           telemetry.aircraft.longitude.isFinite, abs(telemetry.aircraft.longitude) <= 180,
           abs(telemetry.aircraft.latitude) > 1e-9 || abs(telemetry.aircraft.longitude) > 1e-9 {
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(telemetry.aircraft.latitude),
                kCGImagePropertyGPSLatitudeRef: telemetry.aircraft.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(telemetry.aircraft.longitude),
                kCGImagePropertyGPSLongitudeRef: telemetry.aircraft.longitude >= 0 ? "E" : "W",
                kCGImagePropertyGPSAltitude: abs(telemetry.asl),
                kCGImagePropertyGPSAltitudeRef: telemetry.asl >= 0 ? 0 : 1,
                kCGImagePropertyGPSImgDirection: cameraOrientation.yawDegrees
                    ?? normalizedHeading(telemetry.heading),
                kCGImagePropertyGPSImgDirectionRef: "T",
                kCGImagePropertyGPSSpeed: hypot(telemetry.velocityNorth, telemetry.velocityEast) * 3.6,
                kCGImagePropertyGPSSpeedRef: "K",
            ]
            let groundSpeed = hypot(telemetry.velocityNorth, telemetry.velocityEast)
            if groundSpeed > 0.05 {
                gps[kCGImagePropertyGPSTrack] = normalizedHeading(
                    atan2(telemetry.velocityEast, telemetry.velocityNorth) * 180 / .pi
                )
                gps[kCGImagePropertyGPSTrackRef] = "T"
            }
            updated[kCGImagePropertyGPSDictionary] = gps
        }

        let output = NSMutableData()
        guard let finalDestination = CGImageDestinationCreateWithData(output, type, 1, nil) else { return jpeg }
        CGImageDestinationAddImageFromSource(finalDestination, source, 0, updated as CFDictionary)
        guard CGImageDestinationFinalize(finalDestination) else { return jpeg }
        return output as Data
    }

    private static func normalizedHeading(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }
}

struct FlightEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var timestamp = Date()
    var kind: String
    var message: String
}

@MainActor
final class EventLog: ObservableObject {
    @Published private(set) var events: [FlightEvent] = []
    private let store = SessionCaptureStore()

    var sessionDirectory: URL { store.directory }

    func append(_ kind: String, _ message: String) {
        let event = FlightEvent(kind: kind, message: message)
        events.append(event)
        if events.count > 100 { events.removeFirst(events.count - 100) }
        store.append(kind: kind, message: message, timestamp: event.timestamp)
        print("[OpenFly][\(kind)] \(message)")
    }

    func captureInference(frame: CameraFrame, prompt: String, modelState: [Double]?, result: InferenceResult) {
        store.capture(frame: frame, prompt: prompt, modelState: modelState, result: result)
    }

    func captureSurveyFrame(frame: CameraFrame, mission: SurveyMission, reason: String,
                            telemetry: FlightTelemetry, executionLegIndex: Int,
                            waypointIndex: Int, retainLocally: Bool = true,
                            completion: @escaping @Sendable (Result<SurveyFrameCaptureRecord, Error>) -> Void) {
        store.captureSurveyFrame(
            frame: frame, missionID: mission.id, telemetry: telemetry, retainLocally: retainLocally,
            metadata: { imageURL, metadataURL in
                let record = SurveyFrameCaptureRecord(
                    frame: frame, missionID: mission.id, reason: reason,
                    telemetry: telemetry, executionLegIndex: executionLegIndex,
                    waypointIndex: waypointIndex, imageURL: imageURL,
                    metadataURL: metadataURL
                )
                return try SurveyUeBridgeController.encodeCapture(record)
            }
        ) { result in
                completion(result.map { urls in
                    SurveyFrameCaptureRecord(
                        frame: frame, missionID: mission.id, reason: reason,
                        telemetry: telemetry, executionLegIndex: executionLegIndex,
                        waypointIndex: waypointIndex, imageURL: urls.0,
                        metadataURL: urls.1, isTemporary: !retainLocally
                    )
                })
            }
    }

    func snapshot(telemetry: FlightTelemetry, control: ControlSnapshot) -> URL? {
        struct Snapshot: Codable { let telemetry: FlightTelemetry; let controlMode: String; let controlOwner: String; let events: [FlightEvent] }
        let value = Snapshot(telemetry: telemetry, controlMode: control.mode.rawValue, controlOwner: control.owner.rawValue, events: events)
        guard let data = try? JSONEncoder.pretty.encode(value) else { return nil }
        let url = store.directory.appendingPathComponent("openfly-snapshot-\(Int(Date().timeIntervalSince1970)).json")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return encoder }
}
