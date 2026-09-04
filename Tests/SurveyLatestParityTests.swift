import XCTest
import Network
import ImageIO
@testable import DJIVLNiOS

final class SurveyLatestParityTests: XCTestCase {
    func testSimulatorMapProjectionKeepsAircraftVisibleWithoutDJIGPS() throws {
        let simulator = FlightSimulatorStatus(
            available: true, active: true, stateReceived: true,
            motorsOn: true, flying: true,
            originLatitudeDegrees: 31.2, originLongitudeDegrees: 121.4,
            positionX: 95.3, positionY: 111.132, positionZ: -18,
            yawDegrees: 37, sampleMonotonicNanoseconds: 1
        )
        let point = try XCTUnwrap(SurveySimulatorMapProjection.point(from: simulator))
        XCTAssertEqual(point.latitude, 31.201, accuracy: 1e-6)
        XCTAssertEqual(point.longitude, 121.401, accuracy: 2e-5)
        XCTAssertEqual(point.altitudeMeters, 18, accuracy: 1e-9)

        var inactive = simulator
        inactive.active = false
        XCTAssertNil(SurveySimulatorMapProjection.point(from: inactive))
    }

    func testWaypointDivergenceStopsBeforeLongLegTimeout() {
        XCTAssertFalse(SurveyWaypointDivergencePolicy.shouldPause(
            bestErrorMeters: 40, currentErrorMeters: 53,
            lastProgressElapsedMillis: 1_000, nowElapsedMillis: 3_000
        ))
        XCTAssertTrue(SurveyWaypointDivergencePolicy.shouldPause(
            bestErrorMeters: 40, currentErrorMeters: 53,
            lastProgressElapsedMillis: 1_000, nowElapsedMillis: 3_500
        ))
        XCTAssertFalse(SurveyWaypointDivergencePolicy.shouldPause(
            bestErrorMeters: 40, currentErrorMeters: 51,
            lastProgressElapsedMillis: 1_000, nowElapsedMillis: 10_000
        ))
    }

    func testNadirMechanicalLimitDefersStartAndSkipsUnsettledEndFrame() {
        XCTAssertTrue(SurveyNadirGimbalPolicy.isMechanicalLimit(
            targetPitchDegrees: -90, settled: false, pitchAtStop: true
        ))
        XCTAssertFalse(SurveyNadirGimbalPolicy.isMechanicalLimit(
            targetPitchDegrees: -45, settled: false, pitchAtStop: true
        ))
        XCTAssertTrue(SurveyNadirGimbalPolicy.shouldDeferCaptureStart(
            action: .startDistanceInterval, mechanicalLimit: true
        ))
        XCTAssertFalse(SurveyNadirGimbalPolicy.canCapture(settled: false))
        XCTAssertTrue(SurveyNadirGimbalPolicy.shouldSkipEndFrame(
            action: .stopDistanceInterval, settled: false
        ))
        XCTAssertFalse(SurveyNadirGimbalPolicy.canStartDeferredCapture(
            phase: .recoveryToPause, settled: true, cameraReady: true
        ))
        XCTAssertFalse(SurveyNadirGimbalPolicy.canStartDeferredCapture(
            phase: .survey, settled: true, cameraReady: false
        ))
        XCTAssertTrue(SurveyNadirGimbalPolicy.canStartDeferredCapture(
            phase: .survey, settled: true, cameraReady: true
        ))
    }

    func testSurveyCaptureRecoveryRestoresOnlyInsideAnActiveSurveyPass() throws {
        let mission = try SurveyPlanner.plan(name: "capture-recovery", roi: rectangle(),
                                             constraints: .init())
        let start = try XCTUnwrap(mission.waypoints.firstIndex {
            $0.captureAction == .startDistanceInterval
        })
        let stop = try XCTUnwrap(mission.waypoints[(start + 1)...].firstIndex {
            $0.captureAction == .stopDistanceInterval
        })
        let expected = try XCTUnwrap(mission.waypoints[start].captureIntervalMeters)
        XCTAssertEqual(try XCTUnwrap(SurveyCaptureRecoveryPolicy.activeInterval(
            mission: mission, waypointIndex: start + 1, phase: .survey
        )), expected, accuracy: 1e-9)
        XCTAssertNil(SurveyCaptureRecoveryPolicy.activeInterval(
            mission: mission, waypointIndex: stop + 1, phase: .survey
        ))
        XCTAssertNil(SurveyCaptureRecoveryPolicy.activeInterval(
            mission: mission, waypointIndex: start + 1, phase: .recoveryToPause
        ))
    }

    func testBoundaryEditorAllowsConsecutiveAddsAndClearsSelectionAfterMutations() {
        var roi: [SurveyGeoPoint] = []
        var selected: Int?
        let points = rectangle()

        for (index, point) in points.enumerated() {
            XCTAssertEqual(
                SurveyBoundaryEditor.applyTap(
                    point, roi: &roi, selectedVertexIndex: &selected
                ),
                .added(index: index)
            )
            XCTAssertNil(selected)
        }
        XCTAssertEqual(roi, points)

        selected = 1
        let moved = SurveyGeoPoint(latitude: 31.2302, longitude: 121.4738)
        XCTAssertEqual(
            SurveyBoundaryEditor.applyTap(
                moved, roi: &roi, selectedVertexIndex: &selected
            ),
            .moved(index: 1)
        )
        XCTAssertEqual(roi[1], moved)
        XCTAssertNil(selected)

        selected = 2
        XCTAssertTrue(SurveyBoundaryEditor.undoLastVertex(
            roi: &roi, selectedVertexIndex: &selected
        ))
        XCTAssertNil(selected)

        selected = 0
        XCTAssertEqual(
            SurveyBoundaryEditor.deleteSelectedVertex(
                roi: &roi, selectedVertexIndex: &selected
            ),
            0
        )
        XCTAssertNil(selected)
    }

    func testPlannerSafetyPolicyBlocksReplacementStatesAndRequiresTerrainSource() throws {
        XCTAssertFalse(SurveyPlannerSafetyPolicy.editingLocked(for: .idle))
        XCTAssertTrue(SurveyPlannerSafetyPolicy.editingLocked(for: .arming))
        XCTAssertTrue(SurveyPlannerSafetyPolicy.editingLocked(for: .running))
        XCTAssertTrue(SurveyPlannerSafetyPolicy.editingLocked(for: .paused))
        XCTAssertFalse(SurveyPlannerSafetyPolicy.editingLocked(for: .completed))
        XCTAssertFalse(SurveyPlannerSafetyPolicy.editingLocked(for: .aborted))

        XCTAssertFalse(SurveyPlannerSafetyPolicy.canTerminate(.idle))
        XCTAssertTrue(SurveyPlannerSafetyPolicy.canTerminate(.arming))
        XCTAssertTrue(SurveyPlannerSafetyPolicy.canTerminate(.running))
        XCTAssertTrue(SurveyPlannerSafetyPolicy.canTerminate(.paused))
        XCTAssertFalse(SurveyPlannerSafetyPolicy.canTerminate(.completed))
        XCTAssertFalse(SurveyPlannerSafetyPolicy.canTerminate(.aborted))

        XCTAssertThrowsError(try SurveyPlannerSafetyPolicy.validateTerrainSource(
            enabled: true, hasLocalTerrain: false, hasDownloadedTerrain: false
        ))
        XCTAssertNoThrow(try SurveyPlannerSafetyPolicy.validateTerrainSource(
            enabled: true, hasLocalTerrain: true, hasDownloadedTerrain: false
        ))
        XCTAssertNoThrow(try SurveyPlannerSafetyPolicy.validateTerrainSource(
            enabled: false, hasLocalTerrain: false, hasDownloadedTerrain: false
        ))
    }

    func testPlannerTakeoffReferencePrefersHomeThenAircraft() {
        let home = SurveyGeoPoint(latitude: 31.1, longitude: 121.1)
        let aircraft = SurveyGeoPoint(latitude: 31.2, longitude: 121.2)
        let fallback = SurveyGeoPoint(latitude: 31.3, longitude: 121.3)
        XCTAssertEqual(
            SurveyPlannerSafetyPolicy.takeoffReference(
                home: home, aircraft: aircraft, fallback: fallback
            ),
            home
        )
        XCTAssertEqual(
            SurveyPlannerSafetyPolicy.takeoffReference(
                home: nil, aircraft: aircraft, fallback: fallback
            ),
            aircraft
        )
        XCTAssertEqual(
            SurveyPlannerSafetyPolicy.takeoffReference(
                home: nil, aircraft: nil, fallback: fallback
            ),
            fallback
        )
    }

    func testRecoveryPointRoundTripAndRemainingEstimate() throws {
        let recovery = SurveyGeoPoint(latitude: 31.2304, longitude: 121.4737, altitudeMeters: 35)
        let checkpoint = try SurveyExecutionCheckpoint(
            missionID: "resume", waypointIndex: 0, state: .paused,
            updatedAtEpochMillis: 1, executionLegIndex: 0, phase: .survey,
            recoveryPoint: recovery
        )
        XCTAssertEqual(
            try SurveyExecutionCheckpointJSON.decode(SurveyExecutionCheckpointJSON.encode(checkpoint)),
            checkpoint
        )

        var constraints = SurveyConstraints()
        constraints.speedMetersPerSecond = 2
        let mission = try SurveyPlanner.plan(name: "remaining", roi: rectangle(), constraints: constraints)
        let machine = SurveyExecutionStateMachine(mission: mission)
        let estimate = machine.remainingEstimate(
            currentPosition: mission.waypoints[0].point,
            currentHeadingDegrees: 0,
            currentHorizontalSpeedMetersPerSecond: 2,
            currentVerticalSpeedMetersPerSecond: 0.5
        )
        XCTAssertGreaterThan(estimate.currentSectionSeconds, 0)
        XCTAssertGreaterThanOrEqual(estimate.totalSeconds, estimate.currentSectionSeconds)
    }

    func testGlobalBuildingTilesMatchAndroidContract() throws {
        let tiles = try GlobalBuildingHeightTiles.covering(rectangle())
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertLessThanOrEqual(tiles.count, 9)
        let url = try GlobalBuildingHeightTiles.url(
            template: "https://example.test/{x}/{y}?bbox={west},{south},{east},{north}",
            tile: tiles[0]
        )
        XCTAssertFalse(url.absoluteString.contains("{x}"))
        XCTAssertFalse(url.absoluteString.contains("{y}"))
    }

