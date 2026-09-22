import XCTest
@testable import DJIVLNiOS

final class SurveyCloudTests: XCTestCase {
    private func connection(_ endpoint: String = "https://cloud.example") throws -> SurveyCloudConnection {
        try SurveyCloudConnection(endpoint: endpoint, sessionID: "session_123", token: "test-token")
    }

    func testEndpointAndSessionValidation() throws {
        for endpoint in ["file:///tmp/cloud", "https://user:pass@cloud.example", "https://cloud.example/api", "https://cloud.example?secret=1"] {
            XCTAssertThrowsError(try connection(endpoint))
        }
        for identifier in ["short", "../secret", "UPPERCASE", "session?id", "session/path"] {
            XCTAssertThrowsError(try SurveyCloudConnection(endpoint: "https://cloud.example", sessionID: identifier, token: ""))
        }
        XCTAssertThrowsError(try SurveyCloudConnection(endpoint: "https://cloud.example", sessionID: "session_123", token: "test\r\ninjected"))
        XCTAssertEqual(try connection().assetURL("/files/mission.json").absoluteString, "https://cloud.example/files/mission.json")
    }

    func testDownloadsCannotExfiltrateAccessCodeAcrossOrigins() throws {
        let connection = try connection()
        for address in ["https://other.example/file", "//other.example/file", "http://cloud.example/file", "https://cloud.example:8443/file", "https://user@cloud.example/file"] {
            XCTAssertThrowsError(try connection.assetURL(address))
        }
        XCTAssertNoThrow(try connection.assetURL("https://cloud.example:443/files/result.ply"))
    }

