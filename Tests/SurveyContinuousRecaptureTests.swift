import XCTest
@testable import DJIVLNiOS

enum ContinuousRecaptureFixture {
    static func mission(spacing: Double = 8) -> SurveyMission {
        let points = (0...5).map { index in
            SurveyWaypoint(point: .init(latitude: 31 + Double(index) * spacing / 111_132,
                                         longitude: 121, altitudeMeters: 30),
                headingDegrees: 0, gimbalPitchDegrees: -45, kind: .capturePoint,
                captureAction: .captureOnReach, passIndex: index, captureView: .localOblique)
        }
        return SurveyMission(name: "continuous-test", cameraProfile: .djiMini2,
            constraints: SurveyConstraints(), roi: [
                .init(latitude: 30.999, longitude: 120.999),
                .init(latitude: 31.001, longitude: 120.999),
                .init(latitude: 31.001, longitude: 121.001),
            ], waypoints: points, estimatedPathMeters: spacing * 5,
            estimatedPhotoCount: 6, estimatedFlightSeconds: 60,
            activeMapping: .init(selectionMethod: "test", groundTruthUsed: false,
                gsUsedForSelection: false, ordinaryGPSUsed: true, sourceCaptureCount: 6,
                surveyCaptureCount: 6, bridgeCaptureCount: 0, sourceEstimatedRouteDistanceMeters: spacing * 5,
                passes: (0...5).map { .init(passIndex: $0, regionID: "region", role: "EXACT_CAPTURE_POINT",
                    captureRole: "SURVEY", source: "test", requiredForReconstructionBridge: false) }),
            recaptureFlightMode: .continuousExperimental)
    }
}

final class SurveyContinuousRecaptureTests: XCTestCase {
    func testSchema14RoundTripAndCloudImport() throws {
        let mission = ContinuousRecaptureFixture.mission()
        let raw = try SurveyMissionJSON.encode(mission)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(root["schema_version"] as? Int, 14)
        XCTAssertEqual(try SurveyMissionJSON.decode(raw), mission)
        XCTAssertEqual(try SurveyCloudClient.validateMission(raw), mission)
    }

