import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SurveyUploadConfiguration: Codable, Equatable {
    var name: String
    var horizontalFOV: Double
    var takeoffASL: Double?
    var minimumInterval: Double
    var recaptureFlightMode: SurveyRecaptureFlightMode = .stopAndCapture

    func payload() throws -> Data {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, horizontalFOV.isFinite, (10...150).contains(horizontalFOV),
              minimumInterval.isFinite, (0.5...60).contains(minimumInterval),
              takeoffASL == nil || takeoffASL!.isFinite else {
            throw SurveyCloudError.invalid("请填写有效会话名称、水平视场角、拍照间隔和起飞点海拔")
        }
        var fields: [String: Any] = [
            "name": name, "horizontal_fov_deg": horizontalFOV,
            "minimum_capture_interval_s": minimumInterval,
            "supported_mission_schemas": [13, 14], "recapture_flight_mode": recaptureFlightMode.rawValue,
            "auto_preview": true, "maximum_tasks": 12
        ]
        if let takeoffASL { fields["takeoff_absolute_altitude_m"] = takeoffASL }
        return try JSONSerialization.data(withJSONObject: fields)
    }
}

extension SurveyUploadConfiguration {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        horizontalFOV = try values.decode(Double.self, forKey: .horizontalFOV)
        takeoffASL = try values.decodeIfPresent(Double.self, forKey: .takeoffASL)
        minimumInterval = try values.decode(Double.self, forKey: .minimumInterval)
        recaptureFlightMode = try values.decodeIfPresent(SurveyRecaptureFlightMode.self,
                                                        forKey: .recaptureFlightMode) ?? .stopAndCapture
    }
}

struct SurveyUploadSession: Codable {
    var id: String
    var sealed: Bool?
    var cancelled: Bool?
    var phase: String?
    var imageCount: Int?
    enum CodingKeys: String, CodingKey { case id, sealed, cancelled, phase; case imageCount = "image_count" }
}

extension SurveyCloudClient {
    func createUploadSession(_ configuration: SurveyUploadConfiguration) async throws -> SurveyUploadSession {
        let data = try await request("/api/sessions", method: "POST", body: configuration.payload(),
                                     headers: ["Content-Type": "application/json"])
        let session = try JSONDecoder().decode(SurveyUploadSession.self, from: data)
        guard session.id.range(of: "^[a-z0-9][a-z0-9_-]{5,63}$", options: .regularExpression) != nil,
              session.sealed != true, session.cancelled != true else {
            throw SurveyCloudError.invalid("服务器未返回有效的新上传会话")
        }
        return session
    }

    func uploadSession(_ sessionID: String, action: String? = nil) async throws -> SurveyUploadSession {
        guard sessionID.range(of: "^[a-z0-9][a-z0-9_-]{5,63}$", options: .regularExpression) != nil,
              action == nil || ["finalize", "retry", "cancel"].contains(action!) else {
            throw SurveyCloudError.invalid("无效的上传会话操作")
        }
        let suffix = action.map { "/\($0)" } ?? ""
        let data = try await request("/api/sessions/\(sessionID)\(suffix)", method: action == nil ? "GET" : "POST",
                                     body: action == nil ? nil : Data("{}".utf8),
                                     headers: ["Content-Type": "application/json"])
        let session = try JSONDecoder().decode(SurveyUploadSession.self, from: data)
        guard session.id == sessionID else { throw SurveyCloudError.invalid("服务器返回的会话 ID 不匹配") }
        return session
    }

    func uploadImage(sessionID: String, job: SurveyUploadJob, bytes: Data) async throws {
        guard sessionID.range(of: "^[a-z0-9][a-z0-9_-]{5,63}$", options: .regularExpression) != nil,
              (0...999_999).contains(job.sequence), (128...SurveyUploadImage.maximumBytes).contains(bytes.count) else {
            throw SurveyCloudError.invalid("上传图片或序号无效")
        }
        var headers = job.headers
        headers["Content-Type"] = job.mimeType
        headers["X-Filename"] = job.filename
        let data = try await request("/api/sessions/\(sessionID)/images/\(job.sequence)", method: "PUT",
                                     body: bytes, headers: headers)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let image = response["image"] as? [String: Any], let sequence = image["sequence"] as? Int,
              (response["duplicate"] as? Bool == true || sequence == job.sequence) else {
            throw SurveyCloudError.invalid("图片上传回执无效，已保留本地文件")
        }
    }
}