    func testResultRequiresMatchingSessionAndPreservesUnsafeFlag() async throws {
        let client = try client(response: """
        {"session_id":"session_123","phase":"complete","point_cloud":{"url":"/cloud.ply"},
        "openfly_v5_mission":{"url":"/mission.json","safe_to_execute":false}}
        """)
        let result = try await client.result()
        XCTAssertEqual(result.pointCloud?.url, "/cloud.ply")
        XCTAssertEqual(result.mission?.safeToExecute, false)
        XCTAssertFalse(result.relativeHeightTest)
        XCTAssertEqual(CloudURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(CloudURLProtocol.lastRequest?.url?.path, "/api/sessions/session_123/result")
    }

    func testWrongSessionAndUnauthorizedResponseFail() async throws {
        for (body, status) in [("{\"session_id\":\"different\"}", 200), ("access denied", 401)] {
            do { _ = try await client(response: body, status: status).result(); XCTFail("must fail") }
            catch { XCTAssertTrue(error is SurveyCloudError) }
        }
    }

    func testDownloadEnforcesActualByteBudgetWithoutContentLength() async throws {
        do {
            _ = try await client(response: "12345").download("/file", maximumBytes: 4)
            XCTFail("must enforce streaming limit")
        } catch { XCTAssertTrue(error is SurveyCloudError) }
    }

    func testRelativeHeightTestCannotDownloadMission() async throws {
        let client = try client(response: """
        {"session_id":"session_123","contract":{"altitude_mode":"relative_height_test"},
        "openfly_v5_mission":{"url":"/mission.json","safe_to_execute":true}}
        """)
        let result = try await client.result()
        XCTAssertTrue(result.relativeHeightTest)
        do { _ = try await client.mission(result); XCTFail("relative test must not import") }
        catch { XCTAssertTrue(error is SurveyCloudError) }
    }

    func testMissionValidationRejectsSchema14WithoutModeAndNonWGS84() throws {
        let mission = try makeMission()
        let raw = try SurveyMissionJSON.encode(mission)
        XCTAssertEqual(try SurveyCloudClient.validateMission(raw).id, mission.id)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        root["schema_version"] = 14
        XCTAssertThrowsError(try SurveyCloudClient.validateMission(String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self)))
        root["schema_version"] = 13
        root["coordinate_frame"] = "LOCAL_XYZ"
        XCTAssertThrowsError(try SurveyCloudClient.validateMission(String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self)))
    }

    func testDownloadMissionValidatesBeforeReturningForPreview() async throws {
        let mission = try makeMission()
        let client = try client(response: SurveyMissionJSON.encode(mission))
        let result = try JSONDecoder().decode(SurveyCloudResult.self, from: Data("""
        {"session_id":"session_123","openfly_v5_mission":{"url":"/route.json","safe_to_execute":false}}
        """.utf8))
        let raw = try await client.mission(result)
        XCTAssertEqual(try SurveyMissionJSON.decode(raw).id, mission.id)
    }

    func testRedirectIsNotFollowedOrForwarded() throws {
        let client = try client(response: "")
        let url = URL(string: "https://cloud.example/file")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = URLSession.shared.dataTask(with: url)
        var called = false
        client.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                          newRequest: URLRequest(url: URL(string: "https://other.example/file")!)) { next in
            called = true
            XCTAssertNil(next)
        }
        XCTAssertTrue(called)
    }

    func testAsciiPLYColorsAndDecimation() throws {
        let raw = """
        ply
        format ascii 1.0
        element vertex 3
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header
        0 1 2 255 0 0
        3 4 5 0 255 0
        6 7 8 0 0 255

        """
        let cloud = try SurveyCloudPLY.decode(Data(raw.utf8), maximumPoints: 2)
        XCTAssertEqual(cloud.sourceCount, 3)
        XCTAssertEqual(cloud.positions, [SIMD3(0, 1, 2), SIMD3(6, 7, 8)])
        XCTAssertEqual(Array(cloud.colors), [255, 0, 0, 255, 0, 0, 255, 255])
        XCTAssertEqual(SurveyCloudPLY.scene(cloud).rootNode.childNodes.count, 2)
    }

    func testBinaryPLYSupportsExtraPropertiesAndUnalignedFloat() throws {
        var data = Data("""
        ply
        format binary_little_endian 1.0
        element vertex 1
        property uchar confidence
        property float x
        property float y
        property float z
        end_header

        """.utf8)
        data.append(255)
        for value: Float in [1.25, -2.5, 3.75] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        XCTAssertEqual(try SurveyCloudPLY.decode(data).positions, [SIMD3(1.25, -2.5, 3.75)])
        XCTAssertThrowsError(try SurveyCloudPLY.decode(data.dropLast()))
    }

    func testPLYRejectsMalformedHeaderTruncationAndNonfiniteOnlyData() {
        for raw in ["not a ply", "ply\nformat ascii 1.0\nend_header\n", """
        ply
        format ascii 1.0
        element vertex 2
        property float x
        property float y
        property float z
        end_header
        1 2 3
        """, """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        end_header
        nan nan nan
        """] {
            XCTAssertThrowsError(try SurveyCloudPLY.decode(Data(raw.utf8)))
        }
    }

    @MainActor func testResetInvalidatesCloudPreviewAndDoesNotHaveFlightSideEffects() {
        let model = SurveyCloudViewModel()
        model.reset()
        XCTAssertNil(model.result)
        XCTAssertNil(model.scene)
        XCTAssertNil(model.missionRaw)
        XCTAssertFalse(model.busy)
    }

    private func client(response: String, status: Int = 200) throws -> SurveyCloudClient {
        CloudURLProtocol.response = Data(response.utf8)
        CloudURLProtocol.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudURLProtocol.self]
        return SurveyCloudClient(connection: try connection(), configuration: configuration)
    }

    private func makeMission() throws -> SurveyMission {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 30
        constraints.speedMetersPerSecond = 1
        return try SurveyPlanner.plan(name: "cloud-preview", roi: [
            .init(latitude: 31, longitude: 121), .init(latitude: 31, longitude: 121.0002),
            .init(latitude: 31.0002, longitude: 121.0002), .init(latitude: 31.0002, longitude: 121)
        ], constraints: constraints)
    }
}

private final class CloudURLProtocol: URLProtocol {
    static var response = Data()
    static var status = 200
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