    func testStopCaptureStillExports13AndCodableLegacyDefaults() throws {
        var mission = ContinuousRecaptureFixture.mission()
        mission.recaptureFlightMode = .stopAndCapture
        let raw = try SurveyMissionJSON.encode(mission)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(root["schema_version"] as? Int, 13)
        XCTAssertNil(root["recapture_flight_mode"])
        XCTAssertEqual(try SurveyMissionJSON.decode(raw).recaptureFlightMode, .stopAndCapture)
        var stored = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(mission)) as? [String: Any])
        stored.removeValue(forKey: "recaptureFlightMode")
        XCTAssertEqual(try JSONDecoder().decode(SurveyMission.self,
            from: JSONSerialization.data(withJSONObject: stored)).recaptureFlightMode, .stopAndCapture)
    }

    func testRejectsUnknownMissingMisversionedModeAndMissingMetadata() throws {
        let raw = try SurveyMissionJSON.encode(ContinuousRecaptureFixture.mission())
        let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        for change: (String, Any?) in [("schema_version", 15), ("schema_version", 13),
                                      ("recapture_flight_mode", "UNKNOWN"), ("recapture_flight_mode", nil),
                                      ("active_mapping", NSNull())] {
            var root = source
            root[change.0] = change.1
            XCTAssertThrowsError(try SurveyMissionJSON.decode(String(decoding:
                JSONSerialization.data(withJSONObject: root), as: UTF8.self)))
        }
    }

    func testCloudCapabilityExplicitOptInAndOldManifestConfiguration() throws {
        let legacy = Data(#"{"name":"test","horizontalFOV":70,"minimumInterval":2}"#.utf8)
        var config = try JSONDecoder().decode(SurveyUploadConfiguration.self, from: legacy)
        XCTAssertEqual(config.recaptureFlightMode, .stopAndCapture)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: config.payload()) as? [String: Any])
        XCTAssertEqual(payload["supported_mission_schemas"] as? [Int], [13, 14])
        XCTAssertEqual(payload["recapture_flight_mode"] as? String, "STOP_AND_CAPTURE")
        config.recaptureFlightMode = .continuousExperimental
        payload = try XCTUnwrap(JSONSerialization.jsonObject(with: config.payload()) as? [String: Any])
        XCTAssertEqual(payload["recapture_flight_mode"] as? String, "CONTINUOUS_EXPERIMENTAL")
        XCTAssertEqual(try JSONDecoder().decode(SurveyUploadConfiguration.self,
            from: JSONEncoder().encode(config)), config)
    }

    func testOnlyAlignedInteriorPointsInSameRegionAreEligible() {
        let source = ContinuousRecaptureFixture.mission()
        XCTAssertTrue(SurveyContinuousRecapturePolicy.eligible(source, index: 2))
        XCTAssertFalse(SurveyContinuousRecapturePolicy.eligible(source, index: 0))
        XCTAssertFalse(SurveyContinuousRecapturePolicy.eligible(source, index: 5))
        XCTAssertFalse(SurveyContinuousRecapturePolicy.eligible(ContinuousRecaptureFixture.mission(spacing: 2.5), index: 2))
        for change in 0...6 {
            var mission = source
            switch change {
            case 0: mission.waypoints[3].headingDegrees = 20
            case 1: mission.waypoints[3].gimbalPitchDegrees = -90
            case 2: mission.waypoints[3].point.altitudeMeters = 31
            case 3: mission.waypoints[3].captureAction = .none
            case 4: mission.activeMapping?.passes[3].regionID = "other"
            case 5: mission.activeMapping?.passes[3].requiredForReconstructionBridge = true
            default: mission.waypoints[3].point.longitude += 0.001
            }
            XCTAssertFalse(SurveyContinuousRecapturePolicy.eligible(mission, index: 2))
        }
    }

    func testFreshPoseDoesNotRequireZeroSpeed() {
        let target = ContinuousRecaptureFixture.mission().waypoints[2]
        let pose = SurveyFollowerPose(latitude: target.point.latitude, longitude: target.point.longitude,
                                      altitudeMeters: 30, headingDegrees: 0)
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.connected = true
        telemetry.aircraftLocationValid = true
        telemetry.flightStateTimestamp = now
        telemetry.gimbalStateTimestamp = now
        telemetry.gimbalPitch = -45
        telemetry.velocityNorth = 2
        XCTAssertTrue(SurveyContinuousRecapturePolicy.poseReady(telemetry: telemetry, pose: pose, target: target, now: now))
        telemetry.gimbalStateTimestamp = now.addingTimeInterval(1)
        XCTAssertFalse(SurveyContinuousRecapturePolicy.poseReady(telemetry: telemetry, pose: pose, target: target, now: now))
        telemetry.gimbalStateTimestamp = now.addingTimeInterval(-1.01)
        XCTAssertFalse(SurveyContinuousRecapturePolicy.poseReady(telemetry: telemetry, pose: pose, target: target, now: now))
    }

    func test64GuidanceCasesKeepMovingAtCaptureAndBoundAckWait() throws {
        for spacing in [3.0, 5, 8, 15] {
            for speed in [0.3, 1, 2, 4] {
                for latency in [0.1, 0.5, 1, 3] {
                    let mission = ContinuousRecaptureFixture.mission(spacing: spacing)
                    var north = spacing
                    var requested: Double?
                    var confirmed = false
                    for step in 0...3_000 {
                        let time = Double(step) * 0.05
                        let pose = SurveyFollowerPose(latitude: 31 + north / 111_132,
                            longitude: 121, altitudeMeters: 30, headingDegrees: 0)
                        let command = try SurveyContinuousRecapturePolicy.command(mission, index: 2, pose: pose,
                            maximumSpeed: speed, maximumVerticalSpeed: 0.5)
                        XCTAssertLessThanOrEqual(hypot(command.forwardMetersPerSecond, command.rightMetersPerSecond), speed + 1e-6)
                        if let requested {
                            if time - requested >= latency { confirmed = true; break }
                        } else {
                            XCTAssertFalse(SurveyContinuousRecapturePolicy.missedWindow(mission, index: 2, pose: pose))
                            if command.reached {
                                requested = time
                                XCTAssertGreaterThan(command.forwardMetersPerSecond, 0)
                            }
                        }
                        north += command.forwardMetersPerSecond * 0.05
                        XCTAssertLessThanOrEqual(north, spacing * 2.5 + 0.2)
                    }
                    XCTAssertTrue(confirmed, "spacing=\(spacing) speed=\(speed) latency=\(latency)")
                }
            }
        }
    }
}

@MainActor
final class SurveyContinuousRuntimeTests: XCTestCase {
    private let missionKey = "openfly.survey.active-mission.v1"
    private let checkpointKey = "openfly.survey.execution-checkpoint.v2"