struct SurveyUploadJob: Codable, Identifiable {
    var id: String
    var sequence: Int
    var filename: String
    var mimeType: String
    var bytes: Int
    var headers: [String: String]
    var uploaded = false
}

struct SurveyUploadManifest: Codable {
    var endpoint: String
    var sessionID: String
    var configuration: SurveyUploadConfiguration
    var jobs: [SurveyUploadJob] = []
    var finalized = false
    var cancelled = false
    var revision = 0
    var pendingCount: Int { jobs.filter { !$0.uploaded }.count }
}

enum SurveyUploadImage {
    static let maximumBytes = 48 * 1_048_576

    static func previewSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1.0, 1920.0 / Double(max(1, max(width, height))))
        return (max(1, Int(Double(width) * scale)), max(1, Int(Double(height) * scale)))
    }

    static func inspect(_ file: URL, supplied: [String: String]?) throws -> (Int, String, [String: String]) {
        let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, let count = size.fileSize, (128...maximumBytes).contains(count),
              let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 60_000_000 else {
            throw SurveyCloudError.invalid("只支持完整的 JPEG/PNG 图片，单张 48 MiB / 6000 万像素以内；HEIC 请先导出 JPEG")
        }
        var headers = supplied ?? [:]
        if supplied == nil {
            guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
                  let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
                  let longitude = gps[kCGImagePropertyGPSLongitude] as? Double,
                  let altitude = gps[kCGImagePropertyGPSAltitude] as? Double,
                  let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef] as? String,
                  let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef] as? String,
                  ["N", "S"].contains(latitudeRef), ["E", "W"].contains(longitudeRef) else {
                throw SurveyCloudError.invalid("历史照片缺少原始 GPS 或海拔，不能用手机当前位姿代填")
            }
            headers["X-Latitude"] = String(latitudeRef == "S" ? -latitude : latitude)
            headers["X-Longitude"] = String(longitudeRef == "W" ? -longitude : longitude)
            headers["X-Altitude"] = String((gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1 ? -altitude : altitude)
        }
        guard let latitude = Double(headers["X-Latitude"] ?? ""), latitude.isFinite, abs(latitude) <= 90,
              let longitude = Double(headers["X-Longitude"] ?? ""), longitude.isFinite, abs(longitude) <= 180,
              abs(latitude) > 1e-9 || abs(longitude) > 1e-9,
              let altitude = Double(headers["X-Altitude"] ?? ""), altitude.isFinite else {
            throw SurveyCloudError.invalid("图片定位或海拔数据无效")
        }
        guard headers.allSatisfy({ !$0.value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw SurveyCloudError.invalid("图片元数据包含无效控制字符")
        }
        return (count, type == UTType.png.identifier ? "image/png" : "image/jpeg", headers)
    }

    static func liveHeaders(_ record: SurveyFrameCaptureRecord, view: SurveyCaptureView,
                            now: Date = Date()) throws -> [String: String] {
        let telemetry = record.telemetry
        let age = record.frame.capturedAt.timeIntervalSince(telemetry.flightStateTimestamp)
        guard telemetry.connected, !telemetry.simulatorActive, telemetry.positionSource != "Mock GPS",
              telemetry.aircraftLocationValid, (-0.25...2).contains(age),
              (-0.25...10).contains(now.timeIntervalSince(record.frame.capturedAt)) else {
            throw SurveyCloudError.invalid("未上传：定位/图像过期或当前是仿真数据，禁止混入实拍会话")
        }
        var headers = [
            "X-Latitude": String(telemetry.aircraft.latitude), "X-Longitude": String(telemetry.aircraft.longitude),
            "X-Altitude": String(telemetry.asl), "X-Altitude-Source": "takeoff_asl_plus_relative",
            "X-Timestamp": ISO8601DateFormatter().string(from: record.frame.capturedAt)
        ]
        if view != .localOblique { headers["X-Capture-View"] = view.rawValue }
        if let stamp = telemetry.gimbalStateTimestamp,
           (-0.25...2).contains(record.frame.capturedAt.timeIntervalSince(stamp)),
           let yaw = telemetry.gimbalYaw, yaw.isFinite, telemetry.gimbalPitch.isFinite,
           let roll = telemetry.gimbalRoll, roll.isFinite {
            headers["X-Camera-Yaw"] = String(yaw)
            headers["X-Camera-Pitch"] = String(telemetry.gimbalPitch)
            headers["X-Camera-Roll"] = String(roll)
        }
        return headers
    }
}