    func testSchema13RoundTripPreservesSelectedViewsHeadingTerrainAndSpeeds() throws {
        var constraints = SurveyConstraints()
        constraints.collectionMode = .obliqueFiveDirection
        constraints.enabledCaptureViews = [.nadir, .leftOblique]
        constraints.obliqueHeadingMode = .fixedCaptureDirection
        constraints.speedMetersPerSecond = 2
        constraints.obliqueSpeedMetersPerSecond = 6
        constraints.descentSpeedMetersPerSecond = 1.5
        var mission = try SurveyPlanner.plan(name: "schema11", roi: rectangle(), camera: .djiMini2,
                                             constraints: constraints)
        mission.terrainPlan = .init(sourceName: "fixture", sourceSHA256: String(repeating: "a", count: 64),
            epsg: 4326, targetAGLMeters: 60, takeoffTerrainElevationMeters: 3,
            sampleSpacingMeters: 3, minimumTerrainElevationMeters: 2,
            maximumTerrainElevationMeters: 8, minimumWaypointAltitudeMeters: 59,
            maximumWaypointAltitudeMeters: 65, realFlightVerified: false,
            takeoffReference: .init(
                point: .init(latitude: 31.0, longitude: 121.0, altitudeMeters: 0),
                source: .homeLocation,
                capturedAtEpochMillis: 1_725_000_000_123
            ),
            sourceKind: .surfaceDSM,
            bareEarthBaseSHA256: String(repeating: "b", count: 64))
        let raw = try SurveyMissionJSON.encode(mission)
        let decoded = try SurveyMissionJSON.decode(raw)
        XCTAssertEqual(decoded, mission)
        XCTAssertTrue(raw.contains("\"schema_version\" : 13"))
        XCTAssertTrue(raw.contains("\"oblique_speed_mps\" : 6"))
        XCTAssertTrue(raw.contains("\"descent_speed_mps\" : 1.5"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        root["schema_version"] = 11
        var legacyConstraints = try XCTUnwrap(root["constraints"] as? [String: Any])
        legacyConstraints.removeValue(forKey: "oblique_speed_mps")
        root["constraints"] = legacyConstraints
        let legacyData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let legacy = try SurveyMissionJSON.decode(String(decoding: legacyData, as: UTF8.self))
        XCTAssertEqual(legacy.constraints.obliqueSpeedMetersPerSecond, 2)
        XCTAssertEqual(legacy.constraints.descentSpeedMetersPerSecond, 2)
    }

    func testSchema12ActiveRecapturePointCaptureRoundTripAndValidation() throws {
        let point = SurveyGeoPoint(latitude: 31.0, longitude: 121.0, altitudeMeters: 30)
        let waypoint = SurveyWaypoint(point: point, headingDegrees: 45, gimbalPitchDegrees: -45,
            kind: .capturePoint, captureAction: .captureOnReach, captureIntervalMeters: nil,
            passIndex: 0, captureView: .localOblique)
        let metadata = ActiveMappingMetadata(
            selectionMethod: "unit-test", groundTruthUsed: false,
            gsUsedForSelection: true, ordinaryGPSUsed: true,
            sourceCaptureCount: 1, surveyCaptureCount: 1, bridgeCaptureCount: 0,
            sourceEstimatedRouteDistanceMeters: 0,
            regions: [.init(regionID: "R1", priority: 1, kind: "SMALL_CROSS",
                            riskScore: 0.8, passIndices: [0], suggestedSurveyPhotos: 1)],
            passes: [.init(passIndex: 0, regionID: "R1", role: "SURVEY",
                           captureRole: "POINT", source: "fixture",
                           requiredForReconstructionBridge: false)])
        let mission = SurveyMission(name: "active-point", cameraProfile: .djiMini2,
            constraints: .init(),
            roi: [.init(latitude: 30.9999, longitude: 120.9999),
                  .init(latitude: 30.9999, longitude: 121.0001),
                  .init(latitude: 31.0001, longitude: 121.0001),
                  .init(latitude: 31.0001, longitude: 120.9999)],
            waypoints: [waypoint], estimatedPathMeters: 0,
            estimatedPhotoCount: 1, estimatedFlightSeconds: 0,
            activeMapping: metadata)

        let report = try ActiveRecaptureMissionValidator.validate(mission)
        XCTAssertEqual(report.captureCount, 1)
        XCTAssertEqual(report.pointCaptureCount, 1)
        let raw = try SurveyMissionJSON.encode(mission)
        let decoded = try SurveyMissionJSON.decode(raw)
        XCTAssertEqual(decoded, mission)
        XCTAssertEqual(try SurveyCaptureSchedule.build(decoded).first?.captureView, .localOblique)
    }

    func testCameraCatalogResolvesAliasesAndFallsBackSafely() {
        XCTAssertEqual(SurveyCameraProfileCatalog.resolve("DJI Mini 2").profile.id, "dji-mini-2-photo-4x3")
        XCTAssertTrue(SurveyCameraProfileCatalog.resolve("M3E").verifiedProfile)
        XCTAssertFalse(SurveyCameraProfileCatalog.resolve("UNKNOWN").verifiedProfile)
    }

    @MainActor
    func testHILSurveyFrameIsSavedWithMetadataInVisibleSessionTree() async throws {
        let log = EventLog()
        defer { try? FileManager.default.removeItem(at: log.sessionDirectory) }
        let mission = try SurveyPlanner.plan(name: "hil-capture", roi: rectangle(), constraints: .init())
        var frame = CameraFrame.simulator(sequence: 73)
        frame.sourceFrameID = 7003
        frame.sourcePoseSequence = 6002
        frame.sourceCapturePeerMonotonicNanoseconds = 5_001
        var telemetry = FlightTelemetry()
        telemetry.aircraft = .init(latitude: 31.2304, longitude: 121.4737)
        telemetry.altitude = 32
        telemetry.heading = 48
        telemetry.gimbalPitch = -45

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            log.captureSurveyFrame(frame: frame, mission: mission, reason: "endpoint",
                                   telemetry: telemetry, executionLegIndex: 4,
                                   waypointIndex: 3) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }

        let directory = log.sessionDirectory
            .appendingPathComponent("survey", isDirectory: true)
            .appendingPathComponent(mission.id, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)
        let image = try XCTUnwrap(files.first { $0.pathExtension == "jpg" })
        let metadata = try XCTUnwrap(files.first { $0.pathExtension == "json" })
        let savedImage = try Data(contentsOf: image)
        XCTAssertNotEqual(savedImage, frame.jpeg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(savedImage as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let gps = try XCTUnwrap(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? NSNumber).doubleValue,
                       31.2304, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSLongitude] as? NSNumber).doubleValue,
                       121.4737, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(gps[kCGImagePropertyGPSImgDirection] as? NSNumber).doubleValue,
                       48, accuracy: 0.01)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: metadata)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? String, SurveyUeBridgeController.schema)
        XCTAssertEqual(object["type"] as? String, "capture")
        XCTAssertEqual((object["frame_id"] as? NSNumber)?.uint64Value, 7003)
        XCTAssertEqual((object["pose_sequence"] as? NSNumber)?.uint64Value, 6002)
        let frameMetadata = try XCTUnwrap(object["frame"] as? [String: Any])
        XCTAssertEqual((frameMetadata["capture_peer_monotonic_ns"] as? NSNumber)?.uint64Value, 5_001)
        XCTAssertEqual(frameMetadata["format"] as? String, frame.sourceFormat)
        let execution = try XCTUnwrap(object["execution"] as? [String: Any])
        XCTAssertEqual((execution["execution_leg_index"] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((execution["waypoint_index"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(object["saved_path"] as? String, image.path)
        XCTAssertNotNil(object["coordinate_contract"] as? [String: Any])
        XCTAssertNotNil(object["pose"] as? [String: Any])
    }

    @MainActor
    func testSimulatorOriginPersistsIntoNextMockStart() async throws {
        let provider = MockFlightProvider()
        let origin = GeoPoint(latitude: 31.181234, longitude: 121.493210)
        try provider.setSimulatorOrigin(origin)
        try await provider.setSimulator(enabled: true)
        XCTAssertEqual(provider.simulatorStatus.originLatitudeDegrees, origin.latitude, accuracy: 0.000001)
        XCTAssertEqual(provider.simulatorStatus.originLongitudeDegrees, origin.longitude, accuracy: 0.000001)
        XCTAssertThrowsError(try provider.setSimulatorOrigin(.init(latitude: 30, longitude: 120)))
    }

    func testCaptureViewFilterKeepsTerrainControlPoints() throws {
        var constraints = SurveyConstraints()
        constraints.collectionMode = .obliqueFiveDirection
        let mission = try SurveyPlanner.plan(name: "filter", roi: rectangle(), constraints: constraints)
        let filtered = try SurveyMissionCaptureViewFilter.select(mission, enabledViews: [.leftOblique])
        XCTAssertEqual(filtered.constraints.enabledCaptureViews, [.leftOblique])
        XCTAssertTrue(filtered.waypoints.allSatisfy { $0.captureView == .leftOblique })
        XCTAssertEqual(try SurveyCaptureSchedule.build(filtered).count, filtered.estimatedPhotoCount)
        let schedule = try SurveyCaptureSchedule.build(filtered)
        let json = try SurveyCaptureScheduleJSON.encode(mission: filtered, events: schedule)
        XCTAssertTrue(json.contains("\"capture_events\""))
    }

    func testTerrainPlannerAddsDenseControlPointsAndEnvelope() throws {
        let mission = try SurveyPlanner.plan(name: "terrain", roi: rectangle(), constraints: .init())
        let source = RampTerrain()
        let result = try SurveyTerrainPlanner.apply(to: mission, terrain: source,
            takeoffPoint: rectangle()[0], sourceSHA256: String(repeating: "b", count: 64))
        XCTAssertGreaterThan(result.mission.waypoints.count, mission.waypoints.count)
        XCTAssertNotNil(result.mission.terrainPlan)
        XCTAssertLessThanOrEqual(result.safety.maximumRequiredVerticalSpeedMetersPerSecond,
                                 SurveyWaypointFollower.maxVerticalSpeedMetersPerSecond * 0.9 + 1e-6)
    }

    func testHILPoseWireContractHasExpectedLengthAndHeader() throws {
        let pose = OpenFlyHILProtocol.Pose(sampleMonotonicNanoseconds: 1,
            originLatitudeDegrees: 31, originLongitudeDegrees: 121,
            eastMeters: 1, northMeters: 2, upMeters: 3, rollDegrees: 4, pitchDegrees: 5,
            headingDegreesClockwiseFromNorth: 6, velocityNorthMetersPerSecond: 7,
            velocityEastMetersPerSecond: 8, velocityUpMetersPerSecond: 9, gimbalPitchDegrees: -45,
            commandForwardMetersPerSecond: 1, commandRightMetersPerSecond: 2,
            commandUpMetersPerSecond: 3, commandYawRateDegreesPerSecond: 4,
            flightStateAgeMilliseconds: 20, measuredSimulatorHz: 20, stateFlags: 7)
        let wire = OpenFlyHILProtocol.encodePose(sessionID: 12, sequence: 34, value: pose)
        XCTAssertEqual(wire.count, OpenFlyHILProtocol.headerBytes + OpenFlyHILProtocol.posePayloadBytes)
        let decoded = try OpenFlyHILProtocol.decode(wire)
        XCTAssertEqual(decoded.header.type, .pose)
        XCTAssertEqual(decoded.header.sessionID, 12)
        XCTAssertEqual(decoded.header.sequence, 34)
        XCTAssertEqual(
            wire.map { String(format: "%02x", $0) }.joined(),
            "4f46484c0001000200000000000000000000000c000000000000002200000098" +
                "0000000000000001403f000000000000405e4000000000003ff0000000000000" +
                "4000000000000000400800000000000040100000000000004014000000000000" +
                "4018000000000000401c00000000000040200000000000004022000000000000" +
                "c0468000000000003ff000000000000040000000000000004008000000000000" +
                "40100000000000000000001441a000000000000700000000"
        )
    }

    func testHILEventRejectsInvalidKindUtf8AndInfiniteScore() throws {
        func payload(kind: UInt32 = 0, score: Double = 0.5, reason: Data = Data("ok".utf8)) -> Data {
            var data = Data()
            data.appendHILBE(UInt64(1)); data.appendHILBE(kind)
            data.appendHILBE(score.bitPattern); data.appendHILBE(UInt64(2))
            data.appendHILBE(UInt32(reason.count)); data.append(reason)
            return data
        }
        XCTAssertThrowsError(try OpenFlyHILProtocol.decodeEvent(payload(kind: 9)))
        XCTAssertThrowsError(try OpenFlyHILProtocol.decodeEvent(payload(reason: Data([0x80]))))
        XCTAssertThrowsError(try OpenFlyHILProtocol.decodeEvent(payload(score: .infinity)))
    }

    @MainActor
    func testSurveyUeBridgeMatchesAndroidEnvelopeAndPeerResolution() throws {
        let mission = try SurveyPlanner.plan(name: "ue-contract", roi: rectangle(), constraints: .init())
        let data = try SurveyUeBridgeController.encodeMission(mission)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["schema"] as? String, "openfly.survey.ue.v1")
        XCTAssertEqual(root["type"] as? String, "mission")
        let coordinate = try XCTUnwrap(root["coordinate_contract"] as? [String: Any])
        XCTAssertEqual(coordinate["geodetic"] as? String, "WGS84")
        XCTAssertEqual(coordinate["local_world"] as? String, "ENU")
        XCTAssertEqual(coordinate["vehicle_body"] as? String, "FRU")
        XCTAssertNotNil(root["mission"] as? [String: Any])

        let resolved = try SurveyUeBridgeController.resolvedBaseURL(
            configured: "http://192.168.1.2:30010", peerHost: "172.20.10.4")
        XCTAssertEqual(resolved.scheme, "http")
        XCTAssertEqual(resolved.host, "172.20.10.4")
        XCTAssertEqual(resolved.port, 30_010)

        var telemetry = FlightTelemetry()
        telemetry.aircraft = .init(latitude: 31.23, longitude: 121.47)
        telemetry.altitude = 18; telemetry.heading = 24; telemetry.gimbalPitch = -45
        var runtime = SurveyRuntimeSnapshot()
        runtime.state = .running; runtime.phase = .survey
        runtime.missionID = mission.id; runtime.currentTarget = mission.waypoints[0]
        let telemetryRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with:
            SurveyUeBridgeController.encodeTelemetry(
                telemetry: telemetry,
                simulator: .init(available: true, active: true, stateReceived: true,
                                 motorsOn: true, flying: true, message: "test"),
                runtime: runtime)) as? [String: Any])
        XCTAssertEqual(telemetryRoot["type"] as? String, "telemetry")
        XCTAssertNotNil(telemetryRoot["dji_simulator"] as? [String: Any])

        let targetRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with:
            SurveyUeBridgeController.encodeTarget(missionID: mission.id, runtime: runtime,
                                                  phase: .survey,
                                                  target: mission.waypoints[0])) as? [String: Any])
        XCTAssertEqual(targetRoot["type"] as? String, "target")
        XCTAssertNotNil(targetRoot["target"] as? [String: Any])

        let capture = SurveyFrameCaptureRecord(
            frame: .init(sequence: 7, capturedAt: Date(timeIntervalSince1970: 1),
                         jpeg: Data([1]), width: 2, height: 3,
                         sourceFrameID: 70, sourcePoseSequence: 60,
                         sourceCapturePeerMonotonicNanoseconds: 50),
            missionID: mission.id, reason: "endpoint", telemetry: telemetry,
            executionLegIndex: 4, waypointIndex: 3,
            imageURL: URL(fileURLWithPath: "/tmp/frame.jpg"),
            metadataURL: URL(fileURLWithPath: "/tmp/frame.json"))
        let captureRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with:
            SurveyUeBridgeController.encodeCapture(capture)) as? [String: Any])
        XCTAssertEqual(captureRoot["type"] as? String, "capture")
        XCTAssertEqual((captureRoot["frame_id"] as? NSNumber)?.uint64Value, 70)
        XCTAssertEqual((captureRoot["pose_sequence"] as? NSNumber)?.uint64Value, 60)
    }

    func testFiveDirectionRoutePaletteMatchesAndroidAndUsesDistinctColors() {
        let colors = SurveyCaptureView.allCases.map(SurveyRoutePalette.argb)
        XCTAssertEqual(Set(colors).count, SurveyCaptureView.allCases.count)
        XCTAssertEqual(SurveyRoutePalette.argb(for: .nadir), 0xFFFFB547)
        XCTAssertEqual(SurveyRoutePalette.argb(for: .forwardOblique), 0xFFFF6B6B)
        XCTAssertEqual(SurveyRoutePalette.argb(for: .backwardOblique), 0xFFB77BFF)
        XCTAssertEqual(SurveyRoutePalette.argb(for: .leftOblique), 0xFF55D69E)
        XCTAssertEqual(SurveyRoutePalette.argb(for: .rightOblique), 0xFF55BDEB)
    }

    @MainActor
    func testHILDefaultsToAutomaticHotspotAndPersistsConfiguration() {
        let suite = "OpenFlyHILControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = OpenFlyHILController(defaults: defaults)
        XCTAssertEqual(first.configuration.mode, .hotspot)
        XCTAssertEqual(first.configuration.hotspotDiscoveryMode, .automatic)
        first.configuration.mode = .lan
        first.configuration.host = "192.168.1.45"
        first.configuration.poseSendHz = 50

        let reopened = OpenFlyHILController(defaults: defaults)
        XCTAssertEqual(reopened.configuration.mode, .lan)
        XCTAssertEqual(reopened.configuration.host, "192.168.1.45")
        XCTAssertEqual(reopened.configuration.poseSendHz, 50)
    }

    @MainActor
    func testHILAutomaticDiscoveryRemembersAuthenticatedPeerAheadOfFallbacks() async throws {
        let suite = "OpenFlyHILRememberedPeerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let peer = try HILTestPeer(serverPort: 31_230, phonePort: 31_231)
        peer.replyToHelloSource = true
        peer.start()
        defer { peer.stop() }

        let first = OpenFlyHILController(defaults: defaults, listensForFrames: false)
        first.configuration = .init(
            mode: .hotspot, host: "", hotspotDiscoveryMode: .automatic,
            hotspotHost: "", udpServerPort: 31_230, udpLocalPort: 31_231,
            frameTCPPort: 31_232, poseSendHz: 100, simulatorStateHz: 100,
            heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: ["192.0.2.200", "127.0.0.1"]
        )
        XCTAssertEqual(first.automaticHotspotProbeHosts,
                       ["192.0.2.200", "127.0.0.1"])
        first.start()
        let firstLocked = await waitUntil(timeout: 3) {
            first.status.peerFresh && first.status.peerHost == "127.0.0.1"
        }
        XCTAssertTrue(firstLocked)
        XCTAssertEqual(defaults.string(
            forKey: OpenFlyHILController.lastAutomaticPeerDefaultsKey
        ), "127.0.0.1")
        first.stop()

        // Recreate the controller exactly as an app relaunch would. The last
        // authenticated address moves ahead of the fixed scan, while every
        // original fallback remains present and eligible in the same round.
        let reopened = OpenFlyHILController(defaults: defaults, listensForFrames: false)
        XCTAssertEqual(reopened.configuration.hotspotDiscoveryMode, .automatic)
        XCTAssertEqual(reopened.automaticHotspotProbeHosts,
                       ["127.0.0.1", "192.0.2.200"])
        reopened.start()
        defer { reopened.stop() }
        let reopenedLocked = await waitUntil(timeout: 4) {
            reopened.status.peerFresh && reopened.status.peerHost == "127.0.0.1"
        }
        XCTAssertTrue(reopenedLocked,
                      "a new automatic session must recover the last authenticated UE IP")
    }

    @MainActor
    func testHILStaleRememberedPeerStillScansConfiguredFallback() async throws {
        let suite = "OpenFlyHILStalePeerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("192.0.2.201",
                     forKey: OpenFlyHILController.lastAutomaticPeerDefaultsKey)

        let peer = try HILTestPeer(serverPort: 31_233, phonePort: 31_234)
        peer.replyToHelloSource = true
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController(defaults: defaults, listensForFrames: false)
        controller.configuration = .init(
            mode: .hotspot, host: "", hotspotDiscoveryMode: .automatic,
            hotspotHost: "", udpServerPort: 31_233, udpLocalPort: 31_234,
            frameTCPPort: 31_235, poseSendHz: 100, simulatorStateHz: 100,
            heartbeatTimeoutMilliseconds: 250,
            legacyDiscoveryHosts: ["127.0.0.1"]
        )
        XCTAssertEqual(controller.automaticHotspotProbeHosts,
                       ["192.0.2.201", "127.0.0.1"])
        controller.start()
        defer { controller.stop() }
        let fallbackLocked = await waitUntil(timeout: 3) {
            controller.status.peerFresh && controller.status.peerHost == "127.0.0.1"
        }
        XCTAssertTrue(fallbackLocked,
                      "a stale remembered IP must not block the fixed fallback scan")
    }

    @MainActor
    func testHILManualAndLANTargetsIgnoreRememberedPeerAndInvalidCacheIsDiscarded() {
        let suite = "OpenFlyHILManualPriorityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("not-an-ip",
                     forKey: OpenFlyHILController.lastAutomaticPeerDefaultsKey)
        let invalid = OpenFlyHILController(defaults: defaults, listensForFrames: false)
        XCTAssertNil(defaults.string(
            forKey: OpenFlyHILController.lastAutomaticPeerDefaultsKey
        ))
        XCTAssertFalse(invalid.automaticHotspotProbeHosts.contains("not-an-ip"))

        defaults.set("127.0.0.1",
                     forKey: OpenFlyHILController.lastAutomaticPeerDefaultsKey)
        let explicit = OpenFlyHILController(defaults: defaults, listensForFrames: false)
        explicit.configuration.mode = .hotspot
        explicit.configuration.hotspotDiscoveryMode = .manual
        explicit.configuration.hotspotHost = "192.168.50.8"
        XCTAssertEqual(explicit.configuration.destinationHost, "192.168.50.8")
        XCTAssertTrue(explicit.automaticHotspotProbeHosts.isEmpty,
                      "manual hotspot mode must never be overwritten by the cache")

        explicit.configuration.mode = .lan
        explicit.configuration.host = "10.0.0.45"
        XCTAssertEqual(explicit.configuration.destinationHost, "10.0.0.45")
        XCTAssertTrue(explicit.automaticHotspotProbeHosts.isEmpty,
                      "LAN mode must never be overwritten by the hotspot cache")
    }

    @MainActor
    func testHILHotspotAutomaticLegacyDiscoveryRecoversAndCarriesVirtualFrame() async throws {
        let peer = try HILTestPeer(serverPort: 31_120, phonePort: 31_121)
        peer.replyToHelloSource = true
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        var diagnostics: [String] = []
        controller.onDiagnostic = { diagnostics.append($0) }
        controller.configuration = .init(mode: .hotspot, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_120, udpLocalPort: 31_121,
            frameTCPPort: 31_122, poseSendHz: 100, simulatorStateHz: 100,
            heartbeatTimeoutMilliseconds: 250, legacyDiscoveryHosts: ["127.0.0.1"])
        controller.useVirtualFrames = true
        let frame = expectation(description: "authenticated virtual frame")
        controller.onVirtualFrame = { value in
            XCTAssertEqual(value.width, 2)
            XCTAssertEqual(value.height, 2)
            XCTAssertEqual(value.sourceFrameID, 1)
            XCTAssertEqual(value.sourcePoseSequence, 1)
            XCTAssertEqual(value.sourceCapturePeerMonotonicNanoseconds, 1)
            XCTAssertEqual(value.sourceFormat, "jpeg")
            frame.fulfill()
        }
        controller.start()
        defer { controller.stop() }

        let peerReady = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(peerReady)
        XCTAssertTrue(diagnostics.contains { $0.contains("启动 mode=hotspot") })
        XCTAssertTrue(diagnostics.contains { $0.contains("UDP listener ready") })
        XCTAssertTrue(diagnostics.contains { $0.contains("UDP peer lock host=127.0.0.1") })
        controller.submit(telemetry: FlightTelemetry(), simulator: .init(available: true,
            active: true, stateReceived: true, motorsOn: true, flying: true,
            positionX: 20, positionY: 10, positionZ: -30, rollDegrees: 40,
            pitchDegrees: 50, yawDegrees: 60, sampleMonotonicNanoseconds: 0,
            measuredUpdateHz: 100, message: "invalid-no-raw-sample"))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(peer.poseCount, 0, "raw simulator timestamp=0 must never emit a pose")

        var rawTelemetry = FlightTelemetry()
        rawTelemetry.heading = 177 // Must not leak onto the raw SimulatorState HIL wire.
        let poseSample = DispatchTime.now().uptimeNanoseconds
        controller.submit(telemetry: rawTelemetry, simulator: .init(available: true,
            active: true, stateReceived: true, motorsOn: true, flying: true,
            originLatitudeDegrees: 31.501, originLongitudeDegrees: 121.502,
            positionX: 2, positionY: 1, positionZ: -3, rollDegrees: 4,
            pitchDegrees: 5, yawDegrees: 6, sampleMonotonicNanoseconds: poseSample,
            measuredUpdateHz: 100, message: "test"),
            command: .init(forward: 0.4, right: -0.3, up: 0.2, yawRate: 7))

        let connected = await waitUntil { controller.status.peerFresh && peer.poseCount >= 3 }
        XCTAssertTrue(connected)
        XCTAssertEqual(controller.status.peerHost, "127.0.0.1")
        let posePayload = try XCTUnwrap(peer.lastPosePayload)
        XCTAssertEqual(hilUInt64(posePayload, at: 0), poseSample)
        XCTAssertEqual(hilDouble(posePayload, at: 8), 31.501, accuracy: 0.000_001)
        XCTAssertEqual(hilDouble(posePayload, at: 16), 121.502, accuracy: 0.000_001)
        XCTAssertEqual(hilDouble(posePayload, at: 24), 1, accuracy: 0.001,
                       "Android-compatible default maps SimulatorState.positionY to ENU east")
        XCTAssertEqual(hilDouble(posePayload, at: 32), 2, accuracy: 0.001,
                       "Android-compatible default maps SimulatorState.positionX to ENU north")
        XCTAssertEqual(hilDouble(posePayload, at: 64), 6, accuracy: 0.001)
        XCTAssertEqual(hilDouble(posePayload, at: 104), 0.4, accuracy: 0.001)
        let listening = await waitUntil { controller.status.frameListening }
        XCTAssertTrue(listening)
        peer.sendFrame(port: 31_122)
        await fulfillment(of: [frame], timeout: 2)
        let frameConnected = await waitUntil { controller.status.frameConnected }
        XCTAssertTrue(frameConnected)

        peer.responds = false
        let stale = await waitUntil(timeout: 2) {
            !controller.status.peerFresh && !controller.status.frameConnected
        }
        XCTAssertTrue(stale)
        peer.responds = true
        let recovered = await waitUntil(timeout: 2) { controller.status.peerFresh }
        XCTAssertTrue(recovered)
    }

    @MainActor
    func testHILRejectsRepeatedOrOutOfOrderSourceFrameIDs() async throws {
        let peer = try HILTestPeer(serverPort: 31_140, phonePort: 31_141)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_140,
            udpLocalPort: 31_141, frameTCPPort: 31_142, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        var acceptedIDs: [UInt64] = []
        controller.onVirtualFrame = { frame in
            if let id = frame.sourceFrameID { acceptedIDs.append(id) }
        }
        controller.useVirtualFrames = true
        controller.start()
        defer { controller.stop() }

        let ready = await waitUntil {
            controller.status.peerFresh && controller.status.frameListening
        }
        XCTAssertTrue(ready)
        peer.sendFrame(port: 31_142, frameID: 7, repetitions: 3)
        let replayRejected = await waitUntil {
            acceptedIDs.count == 1 && controller.status.rejectedFrameCount == 2
        }
        XCTAssertTrue(replayRejected)
        XCTAssertEqual(acceptedIDs, [7])
        XCTAssertEqual(controller.latestVirtualFrame?.sourceFrameID, 7)
        XCTAssertEqual(controller.latestVirtualFrame?.sequence, 1)
    }

    @MainActor
    func testHILUDPReceiptAgeIsMeasuredBeforeMainActorPublication() async throws {
        let peer = try HILTestPeer(serverPort: 31_150, phonePort: 31_151)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_150,
            udpLocalPort: 31_151, frameTCPPort: 31_152, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 250,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }

        let ready = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(ready)
        peer.responds = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            peer.sendHeartbeat()
        }
        blockCurrentThread(for: 0.45)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertFalse(controller.status.peerFresh,
                       "a datagram received before a MainActor stall must not become fresh when published later")
    }

    @MainActor
    func testHILReplayAndMalformedUDPDoNotRefreshPeer() async throws {
        let peer = try HILTestPeer(serverPort: 31_190, phonePort: 31_191)
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_190,
            udpLocalPort: 31_191, frameTCPPort: 31_192, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 250,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let linkReady = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(linkReady)
        peer.responds = false
        try await Task.sleep(nanoseconds: 160_000_000)
        peer.sendHeartbeat(sequence: peer.currentReplySequence)
        peer.sendMalformedHeartbeat()
        try await Task.sleep(nanoseconds: 130_000_000)
        XCTAssertFalse(controller.status.peerFresh,
                       "duplicate and malformed packets must not extend authenticated freshness")
    }

    @MainActor
    func testHILAcceptsUniqueReorderedUDPButRejectsDuplicateReplay() async throws {
        let peer = try HILTestPeer(serverPort: 31_224, phonePort: 31_225)
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_224,
            udpLocalPort: 31_225, frameTCPPort: 31_226, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let linkReady = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(linkReady)
        peer.responds = false
        try await Task.sleep(nanoseconds: 80_000_000)
        let before = controller.status.receivedPacketCount
        let high = peer.currentReplySequence + 100
        peer.sendHeartbeat(sequence: high)
        peer.sendHeartbeat(sequence: high - 1)
        let bothAccepted = await waitUntil {
            controller.status.receivedPacketCount >= before + 2
        }
        XCTAssertTrue(bothAccepted,
                      "adjacent unique UDP reordering must not look like a link failure")
        let accepted = controller.status.receivedPacketCount
        peer.sendHeartbeat(sequence: high - 1)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(controller.status.receivedPacketCount, accepted,
                       "an exact replay must not refresh the authenticated session")
    }

    @MainActor
    func testHILInboundBurstUsesBatchedMainActorDrainAndPreservesEverySafetyEvent() async throws {
        let peer = try HILTestPeer(serverPort: 31_236, phonePort: 31_237)
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_236,
            udpLocalPort: 31_237, frameTCPPort: 31_238, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        var safetyReasons: [String] = []
        controller.onSafetyEvent = { safetyReasons.append($0.reason) }
        controller.start()
        defer { controller.stop() }
        let initialPeerReady = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(initialPeerReady)

        peer.responds = false
        let receivedBefore = controller.status.receivedPacketCount
        let drainsBefore = controller.inboundUDPDrainCount
        let pongsBefore = peer.receivedCount(type: .pong)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.03) {
            peer.sendInboundBurst(
                controlPacketCount: 60,
                eventReasons: ["collision-a", "stop-b", "emergency-c"]
            )
        }
        blockCurrentThread(for: 0.30)

        let fullyDrained = await waitUntil(timeout: 2) {
            safetyReasons.count == 3
                && controller.status.receivedPacketCount >= receivedBefore + 63
        }
        XCTAssertTrue(fullyDrained)
        XCTAssertEqual(safetyReasons, ["collision-a", "stop-b", "emergency-c"],
                       "safety EVENTs must never be coalesced or reordered")
        let drainPasses = controller.inboundUDPDrainCount - drainsBefore
        XCTAssertLessThan(drainPasses, 20,
                          "a control burst must not create one MainActor task per UDP packet")
        let pongReplies = peer.receivedCount(type: .pong) - pongsBefore
        XCTAssertGreaterThan(pongReplies, 0)
        XCTAssertLessThan(pongReplies, 20,
                          "PING side effects should collapse to the newest valid ping per batch")
    }

    @MainActor
    func testHILDelayedSafetyEventSurvivesMainActorTimeoutWithoutRefreshingPeer() async throws {
        let peer = try HILTestPeer(serverPort: 31_251, phonePort: 31_252)
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController(listensForFrames: false)
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_251,
            udpLocalPort: 31_252, frameTCPPort: 31_253, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 250,
            legacyDiscoveryHosts: [])
        var safetyReasons: [String] = []
        controller.onSafetyEvent = { safetyReasons.append($0.reason) }
        controller.start()
        defer { controller.stop() }
        let initiallyFresh = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(initiallyFresh)

        peer.responds = false
        let eventSequence = peer.currentReplySequence + 100
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.03) {
            peer.sendEvent(reason: "delayed-emergency", sequence: eventSequence)
            peer.sendEvent(reason: "duplicate-must-not-replay", sequence: eventSequence)
        }
        blockCurrentThread(for: 0.45)

        let eventDelivered = await waitUntil(timeout: 1) { safetyReasons.count == 1 }
        XCTAssertTrue(eventDelivered,
                      "a valid safety EVENT must survive MainActor delay beyond heartbeatTimeout")
        XCTAssertEqual(safetyReasons, ["delayed-emergency"],
                       "the replay window must still reject a duplicated delayed EVENT")
        let stayedStale = await waitUntil(timeout: 1) { !controller.status.peerFresh }
        XCTAssertTrue(stayedStale)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(controller.status.peerFresh,
                       "EVENT delivery must not masquerade as a fresh heartbeat")
    }

    @MainActor
    func testHILExplicitTargetsRebuildAfterHeartbeatTimeoutButStopNeverReconnects() async throws {
        let cases: [(HILConnectionMode, HILHotspotDiscoveryMode, UInt16, UInt16, UInt16)] = [
            (.lan, .automatic, 31_239, 31_240, 31_241),
            (.hotspot, .manual, 31_242, 31_243, 31_244)
        ]
        for (mode, discovery, serverPort, phonePort, framePort) in cases {
            let peer = try HILTestPeer(serverPort: serverPort, phonePort: phonePort)
            peer.start()
            let controller = OpenFlyHILController(listensForFrames: false)
            controller.configuration = .init(
                mode: mode,
                host: mode == .lan ? "127.0.0.1" : "",
                hotspotDiscoveryMode: discovery,
                hotspotHost: mode == .hotspot ? "127.0.0.1" : "",
                udpServerPort: serverPort,
                udpLocalPort: phonePort,
                frameTCPPort: framePort,
                poseSendHz: 100,
                simulatorStateHz: 100,
                heartbeatTimeoutMilliseconds: 250,
                legacyDiscoveryHosts: []
            )
            controller.start()
            let initialPeerReady = await waitUntil(timeout: 2) { controller.status.peerFresh }
            XCTAssertTrue(initialPeerReady)
            let initialGeneration = controller.udpTransportGeneration

            peer.responds = false
            let peerTimedOut = await waitUntil(timeout: 2) { !controller.status.peerFresh }
            XCTAssertTrue(peerTimedOut)
            let rebuilt = await waitUntil(timeout: 2) {
                controller.udpTransportGeneration > initialGeneration
            }
            XCTAssertTrue(rebuilt,
                          "\(mode.rawValue) must build a new NWConnection after a real heartbeat timeout")
            peer.responds = true
            let recovered = await waitUntil(timeout: 2) { controller.status.peerFresh }
            XCTAssertTrue(recovered,
                          "\(mode.rawValue) must recover without restarting HIL")

            controller.stop()
            let stoppedGeneration = controller.udpTransportGeneration
            try await Task.sleep(nanoseconds: 650_000_000)
            XCTAssertEqual(controller.udpTransportGeneration, stoppedGeneration,
                           "explicit stop must cancel every pending UDP reconnect")
            XCTAssertFalse(controller.status.running)
            peer.stop()
        }
    }

    @MainActor
    func testHILMissingExplicitPeerTimesOutAndRebuildsReadyUDPTransport() async throws {
        let silentPeer = try HILTestPeer(serverPort: 31_245, phonePort: 31_246)
        silentPeer.responds = false
        silentPeer.start()
        defer { silentPeer.stop() }
        let controller = OpenFlyHILController(listensForFrames: false)
        var diagnostics: [String] = []
        controller.onDiagnostic = { diagnostics.append($0) }
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_245,
            udpLocalPort: 31_246, frameTCPPort: 31_247, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 250,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let firstGeneration = controller.udpTransportGeneration
        let rebuilt = await waitUntil(timeout: 3) {
            controller.udpTransportGeneration > firstGeneration
        }
        XCTAssertTrue(rebuilt,
                      "a connectionless UDP ready state without a real peer handshake must not stall forever")
        XCTAssertTrue(diagnostics.contains { $0.contains("reason=handshake-timeout") })
    }

    @MainActor
    func testHILLANPeerCanRestartSequenceAfterRealHeartbeatTimeout() async throws {
        let peer = try HILTestPeer(serverPort: 31_215, phonePort: 31_216)
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_215,
            udpLocalPort: 31_216, frameTCPPort: 31_217, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 250,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let initiallyFresh = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(initiallyFresh)

        peer.responds = false
        let timedOut = await waitUntil(timeout: 2) { !controller.status.peerFresh }
        XCTAssertTrue(timedOut)
        peer.restartReplySequence()
        peer.responds = true

        let recovered = await waitUntil(timeout: 2) { controller.status.peerFresh }
        XCTAssertTrue(recovered,
                      "a restarted LAN UE must be accepted after the real watchdog transition")
    }

    @MainActor
    func testMalformedTCPFrameClosesOnlyImagePlaneAndUDPPoseContinues() async throws {
        let peer = try HILTestPeer(serverPort: 31_218, phonePort: 31_219)
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_218,
            udpLocalPort: 31_219, frameTCPPort: 31_220, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let linkReady = await waitUntil {
            controller.status.peerFresh && controller.status.frameListening
        }
        XCTAssertTrue(linkReady)
        controller.submit(telemetry: FlightTelemetry(), simulator: .init(
            available: true, active: true, stateReceived: true,
            motorsOn: true, flying: true,
            sampleMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            measuredUpdateHz: 100, message: "malformed-frame"))
        let poseReady = await waitUntil { peer.poseCount >= 3 }
        XCTAssertTrue(poseReady)
        let poseCountBefore = peer.poseCount

        let connection = peer.openFrameConnection(port: 31_220)
        let frameConnected = await waitUntil { controller.status.frameConnected }
        XCTAssertTrue(frameConnected)
        peer.sendMalformedFrame(over: connection)
        let frameRejected = await waitUntil {
            !controller.status.frameConnected
                && controller.status.frameMessage.contains("协议错误")
        }
        XCTAssertTrue(frameRejected)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(controller.status.peerFresh)
        XCTAssertGreaterThanOrEqual(peer.poseCount - poseCountBefore, 10,
            "a bad TCP image must not stall or tear down the independent UDP pose plane")
    }

    @MainActor
    func testHILPoseCadenceContinuesWhileMainActorIsBlocked() async throws {
        let peer = try HILTestPeer(serverPort: 31_200, phonePort: 31_201)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_200,
            udpLocalPort: 31_201, frameTCPPort: 31_202, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let ready = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(ready)
        controller.submit(telemetry: FlightTelemetry(), simulator: .init(
            available: true, active: true, stateReceived: true,
            motorsOn: true, flying: true,
            sampleMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            measuredUpdateHz: 100, message: "cadence"))
        let firstPackets = await waitUntil { peer.poseCount >= 3 }
        XCTAssertTrue(firstPackets)
        let before = peer.poseCount

        blockCurrentThread(for: 0.35)

        XCTAssertGreaterThanOrEqual(peer.poseCount - before, 20,
            "Android-parity UDP pose scheduling must not stall behind SwiftUI/MainActor work")
    }

    @MainActor
    func testHILGroundedRawBeforeStartSeedsPoseAndRestartUsesNewSession() async throws {
        let peer = try HILTestPeer(serverPort: 31_227, phonePort: 31_228)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_227,
            udpLocalPort: 31_228, frameTCPPort: 31_229, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])

        // DJI MSDK4 can deliver exactly one authoritative grounded callback
        // before the user opens HIL, then remain quiet until the motors change.
        // The provider owns this cache; starting a network session must consume
        // it without requiring another UI/MainActor submit callback.
        let rawSample = DispatchTime.now().uptimeNanoseconds
        controller.rawSimulatorStateStore.submit(.init(
            available: true, active: true, stateReceived: true,
            motorsOn: false, flying: false,
            originLatitudeDegrees: 31.123, originLongitudeDegrees: 121.456,
            positionX: 7, positionY: 3, positionZ: -2,
            rollDegrees: 1, pitchDegrees: 2, yawDegrees: 30,
            sampleMonotonicNanoseconds: rawSample,
            measuredUpdateHz: 100, message: "grounded-before-hil"))

        controller.start()
        let firstReady = await waitUntil(timeout: 3) {
            guard let session = peer.receivedSessionIDs.first else { return false }
            return controller.status.peerFresh && peer.poseCount(sessionID: session) >= 5
        }
        XCTAssertTrue(firstReady,
                      "a grounded provider RAW sample must seed POSE after HIL starts")
        let firstSession = try XCTUnwrap(peer.receivedSessionIDs.first)
        let firstPayload = try XCTUnwrap(peer.lastPosePayload(sessionID: firstSession))
        XCTAssertEqual(hilUInt64(firstPayload, at: 0), rawSample)
        XCTAssertEqual(hilDouble(firstPayload, at: 24), 3, accuracy: 0.001)
        XCTAssertEqual(hilDouble(firstPayload, at: 32), 7, accuracy: 0.001)
        XCTAssertEqual(hilDouble(firstPayload, at: 40), 2, accuracy: 0.001)
        XCTAssertEqual(hilDouble(firstPayload, at: 112), 0, accuracy: 0.001,
                       "a provider-only seed must never inherit an old command")

        controller.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        let stoppedPoseCount = peer.poseCount(sessionID: firstSession)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(peer.poseCount(sessionID: firstSession), stoppedPoseCount,
                       "stop must detach the previous network session")

        // No new Simulator callback is submitted between sessions. The same
        // still-active provider state must seed a new wire session, while peer
        // identity and wire sequence are reset rather than reused.
        controller.start()
        defer { controller.stop() }
        let secondReady = await waitUntil(timeout: 4) {
            peer.receivedSessionIDs.count >= 2
                && peer.poseCount(sessionID: peer.receivedSessionIDs[1]) >= 5
        }
        XCTAssertTrue(secondReady)
        let sessions = peer.receivedSessionIDs
        XCTAssertGreaterThanOrEqual(sessions.count, 2)
        let secondSession = sessions[1]
        XCTAssertNotEqual(secondSession, firstSession)
        XCTAssertEqual(peer.poseCount(sessionID: firstSession), stoppedPoseCount,
                       "restart must not leak POSE packets from the stopped session")
        XCTAssertEqual(peer.sequences(sessionID: firstSession).first, 1)
        XCTAssertEqual(peer.sequences(sessionID: secondSession).first, 1,
                       "a restarted session must begin its own sequence space")
        let secondSequences = peer.sequences(sessionID: secondSession)
        XCTAssertTrue(zip(secondSequences, secondSequences.dropFirst())
            .allSatisfy { $0.0 < $0.1 },
            "the restarted session must remain strictly monotonic")
        let secondPayload = try XCTUnwrap(peer.lastPosePayload(sessionID: secondSession))
        XCTAssertEqual(hilUInt64(secondPayload, at: 0), rawSample)
        XCTAssertEqual(hilDouble(secondPayload, at: 24), 3, accuracy: 0.001)
        XCTAssertEqual(hilDouble(secondPayload, at: 32), 7, accuracy: 0.001)
        XCTAssertEqual(hilDouble(secondPayload, at: 112), 0, accuracy: 0.001)
    }

    @MainActor
    func testHILMovingRawStopsAt500MillisecondsButGroundedRawRemainsReusable() async throws {
        let peer = try HILTestPeer(serverPort: 31_248, phonePort: 31_249)
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController(listensForFrames: false)
        var diagnostics: [String] = []
        controller.onDiagnostic = { diagnostics.append($0) }
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_248,
            udpLocalPort: 31_249, frameTCPPort: 31_250, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.rawSimulatorStateStore.submit(.init(
            available: true, active: true, stateReceived: true,
            motorsOn: true, flying: true,
            positionX: 12.5, positionY: -3.25, positionZ: -2,
            yawDegrees: 47,
            sampleMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            measuredUpdateHz: 100, message: "moving"))
        controller.start()
        defer { controller.stop() }
        let movingReady = await waitUntil(timeout: 2) {
            controller.status.peerFresh && peer.poseCount >= 5
        }
        XCTAssertTrue(movingReady)

        try await Task.sleep(nanoseconds: 620_000_000)
        let staleMovingCount = peer.poseCount
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertLessThanOrEqual(peer.poseCount - staleMovingCount, 1,
            "motors-on/flying RAW older than 500 ms must stop stale POSE transmission")

        let oldGroundTimestamp = DispatchTime.now().uptimeNanoseconds - 2_000_000_000
        controller.rawSimulatorStateStore.submit(.init(
            available: true, active: true, stateReceived: true,
            motorsOn: false, flying: false,
            positionX: 12.5, positionY: -3.25, positionZ: 0,
            yawDegrees: 47, sampleMonotonicNanoseconds: oldGroundTimestamp,
            measuredUpdateHz: 0, message: "grounded"))
        let groundResumed = await waitUntil(timeout: 2) {
            peer.poseCount >= staleMovingCount + 5
        }
        XCTAssertTrue(groundResumed,
                      "an authoritative grounded RAW sample may be reused until DJI reports a transition")
        let summaryPublished = await waitUntil(timeout: 2) {
            diagnostics.contains {
                $0.contains("rawX=12.500 rawY=-3.250 rawYaw=47.00")
                    && $0.contains("mapping=android-compat(X->N,Y->E)")
            }
        }
        XCTAssertTrue(summaryPublished,
                      "the 1 Hz summary must expose raw axes and the unverified Android-compatible mapping")
    }

    @MainActor
    func testConcurrentPongAndPoseSubmissionKeepsOutboundSequenceMonotonic() async throws {
        let peer = try HILTestPeer(serverPort: 31_221, phonePort: 31_222)
        peer.start()
        defer { peer.stop() }
        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_221,
            udpLocalPort: 31_222, frameTCPPort: 31_223, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let linkReady = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(linkReady)
        controller.submit(telemetry: FlightTelemetry(), simulator: .init(
            available: true, active: true, stateReceived: true,
            motorsOn: true, flying: true,
            sampleMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            measuredUpdateHz: 100, message: "sequence-order"))

        DispatchQueue.global(qos: .userInteractive).async {
            for _ in 0..<100 { peer.sendPing() }
        }
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertGreaterThan(peer.receivedDatagramCount, 40)
        XCTAssertEqual(peer.outOfOrderPhoneSequenceCount, 0,
            "POSE/heartbeat/PONG must be submitted in the same order as their shared sequence")
    }

    @MainActor
    func testRawSimulatorPoseKeepsSendingWhileMainActorIsBlocked() async throws {
        let peer = try HILTestPeer(serverPort: 31_203, phonePort: 31_204)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_203,
            udpLocalPort: 31_204, frameTCPPort: 31_205, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let linkReady = await waitUntil { controller.status.peerFresh }
        XCTAssertTrue(linkReady)

        var telemetry = FlightTelemetry()
        telemetry.home = .init(latitude: 31.23, longitude: 121.47)
        controller.submit(telemetry: telemetry, simulator: .init(
            available: true, active: true, stateReceived: true,
            motorsOn: true, flying: true,
            sampleMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            measuredUpdateHz: 100, message: "raw-context"),
            command: .init(forward: 0.5, right: 0, up: 0, yawRate: 0))
        let poseReady = await waitUntil { peer.poseCount >= 3 }
        XCTAssertTrue(poseReady)
        let before = peer.poseCount
        let store = controller.rawSimulatorStateStore
        DispatchQueue.global(qos: .userInteractive).async {
            for index in 0..<45 {
                store.submit(.init(
                    available: true, active: true, stateReceived: true,
                    motorsOn: true, flying: true,
                    positionX: Double(index), positionY: Double(index) * 0.5,
                    positionZ: -2, rollDegrees: 0, pitchDegrees: 0, yawDegrees: 12,
                    sampleMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    measuredUpdateHz: 100, message: "raw"))
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        blockCurrentThread(for: 0.35)
        XCTAssertGreaterThanOrEqual(peer.poseCount - before, 20,
            "raw SimulatorState must bypass MainActor and keep the 100 Hz latest-only sender alive")
        XCTAssertGreaterThan(hilDouble(try XCTUnwrap(peer.lastPosePayload), at: 24), 10)
    }

    @MainActor
    func testTCPFrameFloodDoesNotStallUDPPoseCadence() async throws {
        let peer = try HILTestPeer(serverPort: 31_206, phonePort: 31_207)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_206,
            udpLocalPort: 31_207, frameTCPPort: 31_208, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let linkReady = await waitUntil { controller.status.peerFresh && controller.status.frameListening }
        XCTAssertTrue(linkReady)
        controller.submit(telemetry: FlightTelemetry(), simulator: .init(
            available: true, active: true, stateReceived: true,
            motorsOn: true, flying: true,
            sampleMonotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            measuredUpdateHz: 100, message: "frame-flood"))
        let poseReady = await waitUntil { peer.poseCount >= 3 }
        XCTAssertTrue(poseReady)
        let clientReady = expectation(description: "frame flood client ready")
        let frameConnection = peer.openFrameConnection(port: 31_208) {
            clientReady.fulfill()
        }
        await fulfillment(of: [clientReady], timeout: 2)
        let frameConnected = await waitUntil { controller.status.frameConnected }
        XCTAssertTrue(frameConnected)
        let before = peer.poseCount
        peer.sendFrames(over: frameConnection, frameIDs: Array(1...20), payloadBytes: 256 * 1024)

        blockCurrentThread(for: 0.35)
        XCTAssertGreaterThanOrEqual(peer.poseCount - before, 20,
            "TCP image parsing/CRC must remain asynchronous from the UDP pose/control plane")
        let latestFrameArrived = await waitUntil(timeout: 3) {
            controller.latestVirtualFrame?.sourceFrameID == 20
        }
        XCTAssertTrue(latestFrameArrived)
        XCTAssertEqual(controller.status.receivedFrameCount, 20)
    }

    @MainActor
    func testRejectedReplayCannotRefreshFrameAgeAndInferenceUsesTwoSecondGate() async throws {
        let peer = try HILTestPeer(serverPort: 31_209, phonePort: 31_210)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_209,
            udpLocalPort: 31_210, frameTCPPort: 31_211, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.useVirtualFrames = true
        controller.start()
        defer { controller.stop() }
        let linkReady = await waitUntil { controller.status.peerFresh && controller.status.frameListening }
        XCTAssertTrue(linkReady)
        let connection = peer.openFrameConnection(port: 31_211)
        let frameConnected = await waitUntil { controller.status.frameConnected }
        XCTAssertTrue(frameConnected)
        peer.sendFrame(over: connection, frameID: 7)
        let firstFrame = await waitUntil { controller.latestVirtualFrame?.sourceFrameID == 7 }
        XCTAssertTrue(firstFrame)

        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertThrowsError(try controller.requireFreshVirtualFrame(),
            "Android V4 inference rejects UE frames older than two seconds")
        peer.sendFrame(over: connection, frameID: 7, repetitions: 4)
        try await Task.sleep(nanoseconds: 550_000_000)
        XCTAssertFalse(controller.virtualFrameIsFresh,
            "duplicate/replayed source frame IDs must not refresh the accepted-frame clock")
        XCTAssertNil(controller.latestVirtualFrame)
        XCTAssertEqual(controller.status.receivedFrameCount, 1)
        XCTAssertGreaterThanOrEqual(controller.status.rejectedFrameCount, 4)
    }

    @MainActor
    func testAndroidCompatibleOutboundTCPFrameClientReceivesFrames() async throws {
        let peer = try HILTestPeer(serverPort: 31_212, phonePort: 31_213)
        try peer.startFrameServer(port: 31_214, frameID: 33)
        peer.start()
        defer { peer.stop() }
        let serverReady = await waitUntil { peer.frameServerReady }
        XCTAssertTrue(serverReady)

        let controller = OpenFlyHILController(listensForFrames: false)
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_212,
            udpLocalPort: 31_213, frameTCPPort: 31_214, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 1_000,
            legacyDiscoveryHosts: [])
        controller.start()
        defer { controller.stop() }
        let outboundFrameReady = await waitUntil(timeout: 3) {
            controller.status.peerFresh && controller.status.frameConnected
                && controller.latestVirtualFrame?.sourceFrameID == 33
        }
        XCTAssertTrue(outboundFrameReady)
        XCTAssertTrue(controller.status.frameMessage.contains("TCP主动"))
    }

    @MainActor
    func testHILFrameReceiptAgeIsMeasuredBeforeMainActorPublication() async throws {
        let peer = try HILTestPeer(serverPort: 31_160, phonePort: 31_161)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_160,
            udpLocalPort: 31_161, frameTCPPort: 31_162, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 10_000,
            legacyDiscoveryHosts: [])
        var publishedFrameIDs: [UInt64] = []
        controller.onVirtualFrame = { frame in
            if let id = frame.sourceFrameID { publishedFrameIDs.append(id) }
        }
        controller.useVirtualFrames = true
        controller.start()
        defer { controller.stop() }

        let ready = await waitUntil {
            controller.status.peerFresh && controller.status.frameListening
        }
        XCTAssertTrue(ready)
        let connection = peer.openFrameConnection(port: 31_162)
        let frameConnected = await waitUntil { controller.status.frameConnected }
        XCTAssertTrue(frameConnected)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            peer.sendFrame(over: connection, frameID: 17)
        }
        blockCurrentThread(for: 2.7)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertNil(controller.latestVirtualFrame)
        XCTAssertFalse(controller.virtualFrameIsFresh)
        XCTAssertTrue(publishedFrameIDs.isEmpty,
                      "a stale queued frame must not reach inference/capture consumers")
        XCTAssertGreaterThanOrEqual(controller.status.latestFrameAgeMilliseconds ?? 0,
                                    OpenFlyHILController.virtualFrameFreshMilliseconds)
    }

    @MainActor
    func testHILOldConnectionFrameCannotPublishAfterReplacement() async throws {
        let peer = try HILTestPeer(serverPort: 31_170, phonePort: 31_171)
        peer.start()
        defer { peer.stop() }

        let controller = OpenFlyHILController()
        controller.configuration = .init(mode: .lan, host: "127.0.0.1",
            hotspotDiscoveryMode: .automatic, hotspotHost: "", udpServerPort: 31_170,
            udpLocalPort: 31_171, frameTCPPort: 31_172, poseSendHz: 100,
            simulatorStateHz: 100, heartbeatTimeoutMilliseconds: 10_000,
            legacyDiscoveryHosts: [])
        var publishedFrameIDs: [UInt64] = []
        controller.onVirtualFrame = { frame in
            if let id = frame.sourceFrameID { publishedFrameIDs.append(id) }
        }
        controller.useVirtualFrames = true
        controller.start()
        defer { controller.stop() }

        let ready = await waitUntil {
            controller.status.peerFresh && controller.status.frameListening
        }
        XCTAssertTrue(ready)
        let oldConnection = peer.openFrameConnection(port: 31_172)
        let firstConnected = await waitUntil { controller.status.frameConnected }
        XCTAssertTrue(firstConnected)

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            _ = peer.openFrameConnection(port: 31_172) {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                    peer.sendFrame(over: oldConnection, frameID: 91)
                }
            }
        }
        blockCurrentThread(for: 0.5)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(controller.status.frameConnected)
        XCTAssertNil(controller.latestVirtualFrame)
        XCTAssertTrue(publishedFrameIDs.isEmpty,
                      "a queued frame from the replaced TCP connection must be ignored")
    }

    func testAndroidGeoTIFFFixtureDecodesWithCRSAndElevation() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.deletingLastPathComponent()
            .appendingPathComponent("dji-vln-mini2-camera/testdata/terrain/ea-london-dsm-1m.tif")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Android DSM fixture unavailable") }
        let terrain = try GeoTIFFTerrain.read(Data(contentsOf: fixture), displayName: fixture.lastPathComponent)
        XCTAssertEqual(terrain.info.epsg, 4326)
        XCTAssertEqual(terrain.info.width, 200)
        XCTAssertEqual(terrain.info.height, 200)
        let elevation = try terrain.elevationMeters(
            latitude: (terrain.info.minimumLatitude + terrain.info.maximumLatitude) / 2,
            longitude: (terrain.info.minimumLongitude + terrain.info.maximumLongitude) / 2)
        XCTAssertTrue(elevation.isFinite)
    }

    private func rectangle() -> [SurveyGeoPoint] {
        [.init(latitude: 31.2300, longitude: 121.4730),
         .init(latitude: 31.2300, longitude: 121.4736),
         .init(latitude: 31.2305, longitude: 121.4736),
         .init(latitude: 31.2305, longitude: 121.4730)]
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func waitForInferenceCapture(_ engine: HILFrameCapturingInferenceEngine,
                                         count: Int,
                                         requireLoaded: Bool = false,
                                         timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let captureCount = await engine.captureCount()
            let loaded = await engine.isLoaded()
            if captureCount >= count, !requireLoaded || loaded { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let captureCount = await engine.captureCount()
        let loaded = await engine.isLoaded()
        return captureCount >= count && (!requireLoaded || loaded)
    }
}

private final class HILTestPeer {
    private let queue = DispatchQueue(label: "com.openfly.go.tests.hil-peer")
    private let frameQueue = DispatchQueue(label: "com.openfly.go.tests.hil-peer.frame")
    private let lock = NSLock()
    private let serverPort: NWEndpoint.Port
    private let phonePort: NWEndpoint.Port
    private var listener: NWListener?
    private var frameListener: NWListener?
    private var reply: NWConnection?
    private var accepted: [NWConnection] = []
    private var _responds = true
    private var _frameServerReady = false
    private var _poseCount = 0
    private var _lastPosePayload: Data?
    private var _sessionID: UInt64?
    private var _lastReceivedSequence: UInt64 = 0
    private var replySequence: UInt64 = 0
    private var lastPhoneSequence: UInt64?
    private var receivedHeaders: [OpenFlyHILProtocol.Header] = []
    private var receivedSessionOrder: [UInt64] = []
    private var posePayloadsBySession: [UInt64: Data] = [:]
    private var _receivedDatagramCount = 0
    private var _outOfOrderPhoneSequenceCount = 0
    var replyToHelloSource = false

    var responds: Bool {
        get { lock.withLock { _responds } }
        set { lock.withLock { _responds = newValue } }
    }
    var poseCount: Int { lock.withLock { _poseCount } }
    var lastPosePayload: Data? { lock.withLock { _lastPosePayload } }
    var frameServerReady: Bool { lock.withLock { _frameServerReady } }
    var currentReplySequence: UInt64 { lock.withLock { replySequence } }
    var receivedDatagramCount: Int { lock.withLock { _receivedDatagramCount } }
    var outOfOrderPhoneSequenceCount: Int { lock.withLock { _outOfOrderPhoneSequenceCount } }
    var receivedSessionIDs: [UInt64] { lock.withLock { receivedSessionOrder } }

    func receivedCount(type: OpenFlyHILProtocol.MessageType) -> Int {
        lock.withLock { receivedHeaders.lazy.filter { $0.type == type }.count }
    }

    func poseCount(sessionID: UInt64) -> Int {
        lock.withLock {
            receivedHeaders.lazy.filter {
                $0.sessionID == sessionID && $0.type == .pose
            }.count
        }
    }

    func lastPosePayload(sessionID: UInt64) -> Data? {
        lock.withLock { posePayloadsBySession[sessionID] }
    }

    func sequences(sessionID: UInt64) -> [UInt64] {
        lock.withLock {
            receivedHeaders.lazy.filter { $0.sessionID == sessionID }.map(\.sequence)
        }
    }

    func restartReplySequence() {
        lock.withLock { replySequence = 0 }
    }

    init(serverPort: UInt16, phonePort: UInt16) throws {
        self.serverPort = NWEndpoint.Port(rawValue: serverPort)!
        self.phonePort = NWEndpoint.Port(rawValue: phonePort)!
        listener = try NWListener(using: .udp, on: self.serverPort)
    }

    func start() {
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.accepted.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener?.start(queue: queue)
        let value = NWConnection(host: "127.0.0.1", port: phonePort, using: .udp)
        value.start(queue: queue)
        reply = value
    }

    func stop() {
        listener?.cancel(); frameListener?.cancel(); reply?.cancel()
        let connections = lock.withLock { () -> [NWConnection] in
            let value = accepted
            accepted.removeAll()
            return value
        }
        connections.forEach { $0.cancel() }
        listener = nil; frameListener = nil; reply = nil
        lock.withLock { _frameServerReady = false }
    }

    func startFrameServer(port: UInt16, frameID: UInt64) throws {
        let listener = try NWListener(using: .tcp, on: .init(rawValue: port)!)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.lock.withLock { self._frameServerReady = true }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.accepted.append(connection) }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: Self.frameWire(frameID: frameID),
                                    completion: .contentProcessed { _ in })
                }
            }
            connection.start(queue: self.frameQueue)
        }
        listener.start(queue: frameQueue)
        frameListener = listener
    }

    func sendFrame(port: UInt16, frameID: UInt64 = 1, repetitions: Int = 1) {
        let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let wire = Self.frameWire(frameID: frameID)
            var content = Data()
            for _ in 0..<max(1, repetitions) { content.append(wire) }
            connection.send(content: content, completion: .contentProcessed { _ in })
        }
        connection.start(queue: frameQueue)
        lock.withLock { accepted.append(connection) }
    }

    @discardableResult
    func openFrameConnection(port: UInt16, onReady: (() -> Void)? = nil) -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state { onReady?() }
        }
        connection.start(queue: frameQueue)
        lock.withLock { accepted.append(connection) }
        return connection
    }

    func sendFrame(over connection: NWConnection, frameID: UInt64 = 1, repetitions: Int = 1) {
        let wire = Self.frameWire(frameID: frameID)
        var content = Data()
        for _ in 0..<max(1, repetitions) { content.append(wire) }
        connection.send(content: content, completion: .contentProcessed { _ in })
    }

    func sendMalformedFrame(over connection: NWConnection) {
        var wire = Self.frameWire(frameID: 1)
        wire[0] = 0
        connection.send(content: wire, completion: .contentProcessed { _ in })
    }

    func sendFrames(over connection: NWConnection, frameIDs: [UInt64], payloadBytes: Int) {
        frameQueue.async {
            for frameID in frameIDs {
                // Match the UE contract: one complete serialized frame per write.
                // Do not manufacture an application-level multi-frame batch.
                connection.send(content: Self.frameWire(frameID: frameID, payloadBytes: payloadBytes),
                                completion: .contentProcessed { _ in })
            }
        }
    }

    func sendHeartbeat(sequence explicitSequence: UInt64? = nil) {
        let outbound = lock.withLock { () -> (NWConnection, Data)? in
            guard let reply, let sessionID = _sessionID else { return nil }
            if explicitSequence == nil { replySequence &+= 1 }
            let heartbeat = OpenFlyHILProtocol.encodeHeartbeat(
                sessionID: sessionID, sequence: explicitSequence ?? replySequence,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                lastReceivedSequence: _lastReceivedSequence
            )
            return (reply, heartbeat)
        }
        if let (connection, heartbeat) = outbound {
            connection.send(content: heartbeat, completion: .contentProcessed { _ in })
        }
    }

    func sendPing() {
        let outbound = lock.withLock { () -> (NWConnection, Data)? in
            guard let reply, let sessionID = _sessionID else { return nil }
            replySequence &+= 1
            let ping = OpenFlyHILProtocol.encodePing(
                sessionID: sessionID,
                sequence: replySequence,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            return (reply, ping)
        }
        if let (connection, ping) = outbound {
            connection.send(content: ping, completion: .contentProcessed { _ in })
        }
    }

    func sendMalformedHeartbeat() {
        let outbound = lock.withLock { () -> (NWConnection, Data)? in
            guard let reply, let sessionID = _sessionID else { return nil }
            replySequence &+= 1
            var heartbeat = OpenFlyHILProtocol.encodeHeartbeat(
                sessionID: sessionID, sequence: replySequence,
                monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                lastReceivedSequence: _lastReceivedSequence
            )
            heartbeat.removeLast()
            return (reply, heartbeat)
        }
        if let (connection, heartbeat) = outbound {
            connection.send(content: heartbeat, completion: .contentProcessed { _ in })
        }
    }

    func sendInboundBurst(controlPacketCount: Int, eventReasons: [String]) {
        let outbound = lock.withLock { () -> (NWConnection, [Data])? in
            guard let reply, let sessionID = _sessionID else { return nil }
            var packets: [Data] = []
            packets.reserveCapacity(max(0, controlPacketCount) + eventReasons.count)
            for index in 0..<max(0, controlPacketCount) {
                replySequence &+= 1
                let now = DispatchTime.now().uptimeNanoseconds
                switch index % 3 {
                case 0:
                    packets.append(OpenFlyHILProtocol.encodeHeartbeat(
                        sessionID: sessionID, sequence: replySequence,
                        monotonicNanoseconds: now,
                        lastReceivedSequence: _lastReceivedSequence
                    ))
                case 1:
                    packets.append(OpenFlyHILProtocol.encodePing(
                        sessionID: sessionID, sequence: replySequence,
                        monotonicNanoseconds: now
                    ))
                default:
                    packets.append(OpenFlyHILProtocol.encodePong(
                        sessionID: sessionID, sequence: replySequence,
                        echoed: now, peer: now
                    ))
                }
            }
            for (index, reason) in eventReasons.enumerated() {
                replySequence &+= 1
                packets.append(Self.eventWire(
                    sessionID: sessionID,
                    sequence: replySequence,
                    kind: index == 0 ? .collision : (index == 1 ? .stop : .emergency),
                    reason: reason
                ))
            }
            return (reply, packets)
        }
        guard let (connection, packets) = outbound else { return }
        for packet in packets {
            connection.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    func sendEvent(reason: String, sequence explicitSequence: UInt64? = nil) {
        let outbound = lock.withLock { () -> (NWConnection, Data)? in
            guard let reply, let sessionID = _sessionID else { return nil }
            let sequence: UInt64
            if let explicitSequence {
                sequence = explicitSequence
                replySequence = max(replySequence, explicitSequence)
            } else {
                replySequence &+= 1
                sequence = replySequence
            }
            return (reply, Self.eventWire(
                sessionID: sessionID,
                sequence: sequence,
                kind: .emergency,
                reason: reason
            ))
        }
        if let (connection, event) = outbound {
            connection.send(content: event, completion: .contentProcessed { _ in })
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.handle(data, sourceConnection: connection) }
            if error == nil { self.receive(connection) }
        }
    }

    private func handle(_ data: Data, sourceConnection: NWConnection) {
        guard let datagram = try? OpenFlyHILProtocol.decode(data) else { return }
        lock.withLock {
            _receivedDatagramCount += 1
            if let previous = lastPhoneSequence,
               datagram.header.sequence <= previous {
                _outOfOrderPhoneSequenceCount += 1
            }
            lastPhoneSequence = datagram.header.sequence
            receivedHeaders.append(datagram.header)
            if !receivedSessionOrder.contains(datagram.header.sessionID) {
                receivedSessionOrder.append(datagram.header.sessionID)
            }
            _sessionID = datagram.header.sessionID
            _lastReceivedSequence = datagram.header.sequence
            if datagram.header.type == .pose {
                _poseCount += 1
                _lastPosePayload = datagram.payload
                posePayloadsBySession[datagram.header.sessionID] = datagram.payload
            }
            guard _responds else { return }
            replySequence &+= 1
            let heartbeat = OpenFlyHILProtocol.encodeHeartbeat(sessionID: datagram.header.sessionID,
                sequence: replySequence, monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
                lastReceivedSequence: datagram.header.sequence)
            let destination = replyToHelloSource ? sourceConnection : reply
            destination?.send(content: heartbeat, completion: .contentProcessed { _ in })
        }
    }

    private static func frameWire(frameID: UInt64 = 1, payloadBytes: Int = 4) -> Data {
        var payload = Data(repeating: 0xa5, count: max(4, payloadBytes))
        payload[0] = 0xff; payload[1] = 0xd8
        payload[payload.count - 2] = 0xff; payload[payload.count - 1] = 0xd9
        var data = Data()
        data.appendHILBE(UInt32(0x4f464652)); data.appendHILBE(UInt16(1)); data.appendHILBE(UInt16(1))
        data.appendHILBE(UInt32(56)); data.appendHILBE(UInt32(payload.count))
        data.appendHILBE(frameID); data.appendHILBE(UInt64(1)); data.appendHILBE(UInt64(1))
        data.appendHILBE(UInt32(2)); data.appendHILBE(UInt32(2)); data.appendHILBE(UInt32(0))
        data.appendHILBE(hilCRC32(payload)); data.append(payload)
        return data
    }

    private static func eventWire(sessionID: UInt64, sequence: UInt64,
                                  kind: OpenFlyHILProtocol.EventKind,
                                  reason: String) -> Data {
        let reasonData = Data(reason.utf8)
        var payload = Data()
        payload.appendHILBE(DispatchTime.now().uptimeNanoseconds)
        payload.appendHILBE(kind.rawValue)
        payload.appendHILBE(Double(0.9).bitPattern)
        payload.appendHILBE(UInt64(1))
        payload.appendHILBE(UInt32(reasonData.count))
        payload.append(reasonData)
        var wire = Data()
        wire.appendHILBE(OpenFlyHILProtocol.magic)
        wire.appendHILBE(OpenFlyHILProtocol.version)
        wire.appendHILBE(OpenFlyHILProtocol.MessageType.event.rawValue)
        wire.appendHILBE(UInt32(0))
        wire.appendHILBE(sessionID)
        wire.appendHILBE(sequence)
        wire.appendHILBE(UInt32(payload.count))
        wire.append(payload)
        return wire
    }
}

private struct HILInferenceCapture: Sendable {
    var frame: CameraFrame
    var telemetryFrameTimestamp: Date
}

private actor HILFrameCapturingInferenceEngine: EmbeddedInferenceEngine {
    nonisolated let engineName = "HIL frame capture test engine"
    private var loaded = false
    private var captures: [HILInferenceCapture] = []

    func load() async throws { loaded = true }
    func isLoaded() -> Bool { loaded }
    func captureCount() -> Int { captures.count }
    func capture(at index: Int) -> HILInferenceCapture? {
        captures.indices.contains(index) ? captures[index] : nil
    }

    func infer(frame: CameraFrame, prompt: String, telemetry: FlightTelemetry,
               modelState: [Double]?) async throws -> InferenceResult {
        guard loaded else { throw FlightActionError.unavailable("test model not loaded") }
        captures.append(.init(frame: frame, telemetryFrameTimestamp: telemetry.frameTimestamp))
        return .init(action: .init(forwardMeters: 0.5, rightMeters: 0, upMeters: 0,
                                   yawDegrees: 0, confidence: 1, stopScore: 0,
                                   reason: "HIL frame capture"),
                     latencyMilliseconds: 1, stages: [:], source: "test",
                     replanned: true, chunkRemaining: 0)
    }

    func stop() async {}
    func reset() async { captures.removeAll() }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

private extension Data {
    mutating func appendHILBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

private func hilUInt64(_ data: Data, at offset: Int) -> UInt64 {
    data.subdata(in: offset..<(offset + 8)).reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
}

private func hilDouble(_ data: Data, at offset: Int) -> Double {
    Double(bitPattern: hilUInt64(data, at: offset))
}

private func hilCRC32(_ data: Data) -> UInt32 {
    let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1
        }
        return value
    }
    var crc = UInt32.max
    for byte in data {
        let index = Int((crc ^ UInt32(byte)) & 0xff)
        crc = (crc >> 8) ^ table[index]
    }
    return crc ^ UInt32.max
}

private func blockCurrentThread(for interval: TimeInterval) {
    Thread.sleep(forTimeInterval: interval)
}

private struct RampTerrain: TerrainElevationSource {
    let info = TerrainRasterInfo(displayName: "ramp", width: 100, height: 100, epsg: 4326,
        noDataValue: nil, pixelSizeX: 0.00001, pixelSizeY: 0.00001,
        minimumLatitude: 31.22, maximumLatitude: 31.24,
        minimumLongitude: 121.46, maximumLongitude: 121.49)
    func elevationMeters(latitude: Double, longitude: Double) throws -> Double {
        5 + (longitude - 121.473) * 10_000
    }
}
