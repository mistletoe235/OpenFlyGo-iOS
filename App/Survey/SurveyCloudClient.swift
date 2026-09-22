import Foundation
import Security

enum SurveyCloudError: LocalizedError {
    case invalid(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .http(let status): return "云端请求失败（HTTP \(status)）；请检查网络、会话状态或访问权限"
        }
    }
}

struct SurveyCloudConnection {
    let endpoint: URL
    let sessionID: String
    let token: String

    init(endpoint: String, sessionID: String, token: String) throws {
        let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else {
            throw SurveyCloudError.invalid("服务地址必须是 HTTP/HTTPS 根地址，不能带账号、查询参数或 API 路径")
        }
        let identifier = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.range(of: "^[a-z0-9][a-z0-9_-]{5,63}$", options: .regularExpression) != nil else {
            throw SurveyCloudError.invalid("会话 ID 应为 6–64 位小写字母、数字、下划线或连字符")
        }
        guard !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SurveyCloudError.invalid("访问码不能包含换行")
        }
        self.endpoint = url
        self.sessionID = identifier
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func assetURL(_ reference: String) throws -> URL {
        guard let url = URL(string: reference, relativeTo: endpoint)?.absoluteURL,
              Self.sameOrigin(endpoint, url), url.user == nil, url.password == nil, url.fragment == nil else {
            throw SurveyCloudError.invalid("拒绝下载其他服务器的文件，避免泄露访问码")
        }
        return url
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }
}

struct SurveyCloudResult: Decodable {
    struct Asset: Decodable { let url: String? }
    struct MissionAsset: Decodable {
        let url: String?
        let safeToExecute: Bool?
        enum CodingKeys: String, CodingKey { case url; case safeToExecute = "safe_to_execute" }
    }
    struct Contract: Decodable {
        let altitudeMode: String?
        enum CodingKeys: String, CodingKey { case altitudeMode = "altitude_mode" }
    }
    let sessionID: String
    let phase: String?
    let completed: Bool?
    let message: String?
    let pointCloud: Asset?
    let mission: MissionAsset?
    let testOnly: Bool?
    let contract: Contract?
    let error: String?
    let missionError: String?
    var relativeHeightTest: Bool { testOnly == true || contract?.altitudeMode == "relative_height_test" }
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", phase, completed, message, pointCloud = "point_cloud"
        case mission = "openfly_v5_mission", testOnly = "test_only", contract, error, missionError = "mission_error"
    }
}

final class SurveyCloudClient: NSObject, URLSessionTaskDelegate {
    private let connection: SurveyCloudConnection
    private let configuration: URLSessionConfiguration

    init(connection: SurveyCloudConnection, configuration: URLSessionConfiguration = .ephemeral) {
        self.connection = connection
        self.configuration = configuration
    }

    func result() async throws -> SurveyCloudResult {
        let data = try await download("/api/sessions/\(connection.sessionID)/result", maximumBytes: 1_048_576)
        let result = try JSONDecoder().decode(SurveyCloudResult.self, from: data)
        guard result.sessionID == connection.sessionID else {
            throw SurveyCloudError.invalid("服务器返回的会话 ID 不匹配")
        }
        return result
    }

    func mission(_ result: SurveyCloudResult) async throws -> String {
        guard !result.relativeHeightTest, let reference = result.mission?.url, !reference.isEmpty else {
            throw SurveyCloudError.invalid("该会话没有可导入航线；相对高度测试结果不能直接用于飞行")
        }
        let data = try await download(reference, maximumBytes: 8 * 1_048_576)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw SurveyCloudError.invalid("航线不是 UTF-8 JSON")
        }
        _ = try Self.validateMission(raw)
        return raw
    }

    static func validateMission(_ raw: String) throws -> SurveyMission {
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = root["schema_version"] as? Int, schema <= SurveyMissionJSON.schemaVersion else {
            throw SurveyCloudError.invalid("云端航线格式不兼容：iOS 当前支持 schema 1–14，请生成兼容航线；不会自动降级连续补拍任务")
        }
        let mission = try SurveyMissionJSON.decode(raw)
        if mission.activeMapping != nil { _ = try ActiveRecaptureMissionValidator.validate(mission) }
        guard OpenFlyBuildFeatures.terrainFollowing || mission.terrainPlan == nil else {
            throw SurveyCloudError.invalid("当前版本未启用仿地飞行，不能导入 terrainPlan 航线")
        }
        return mission
    }

    func pointCloud(_ result: SurveyCloudResult) async throws -> SurveyCloudPointCloud {
        guard let reference = result.pointCloud?.url, !reference.isEmpty else {
            throw SurveyCloudError.invalid("该会话尚未生成点云，请刷新结果")
        }
        let data = try await download(reference, maximumBytes: 32 * 1_048_576)
        return try await Task.detached(priority: .userInitiated) { try SurveyCloudPLY.decode(data) }.value
    }

    func download(_ reference: String, maximumBytes: Int) async throws -> Data {
        try await request(reference, method: "GET", maximumBytes: maximumBytes)
    }

    func request(_ reference: String, method: String, body: Data? = nil,
                 headers: [String: String] = [:], maximumBytes: Int = 1_048_576) async throws -> Data {
        let url = try connection.assetURL(reference)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !connection.token.isEmpty { request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw SurveyCloudError.invalid("无效的服务器响应") }
        guard (200...299).contains(http.statusCode) else {
            throw SurveyCloudError.http(http.statusCode)
        }
        guard http.expectedContentLength <= Int64(maximumBytes) else {
            throw SurveyCloudError.invalid("文件超过预览上限，请在服务器生成精简版（上限 \(maximumBytes / 1_048_576) MiB）")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw SurveyCloudError.invalid("下载文件超过大小上限") }
            data.append(byte)
        }
        guard !data.isEmpty else { throw SurveyCloudError.invalid("服务器返回空文件") }
        return data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum SurveyCloudTokenStore {
    private static let service = "com.openfly.go.survey-cloud"
    static func load(endpoint: URL) -> String {
        var query = base(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess,
              let data = output as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String, endpoint: URL) throws {
        let query = base(endpoint)
        if token.isEmpty { SecItemDelete(query as CFDictionary); return }
        let values = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SurveyCloudError.invalid("访问码无法存入本机钥匙串") }
    }
    private static func base(_ endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "\(endpoint.scheme!.lowercased())://\(endpoint.host!.lowercased()):\(endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80))"]
    }
}