actor SurveyUploadStore {
    let root: URL
    private var manifest: SurveyUploadManifest?
    private var loaded = false
    private let maximumQueueBytes: Int

    init(root: URL, maximumQueueBytes: Int = 512 * 1_048_576) {
        self.root = root
        self.maximumQueueBytes = maximumQueueBytes
    }

    func load() throws -> SurveyUploadManifest? {
        if !loaded {
            let url = root.appendingPathComponent("session.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(SurveyUploadManifest.self, from: Data(contentsOf: url))
                _ = try SurveyCloudConnection(endpoint: value.endpoint, sessionID: value.sessionID, token: "")
                _ = try value.configuration.payload()
                guard value.jobs.count <= 1_000, Set(value.jobs.map(\.sequence)).count == value.jobs.count,
                      value.jobs.allSatisfy({ job in
                          job.filename.range(of: "^image_[0-9]{6}\\.(jpg|png)$", options: .regularExpression) != nil &&
                              (0...999_999).contains(job.sequence) && (128...SurveyUploadImage.maximumBytes).contains(job.bytes)
                      }) else { throw SurveyCloudError.invalid("本地上传清单无效，未读取或删除图片") }
                manifest = value
            }
            loaded = true
        }
        return manifest
    }

    func begin(_ value: SurveyUploadManifest) throws {
        guard try load() == nil else { throw SurveyCloudError.invalid("请先保留会话 ID 并清理上次本地上传记录") }
        try save(value)
    }

    func enqueue(file: URL, headers: [String: String]?, sessionID: String, sourceID: String) throws -> SurveyUploadManifest {
        guard var current = try load(), current.sessionID == sessionID, !current.finalized, !current.cancelled else {
            throw SurveyCloudError.invalid("上传会话已改变、提交或取消")
        }
        if current.jobs.contains(where: { $0.id == sourceID }) { return current }
        let (count, mime, metadata) = try SurveyUploadImage.inspect(file, supplied: headers)
        guard current.jobs.count < 1_000,
              current.jobs.filter({ !$0.uploaded }).reduce(0, { $0 + $1.bytes }) + count <= maximumQueueBytes else {
            throw SurveyCloudError.invalid("本地待传队列已满（512 MiB / 1000 张）；请先上传或清理")
        }
        let sequence = (current.jobs.map(\.sequence).max() ?? -1) + 1
        let filename = String(format: "image_%06d", sequence) + (mime == "image/png" ? ".png" : ".jpg")
        let job = SurveyUploadJob(id: sourceID, sequence: sequence, filename: filename, mimeType: mime, bytes: count, headers: metadata)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: file, to: destination)
        current.jobs.append(job)
        current.revision += 1
        do { try save(current) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return current
    }

    func data(for job: SurveyUploadJob, sessionID: String) throws -> Data {
        guard let current = try load(), current.sessionID == sessionID,
              current.jobs.contains(where: { $0.id == job.id && !$0.uploaded }),
              job.filename == URL(fileURLWithPath: job.filename).lastPathComponent else {
            throw SurveyCloudError.invalid("待传图片不属于当前会话")
        }
        let file = root.appendingPathComponent(job.filename)
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == job.bytes else {
            throw SurveyCloudError.invalid("本地图片大小发生变化，停止上传")
        }
        return try Data(contentsOf: file, options: .mappedIfSafe)
    }

    func acknowledge(_ job: SurveyUploadJob, sessionID: String) throws -> SurveyUploadManifest {
        guard var current = try load(), current.sessionID == sessionID,
              let index = current.jobs.firstIndex(where: { $0.id == job.id }) else {
            throw SurveyCloudError.invalid("上传回执属于旧会话")
        }
        current.jobs[index].uploaded = true
        current.revision += 1
        try save(current)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(job.filename))
        return current
    }

    func markClosed(sessionID: String, cancelled: Bool = false) throws -> SurveyUploadManifest {
        guard var current = try load(), current.sessionID == sessionID else { throw SurveyCloudError.invalid("旧会话操作已失效") }
        current.finalized = !cancelled
        current.cancelled = cancelled
        current.revision += 1
        try save(current)
        return current
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        manifest = nil
        loaded = true
    }

    private func save(_ value: SurveyUploadManifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent("session.json"), options: .atomic)
        manifest = value
        loaded = true
    }
}