    private func prepare() async throws -> (SurveyRuntimeController, SurveyFakeProvider, SurveyMission) {
        let mission = ContinuousRecaptureFixture.mission()
        let checkpoint = try SurveyExecutionCheckpoint(missionID: mission.id, waypointIndex: 2,
            state: .paused, updatedAtEpochMillis: 1, executionLegIndex: .max, phase: .survey)
        UserDefaults.standard.set(try SurveyMissionJSON.encode(mission), forKey: missionKey)
        UserDefaults.standard.set(try SurveyExecutionCheckpointJSON.encode(checkpoint), forKey: checkpointKey)
        let provider = SurveyFakeProvider()
        let target = mission.waypoints[2].point
        provider.telemetry.aircraft = .init(latitude: target.latitude - 4 / 111_132, longitude: target.longitude)
        provider.telemetry.altitude = 30
        provider.telemetry.gimbalPitch = -45
        provider.telemetry.gimbalStateTimestamp = Date()
        provider.deferSurveyPhotoCompletion = true
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        XCTAssertEqual(runtime.restorePersistedMission()?.recaptureFlightMode, .continuousExperimental)
        runtime.resume(anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        await feed(runtime, provider, ticks: 55)
        XCTAssertEqual(runtime.snapshot.state, .running)
        XCTAssertEqual(provider.takePhotoRequests, 0)
        XCTAssertEqual(provider.takeOffRequests, 0)
        return (runtime, provider, mission)
    }

    private func feed(_ runtime: SurveyRuntimeController, _ provider: SurveyFakeProvider, ticks: Int = 5) async {
        for _ in 0..<ticks {
            provider.telemetry.flightStateTimestamp = Date()
            provider.telemetry.gimbalStateTimestamp = Date()
            runtime.updateTelemetry(provider.telemetry)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func testPendingPhotoKeepsMovingAndAdvancesOnlyAfterAck() async throws {
        let (runtime, provider, mission) = try await prepare()
        defer { runtime.abort("test cleanup") }
        provider.telemetry.aircraft.latitude = mission.waypoints[2].point.latitude
        await feed(runtime, provider)
        XCTAssertEqual(provider.takePhotoRequests, 1)
        XCTAssertEqual(runtime.snapshot.waypointIndex, 2)
        XCTAssertGreaterThan(try XCTUnwrap(provider.commands.last).forward, 0)
        await feed(runtime, provider)
        XCTAssertEqual(provider.takePhotoRequests, 1)
        let callback = try XCTUnwrap(provider.pendingPhotoCompletions.first)
        callback(nil)
        await feed(runtime, provider)
        XCTAssertEqual(runtime.snapshot.waypointIndex, 3)
        XCTAssertEqual(runtime.snapshot.photoCount, 1)
    }

    func testPhotoFailurePausesAndDoesNotAdvance() async throws {
        let (runtime, provider, mission) = try await prepare()
        defer { runtime.abort("test cleanup") }
        provider.telemetry.aircraft.latitude = mission.waypoints[2].point.latitude
        await feed(runtime, provider)
        let callback = try XCTUnwrap(provider.pendingPhotoCompletions.first)
        callback(FlightActionError.unavailable("camera rejected"))
        await feed(runtime, provider)
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertEqual(runtime.snapshot.waypointIndex, 2)
        XCTAssertEqual(runtime.snapshot.photoCount, 0)
        XCTAssertEqual(provider.commands.last, .zero)
    }

    func testLateCallbackAfterTakeoverCannotAdvance() async throws {
        let (runtime, provider, mission) = try await prepare()
        defer { runtime.abort("test cleanup") }
        provider.telemetry.aircraft.latitude = mission.waypoints[2].point.latitude
        await feed(runtime, provider)
        let callback = try XCTUnwrap(provider.pendingPhotoCompletions.first)
        runtime.manualTakeover()
        callback(nil)
        await feed(runtime, provider)
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertEqual(runtime.snapshot.waypointIndex, 2)
        XCTAssertEqual(runtime.snapshot.photoCount, 0)
        XCTAssertEqual(provider.commands.last, .zero)
    }

    func testMissedWindowPausesWithoutTakingPhoto() async throws {
        let (runtime, provider, mission) = try await prepare()
        defer { runtime.abort("test cleanup") }
        provider.telemetry.aircraft.latitude = mission.waypoints[2].point.latitude + 2.5 / 111_132
        await feed(runtime, provider)
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertEqual(provider.takePhotoRequests, 0)
        XCTAssertEqual(runtime.snapshot.waypointIndex, 2)
        XCTAssertEqual(provider.commands.last, .zero)
    }
}
