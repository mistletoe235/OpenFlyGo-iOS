import XCTest
@testable import DJIVLNiOS

final class SurveyCoreTests: XCTestCase {
    func testVirtualStickCommandLeaseExpiresStaleNonZeroButKeepsFreshAndZeroCommands() {
        let now = Date(timeIntervalSince1970: 1_000)
        let moving = VelocityCommand(forward: 2, right: -1, up: 0.2, yawRate: 3)

        XCTAssertEqual(
            VirtualStickCommandLeasePolicy.appliedCommand(
                desired: moving, refreshedAt: now.addingTimeInterval(-0.99), now: now
            ),
            moving
        )
        XCTAssertEqual(
            VirtualStickCommandLeasePolicy.appliedCommand(
                desired: moving, refreshedAt: now.addingTimeInterval(-1.01), now: now
            ),
            .zero
        )
        XCTAssertEqual(
            VirtualStickCommandLeasePolicy.appliedCommand(
                desired: .zero, refreshedAt: .distantPast, now: now
            ),
            .zero
        )
    }
    private let origin = SurveyGeoPoint(latitude: 31.2304, longitude: 121.4737, altitudeMeters: 10)

    func testParameterPolicyMatchesMini2PercentAndHeadingContract() throws {
        let constraints = try SurveyParameterPolicy.createConstraints(
            altitudeMetersAgl: 60, routeHeadingDegrees: -10,
            forwardOverlapPercent: 80, sideOverlapPercent: 70,
            speedMetersPerSecond: 3, gimbalPitchDegrees: -45,
            boundaryMarginMeters: 2, obliqueFiveDirection: true
        )
        XCTAssertEqual(constraints.forwardOverlap, 0.8)
        XCTAssertEqual(constraints.sideOverlap, 0.7)
        XCTAssertEqual(constraints.routeHeadingDegrees, 350)
        XCTAssertEqual(constraints.collectionMode, .obliqueFiveDirection)
        XCTAssertEqual(constraints.gimbalPitchDegrees, -90)
        XCTAssertEqual(constraints.obliqueGimbalPitchDegrees, -45)
    }

    func testParameterPolicyCarriesSelectedViewsAndObliqueHeadingMode() throws {
        let selected: Set<SurveyCaptureView> = [.nadir, .leftOblique]
        let value = try SurveyParameterPolicy.createConstraints(
            altitudeMetersAgl: 40, routeHeadingDegrees: 370,
            forwardOverlapPercent: 80, sideOverlapPercent: 70,
            speedMetersPerSecond: 3, gimbalPitchDegrees: -45,
            boundaryMarginMeters: 2, obliqueFiveDirection: true,
            enabledCaptureViews: selected,
            obliqueHeadingMode: .fixedCaptureDirection
        )
        XCTAssertEqual(value.enabledCaptureViews, selected)
        XCTAssertEqual(value.obliqueHeadingMode, .fixedCaptureDirection)
        XCTAssertEqual(value.routeHeadingDegrees, 10, accuracy: 0.0001)
    }

    func testParameterPolicyRejectsUnsafeValues() {
        XCTAssertThrowsError(try SurveyParameterPolicy.createConstraints(
            altitudeMetersAgl: 60, routeHeadingDegrees: 0,
            forwardOverlapPercent: 95, sideOverlapPercent: 70,
            speedMetersPerSecond: 3, gimbalPitchDegrees: -90,
            boundaryMarginMeters: 0, obliqueFiveDirection: false
        ))
        XCTAssertThrowsError(try SurveyParameterPolicy.createConstraints(
            altitudeMetersAgl: 60, routeHeadingDegrees: 0,
            forwardOverlapPercent: 80, sideOverlapPercent: 70,
            speedMetersPerSecond: 10.1, gimbalPitchDegrees: -90,
            boundaryMarginMeters: 0, obliqueFiveDirection: false
        ))
        XCTAssertThrowsError(try SurveyParameterPolicy.createConstraints(
            altitudeMetersAgl: 60, routeHeadingDegrees: 0,
            forwardOverlapPercent: 80, sideOverlapPercent: 70,
            speedMetersPerSecond: 3, gimbalPitchDegrees: -90,
            boundaryMarginMeters: 0, obliqueFiveDirection: false,
            targetSurfaceToTakeoffMeters: 70
        ))
    }

    func testCoverageAndGSDMatchMini2Contract() throws {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 60
        let coverage = SurveyCoveragePlanner.coverage(camera: .djiMini2, constraints: constraints)
        XCTAssertGreaterThan(coverage.footprintWidthMeters, coverage.footprintLengthMeters)
        XCTAssertGreaterThan(coverage.lineSpacingMeters, 1)
        XCTAssertGreaterThan(coverage.captureIntervalMeters, 1)
        XCTAssertTrue((1...5).contains(coverage.groundSampleDistanceCentimeters))
        XCTAssertEqual(
            try SurveyCoveragePlanner.altitudeForGroundSampleDistance(
                camera: .djiMini2,
                groundSampleDistanceCentimeters: coverage.groundSampleDistanceCentimeters
            ),
            60,
            accuracy: 1e-9
        )
    }

    func testDistanceCaptureExposesCameraLimitedSpeed() throws {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 30
        constraints.speedMetersPerSecond = 10
        let limit = try SurveyCoveragePlanner.speedLimit(camera: .djiMini2, constraints: constraints)
        XCTAssertEqual(limit.hardMaximumMetersPerSecond, 10)
        XCTAssertTrue(limit.cameraLimited)
        XCTAssertLessThan(limit.effectiveMaximumMetersPerSecond, 10)
        XCTAssertTrue(limit.exceeded)

        constraints.captureTriggerMode = .time
        constraints.speedMetersPerSecond = 5
        let timed = try SurveyCoveragePlanner.speedLimit(camera: .djiMini2, constraints: constraints)
        XCTAssertEqual(timed.effectiveMaximumMetersPerSecond, 10)
        XCTAssertFalse(timed.cameraLimited)
        XCTAssertFalse(timed.exceeded)
    }

    func testLegacyKnownCameraCannotBypassCatalogCaptureInterval() throws {
        var legacy = SurveyCameraProfile.djiMini2
        legacy.minimumCaptureIntervalSeconds = 1
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 30
        constraints.speedMetersPerSecond = 5

        let feasibility = try SurveyCoveragePlanner.captureFeasibility(
            camera: legacy, constraints: constraints
        )
        let legacyCaptureInterval = SurveyCoveragePlanner.coverage(
            camera: legacy, constraints: constraints
        ).captureIntervalMeters

        XCTAssertEqual(feasibility.minimumIntervalSeconds, 2, accuracy: 1e-9)
        XCTAssertFalse(feasibility.feasible)
        XCTAssertEqual(
            feasibility.maximumFeasibleSpeedMetersPerSecond,
            legacyCaptureInterval / 2,
            accuracy: 1e-9
        )
    }

    func testWaypointFollowerUsesBodyFrameAndBoundsCommands() throws {
        let north = waypoint(northMeters: 10, eastMeters: 0)
        let northCommand = try SurveyWaypointFollower.command(
            pose: .init(latitude: origin.latitude, longitude: origin.longitude,
                        altitudeMeters: 10, headingDegrees: 0),
            target: north,
            maximumHorizontalSpeedMetersPerSecond: 2
        )
        XCTAssertGreaterThan(northCommand.forwardMetersPerSecond, 1.9)
        XCTAssertEqual(northCommand.rightMetersPerSecond, 0, accuracy: 0.02)

        let bounded = try SurveyWaypointFollower.command(
            pose: .init(latitude: origin.latitude, longitude: origin.longitude,
                        altitudeMeters: 10, headingDegrees: 170),
            target: waypoint(northMeters: 100, eastMeters: 100, upMeters: 20, headingDegrees: 350),
            maximumHorizontalSpeedMetersPerSecond: 1.5
        )
        XCTAssertEqual(hypot(bounded.forwardMetersPerSecond, bounded.rightMetersPerSecond), 1.5, accuracy: 1e-6)
        XCTAssertEqual(bounded.upMetersPerSecond, 0.5)
        XCTAssertLessThanOrEqual(abs(bounded.yawRateDegreesPerSecond), 30)
    }

    func testWaypointFollowerRequiresPositionAltitudeAndHeadingTolerance() throws {
        let reached = try SurveyWaypointFollower.command(
            pose: .init(latitude: origin.latitude, longitude: origin.longitude,
                        altitudeMeters: 10, headingDegrees: 42),
            target: waypoint(northMeters: 0.5, eastMeters: 0.4, upMeters: 0.2, headingDegrees: 42),
            maximumHorizontalSpeedMetersPerSecond: 2
        )
        XCTAssertTrue(reached.reached)
        XCTAssertEqual(reached.forwardMetersPerSecond, 0)
        XCTAssertEqual(reached.rightMetersPerSecond, 0)
        XCTAssertEqual(reached.upMetersPerSecond, 0)
        XCTAssertEqual(reached.yawRateDegreesPerSecond, 0)

        let align = try SurveyWaypointFollower.command(
            pose: .init(latitude: origin.latitude, longitude: origin.longitude,
                        altitudeMeters: 10, headingDegrees: 0),
            target: waypoint(northMeters: 0, eastMeters: 0, headingDegrees: 90),
            maximumHorizontalSpeedMetersPerSecond: 2
        )
        XCTAssertFalse(align.reached)
        XCTAssertGreaterThan(align.yawRateDegreesPerSecond, 0)

        let transitAlign = try SurveyWaypointFollower.command(
            pose: .init(latitude: origin.latitude, longitude: origin.longitude,
                        altitudeMeters: 10, headingDegrees: 0),
            target: waypoint(northMeters: 0, eastMeters: 10, headingDegrees: 90),
            maximumHorizontalSpeedMetersPerSecond: 2,
            alignHeadingBeforeHorizontalMotion: true
        )
        XCTAssertEqual(transitAlign.forwardMetersPerSecond, 0)
        XCTAssertEqual(transitAlign.rightMetersPerSecond, 0)
        XCTAssertGreaterThan(transitAlign.yawRateDegreesPerSecond, 0)
    }

    func testCheckpointSchemaAndCoverageSafeRecovery() throws {
        let original = try SurveyExecutionCheckpoint(
            missionID: "mission-1", waypointIndex: 7, state: .running,
            updatedAtEpochMillis: 123_456, executionLegIndex: 9, phase: .transitToStart,
            activeCaptureIntervalMeters: 2.4
        )
        XCTAssertEqual(
            try SurveyExecutionCheckpointJSON.decode(SurveyExecutionCheckpointJSON.encode(original)),
            original
        )
        let legacy = try SurveyExecutionCheckpointJSON.decode(
            #"{"schema_version":1,"mission_id":"m","waypoint_index":3,"state":"PAUSED","updated_at_epoch_ms":9}"#
        )
        XCTAssertEqual(legacy.executionLegIndex, .max)
        XCTAssertEqual(legacy.phase, .survey)
        XCTAssertFalse(legacy.captureStateRecorded)
        XCTAssertNil(legacy.activeCaptureIntervalMeters)
        XCTAssertNil(legacy.pendingCaptureStartWaypointIndex)
        XCTAssertEqual(
            SurveyCheckpointRecoveryPolicy.position(
                waypointIndex: 7, executionLegIndex: 9, state: .paused,
                phase: .survey, targetCaptureAction: .stopDistanceInterval
            ),
            .init(waypointIndex: 6, executionLegIndex: 8)
        )

        let pending = try SurveyExecutionCheckpoint(
            missionID: "mission-1", waypointIndex: 8, state: .paused,
            updatedAtEpochMillis: 123_457, executionLegIndex: 10, phase: .survey,
            pendingCaptureStartWaypointIndex: 6
        )
        XCTAssertEqual(
            try SurveyExecutionCheckpointJSON.decode(SurveyExecutionCheckpointJSON.encode(pending)),
            pending
        )

        let mission = try validMission(name: "legacy-capture-recovery")
        XCTAssertEqual(
            SurveyCaptureRecoveryPolicy.legacySafeWaypointIndex(
                mission: mission, waypointIndex: 1, phase: .survey
            ),
            0
        )
        let base = SurveyRecoveryPosition(waypointIndex: 1, executionLegIndex: 3)
        let runningWithoutExactPoint = try SurveyExecutionCheckpoint(
            missionID: mission.id, waypointIndex: 1, state: .running,
            updatedAtEpochMillis: 2, executionLegIndex: 3, phase: .survey,
            activeCaptureIntervalMeters: try XCTUnwrap(mission.waypoints[0].captureIntervalMeters)
        )
        let conservative = try SurveyCaptureCheckpointRecoveryPolicy.decide(
            mission: mission, checkpoint: runningWithoutExactPoint,
            basePosition: base, baseTargetPassIndex: 0, baseMissionWaypointIndex: 1
        )
        XCTAssertTrue(conservative.rewoundToStripStart)
        XCTAssertEqual(conservative.waypointIndex, 0)
        XCTAssertNil(conservative.executionLegIndex)
        XCTAssertNil(conservative.activeCaptureIntervalMeters)

        var pausedWithExactPoint = runningWithoutExactPoint
        pausedWithExactPoint.state = .paused
        pausedWithExactPoint.recoveryPoint = mission.waypoints[1].point
        let exact = try SurveyCaptureCheckpointRecoveryPolicy.decide(
            mission: mission, checkpoint: pausedWithExactPoint,
            basePosition: base, baseTargetPassIndex: 0, baseMissionWaypointIndex: 1
        )
        XCTAssertFalse(exact.rewoundToStripStart)
        XCTAssertEqual(exact.activeCaptureIntervalMeters,
                       mission.waypoints[0].captureIntervalMeters)
        XCTAssertEqual(exact.recoveryPoint, mission.waypoints[1].point)

        let legacyWithPoint = try SurveyExecutionCheckpoint(
            missionID: mission.id, waypointIndex: 1, state: .paused,
            updatedAtEpochMillis: 3, executionLegIndex: 3, phase: .survey,
            recoveryPoint: mission.waypoints[1].point, captureStateRecorded: false
        )
        let legacyDecision = try SurveyCaptureCheckpointRecoveryPolicy.decide(
            mission: mission, checkpoint: legacyWithPoint,
            basePosition: base, baseTargetPassIndex: 0, baseMissionWaypointIndex: 1
        )
        XCTAssertTrue(legacyDecision.rewoundToStripStart)
        XCTAssertNil(legacyDecision.recoveryPoint)

        let mismatchedPending = try SurveyExecutionCheckpoint(
            missionID: mission.id, waypointIndex: 1, state: .paused,
            updatedAtEpochMillis: 4, executionLegIndex: 3, phase: .survey,
            recoveryPoint: mission.waypoints[1].point,
            pendingCaptureStartWaypointIndex: 1
        )
        let mismatchDecision = try SurveyCaptureCheckpointRecoveryPolicy.decide(
            mission: mission, checkpoint: mismatchedPending,
            basePosition: base, baseTargetPassIndex: 0, baseMissionWaypointIndex: 1
        )
        XCTAssertTrue(mismatchDecision.rewoundToStripStart)
        XCTAssertNil(mismatchDecision.pendingCaptureStartWaypointIndex)

        let interPassCheckpoint = try SurveyExecutionCheckpoint(
            missionID: mission.id, waypointIndex: 1, state: .paused,
            updatedAtEpochMillis: 5, executionLegIndex: 4, phase: .survey,
            recoveryPoint: mission.waypoints[1].point
        )
        let interPass = try SurveyCaptureCheckpointRecoveryPolicy.decide(
            mission: mission, checkpoint: interPassCheckpoint,
            basePosition: .init(waypointIndex: 1, executionLegIndex: 4),
            baseTargetPassIndex: 0, baseMissionWaypointIndex: nil
        )
        XCTAssertFalse(interPass.rewoundToStripStart)
        XCTAssertEqual(interPass.executionLegIndex, 4)
    }

    func testWatchdogAndLowBatteryPoliciesFailSafe() {
        let allowed = SurveyExecutionGateResult(allowed: true, blocks: [], startDistanceMeters: 4)
        XCTAssertEqual(
            SurveyExecutionWatchdog.inspect(
                state: .running, gate: allowed, trustedDJITelemetry: true,
                nowElapsedMillis: 1_000, waypointDeadlineElapsedMillis: 2_000
            ).action,
            .continue
        )
        XCTAssertEqual(
            SurveyExecutionWatchdog.inspect(
                state: .running, gate: allowed, trustedDJITelemetry: false,
                nowElapsedMillis: 1_000, waypointDeadlineElapsedMillis: 2_000
            ).action,
            .pauseZeroAndRelease
        )
        XCTAssertEqual(
            SurveyExecutionWatchdog.inspect(
                state: .running, gate: allowed, trustedDJITelemetry: true,
                nowElapsedMillis: 2_000, waypointDeadlineElapsedMillis: 2_000
            ).action,
            .pauseZeroAndRelease
        )
        XCTAssertTrue(SurveyLowBatteryPolicy.shouldTrigger(
            batteryPercent: 19, aircraftFlying: true, simulatorActive: false, executionState: .running
        ))
        XCTAssertFalse(SurveyLowBatteryPolicy.shouldTrigger(
            batteryPercent: 20, aircraftFlying: true, simulatorActive: false, executionState: .running
        ))
        XCTAssertNotNil(SurveyExternalInterventionPolicy.reason(
            mode: .gps, smartReturnToHomeState: "COUNTING_DOWN"
        ))
        XCTAssertNil(SurveyExternalInterventionPolicy.reason(
            mode: .gps, smartReturnToHomeState: "CANCELLED"
        ))
        XCTAssertNotNil(SurveyExternalInterventionPolicy.reason(
            mode: .returningHome, smartReturnToHomeState: "IDLE"
        ))
        XCTAssertNil(SurveyExternalInterventionPolicy.reason(
            mode: .returningHome, smartReturnToHomeState: "EXECUTED",
            locallyInitiatedReturnHome: true
        ), "the runtime's own RTH acknowledgement must not pause its completion callback")
        XCTAssertNotNil(SurveyExternalInterventionPolicy.reason(
            mode: .landing, smartReturnToHomeState: "IDLE",
            locallyInitiatedReturnHome: true
        ), "an unrelated landing intervention must remain recoverable-stop input")
        XCTAssertTrue(SurveyCaptureSourcePolicy.usesHILVirtualFrame(
            hilVirtualFramesEnabled: true, simulatorActive: true
        ))
        XCTAssertFalse(SurveyCaptureSourcePolicy.usesHILVirtualFrame(
            hilVirtualFramesEnabled: true, simulatorActive: false
        ))
    }

    func testGimbalSettlePolicyMatchesMini2Bounds() {
        XCTAssertTrue(SurveyGimbalSettlePolicy.isSettled(targetPitchDegrees: -45, actualPitchDegrees: -42))
        XCTAssertFalse(SurveyGimbalSettlePolicy.isSettled(targetPitchDegrees: -45, actualPitchDegrees: -41.9))
        XCTAssertFalse(SurveyGimbalSettlePolicy.shouldRetry(nowElapsedMillis: 2_999, lastCommandElapsedMillis: 1_000))
        XCTAssertTrue(SurveyGimbalSettlePolicy.shouldRetry(nowElapsedMillis: 3_000, lastCommandElapsedMillis: 1_000))
        XCTAssertFalse(SurveyGimbalSettlePolicy.hasTimedOut(nowElapsedMillis: 20_999, settlingStartedElapsedMillis: 1_000))
        XCTAssertTrue(SurveyGimbalSettlePolicy.hasTimedOut(nowElapsedMillis: 21_000, settlingStartedElapsedMillis: 1_000))
        XCTAssertFalse(SurveyGimbalSettlePolicy.isVerifiedForCapture(
            targetPitchDegrees: -45, actualPitchDegrees: -45,
            commandAcceptedElapsedMillis: 1_000, nowElapsedMillis: 2_199
        ))
        XCTAssertTrue(SurveyGimbalSettlePolicy.isVerifiedForCapture(
            targetPitchDegrees: -45, actualPitchDegrees: -45,
            commandAcceptedElapsedMillis: 1_000, nowElapsedMillis: 2_200
        ))
        XCTAssertFalse(SurveyGimbalSettlePolicy.isVerifiedForCapture(
            targetPitchDegrees: -45, actualPitchDegrees: -45,
            commandAcceptedElapsedMillis: 0, nowElapsedMillis: 10_000
        ))
    }

    func testMissionValidationRejectsIncompletePass() throws {
        let start = waypoint(northMeters: 0, eastMeters: 0, captureAction: .startDistanceInterval,
                             captureIntervalMeters: 2)
        var end = waypoint(northMeters: 10, eastMeters: 0, captureAction: .stopDistanceInterval)
        end.kind = .passEnd
        var mission = SurveyMission(
            name: "valid", cameraProfile: .djiMini2, constraints: .init(),
            roi: [origin, waypointPoint(0, 10), waypointPoint(10, 10), waypointPoint(10, 0)],
            waypoints: [start, end], estimatedPathMeters: 10,
            estimatedPhotoCount: 6, estimatedFlightSeconds: 3.3
        )
        XCTAssertNoThrow(try mission.validate())
        mission.waypoints.removeLast()
        XCTAssertThrowsError(try mission.validate())
    }

    func testMissionJSONSchemaSixRoundTripAndLegacyDefaults() throws {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 45
        constraints.routeHeadingDegrees = 32
        constraints.collectionMode = .obliqueFiveDirection
        constraints.obliqueGimbalPitchDegrees = -48
        constraints.targetSurfaceToTakeoffMeters = 12.5
        constraints.safeTakeoffAltitudeMeters = 35
        constraints.takeoffSpeedMetersPerSecond = 2.5
        constraints.takeoffMode = .autoSimulatorOnly
        constraints.startPointMode = .routeCorner4
        constraints.completionAction = .hover
        constraints.captureTriggerMode = .time
        constraints.timedCaptureIntervalSeconds = 2.4
        constraints.obliqueForwardOverlap = 0.77
        constraints.obliqueSideOverlap = 0.66
        let mission = try validMission(name: "round-trip", constraints: constraints)

        let encoded = try SurveyMissionJSON.encode(mission)
        let decoded = try SurveyMissionJSON.decode(encoded)
        XCTAssertEqual(decoded, mission)

        let data = try XCTUnwrap(encoded.data(using: .utf8))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((root["schema_version"] as? NSNumber)?.intValue, 13)
        var values = try XCTUnwrap(root["constraints"] as? [String: Any])
        root["schema_version"] = 5
        values.removeValue(forKey: "takeoff_mode")
        root["constraints"] = values
        let schema5 = try SurveyMissionJSON.decode(json(root))
        XCTAssertEqual(schema5.constraints.takeoffMode, .manual)

        root["schema_version"] = 3
        for key in ["altitude_mode", "target_surface_to_takeoff_m", "safe_takeoff_altitude_m",
                    "takeoff_speed_mps", "start_point_mode", "completion_action",
                    "capture_trigger_mode", "timed_capture_interval_s",
                    "oblique_forward_overlap", "oblique_side_overlap"] {
            values.removeValue(forKey: key)
        }
        root["constraints"] = values
        let schema3 = try SurveyMissionJSON.decode(json(root))
        XCTAssertEqual(schema3.constraints.altitudeMode, .aboveTargetSurface)
        XCTAssertEqual(schema3.constraints.obliqueForwardOverlap, schema3.constraints.forwardOverlap)

        root["schema_version"] = 2
        values.removeValue(forKey: "collection_mode")
        values.removeValue(forKey: "oblique_gimbal_pitch_deg")
        root["constraints"] = values
        root["waypoints"] = try XCTUnwrap(root["waypoints"] as? [[String: Any]]).map { item in
            var item = item; item.removeValue(forKey: "capture_view"); return item
        }
        let schema2 = try SurveyMissionJSON.decode(json(root))
        XCTAssertEqual(schema2.constraints.collectionMode, .ortho)

        root["schema_version"] = 1
        values.removeValue(forKey: "boundary_margin_m")
        values["safety_margin_m"] = 8.0
        root["constraints"] = values
        let schema1 = try SurveyMissionJSON.decode(json(root))
        XCTAssertEqual(schema1.constraints.boundaryMarginMeters, 0)
    }

    func testDecodesAndroidStableSchemaSixGoldenMission() throws {
        let androidGolden = #"{"schema_version":6,"camera_profile":{"image_height_px":3000,"horizontal_fov_deg":73.7,"image_width_px":4000,"vertical_fov_deg":53.1,"id":"dji-mini-2-photo-4x3","minimum_capture_interval_s":1},"name":"Android iOS Golden","estimated_photo_count":17,"id":"android-ios-golden-v1","estimated_path_m":123.5,"coordinate_frame":"WGS84","constraints":{"safe_takeoff_altitude_m":30,"speed_mps":2.5,"oblique_gimbal_pitch_deg":-47,"start_point_mode":"ROUTE_CORNER_2","takeoff_speed_mps":2,"takeoff_mode":"MANUAL","target_surface_to_takeoff_m":3,"timed_capture_interval_s":1.5,"gimbal_pitch_deg":-90,"altitude_agl_m":42,"capture_trigger_mode":"DISTANCE","side_overlap":0.71,"forward_overlap":0.81,"crosshatch":false,"collection_mode":"OBLIQUE_FIVE_DIRECTION","completion_action":"HOVER","oblique_side_overlap":0.62,"route_heading_deg":33,"altitude_mode":"ABOVE_TARGET_SURFACE","boundary_margin_m":4,"oblique_forward_overlap":0.72},"roi":[{"latitude":31.23,"altitude_m":0,"longitude":121.473},{"latitude":31.23,"altitude_m":0,"longitude":121.474},{"latitude":31.231,"altitude_m":0,"longitude":121.474},{"latitude":31.231,"altitude_m":0,"longitude":121.473}],"waypoints":[{"capture_interval_m":8.25,"kind":"PASS_START","capture_view":"NADIR","heading_deg":33,"capture_action":"START_DISTANCE_INTERVAL","gimbal_pitch_deg":-90,"point":{"latitude":31.2301,"altitude_m":45,"longitude":121.4731},"pass_index":0},{"capture_interval_m":null,"kind":"PASS_END","capture_view":"NADIR","heading_deg":33,"capture_action":"STOP_DISTANCE_INTERVAL","gimbal_pitch_deg":-90,"point":{"latitude":31.2309,"altitude_m":45,"longitude":121.4739},"pass_index":0}],"estimated_flight_s":49.4,"created_at_epoch_ms":1725000000123}"#
        let mission = try SurveyMissionJSON.decode(androidGolden)
        XCTAssertEqual(mission.id, "android-ios-golden-v1")
        XCTAssertEqual(mission.createdAtEpochMillis, 1_725_000_000_123)
        XCTAssertEqual(mission.constraints.collectionMode, .obliqueFiveDirection)
        XCTAssertEqual(mission.constraints.startPointMode, .routeCorner2)
        XCTAssertEqual(mission.constraints.completionAction, .hover)
        XCTAssertEqual(mission.waypoints.count, 2)
        XCTAssertEqual(mission.waypoints[0].captureIntervalMeters, 8.25)
        XCTAssertEqual(try SurveyMissionJSON.decode(SurveyMissionJSON.encode(mission)), mission)
    }

    func testMissionLibraryMonotonicRevisionAndBoundedHistory() throws {
        var constraints = SurveyConstraints()
        var versions = try SurveyMissionLibrary.addVersion(
            existing: [], mission: validMission(name: "campus", constraints: constraints),
            savedAtEpochMillis: 10
        )
        constraints.routeHeadingDegrees = 45
        versions = try SurveyMissionLibrary.addVersion(
            existing: versions, mission: validMission(name: "campus", constraints: constraints),
            savedAtEpochMillis: 20
        )
        versions = try SurveyMissionLibrary.addVersion(
            existing: versions, mission: validMission(name: "roof"), savedAtEpochMillis: 30
        )
        let decoded = try SurveyMissionLibrary.decode(SurveyMissionLibrary.encode(versions))
        XCTAssertEqual(decoded.map(\.missionName), ["roof", "campus", "campus"])
        XCTAssertEqual(decoded.map(\.revision), [1, 2, 1])
        XCTAssertEqual(try decoded[1].mission().constraints.routeHeadingDegrees, 45)

        var bounded: [SurveyMissionVersion] = []
        for index in 0..<(SurveyMissionLibrary.maxVersions + 5) {
            bounded = try SurveyMissionLibrary.addVersion(
                existing: bounded, mission: validMission(name: "m"),
                savedAtEpochMillis: Int64(index)
            )
        }
        XCTAssertEqual(bounded.count, SurveyMissionLibrary.maxVersions)
        XCTAssertEqual(bounded.first?.revision, 55)
        XCTAssertGreaterThan(bounded.last?.revision ?? 0, 1)
    }

    func testPlannerAlternatesPassesAndEstimatesCapture() throws {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 50
        constraints.routeHeadingDegrees = 90
        let mission = try SurveyPlanner.plan(name: "rectangle-grid", roi: rectangularROI,
                                             constraints: constraints)
        XCTAssertGreaterThanOrEqual(mission.waypoints.count, 4)
        XCTAssertTrue(mission.waypoints.count.isMultiple(of: 2))
        XCTAssertEqual(mission.waypoints[0].captureAction, .startDistanceInterval)
        XCTAssertEqual(mission.waypoints[1].captureAction, .stopDistanceInterval)
        XCTAssertGreaterThan(mission.estimatedPathMeters, 100)
        XCTAssertGreaterThan(mission.estimatedPhotoCount, 4)
        let difference = wrappedDegrees(mission.waypoints[2].headingDegrees - mission.waypoints[0].headingDegrees)
        XCTAssertGreaterThan(abs(difference), 170)
    }

    func testFiveDirectionCreatesAllViewsAndIndependentObliqueSpacing() throws {
        var orthoConstraints = SurveyConstraints()
        orthoConstraints.altitudeMetersAgl = 50
        let ortho = try SurveyPlanner.plan(name: "ortho", roi: rectangularROI,
                                           constraints: orthoConstraints)
        var obliqueConstraints = orthoConstraints
        obliqueConstraints.collectionMode = .obliqueFiveDirection
        obliqueConstraints.obliqueGimbalPitchDegrees = -45
        let oblique = try SurveyPlanner.plan(name: "five-direction", roi: rectangularROI,
                                             constraints: obliqueConstraints)
        XCTAssertEqual(Set(oblique.waypoints.map(\.captureView)), SurveyCaptureView.standardSurveyViews)
        XCTAssertEqual(Set(oblique.waypoints.map(\.gimbalPitchDegrees)), Set([-90, -45]))
        XCTAssertGreaterThan(oblique.waypoints.count, ortho.waypoints.count)
        XCTAssertGreaterThan(oblique.estimatedPathMeters, ortho.estimatedPathMeters)
        XCTAssertGreaterThan(oblique.estimatedPhotoCount, ortho.estimatedPhotoCount)
    }

    func testPlannerHeadingConventionAndSuggestedLongAxis() throws {
        var north = SurveyConstraints(); north.altitudeMetersAgl = 50; north.routeHeadingDegrees = 0
        var east = north; east.routeHeadingDegrees = 90
        let northMission = try SurveyPlanner.plan(name: "north", roi: rectangularROI, constraints: north)
        let eastMission = try SurveyPlanner.plan(name: "east", roi: rectangularROI, constraints: east)
        XCTAssertLessThan(axisDifference(northMission.waypoints[0].headingDegrees, 0), 1)
        XCTAssertLessThan(axisDifference(eastMission.waypoints[0].headingDegrees, 90), 1)

        let center = SurveyGeoPoint(latitude: 31, longitude: 121)
        let heading = 32.0, radians = heading * .pi / 180
        let alongEast = sin(radians), alongNorth = cos(radians)
        let crossEast = cos(radians), crossNorth = -sin(radians)
        func corner(_ alongSign: Double, _ crossSign: Double) -> SurveyGeoPoint {
            let east = alongEast * 60 * alongSign + crossEast * 22.5 * crossSign
            let north = alongNorth * 60 * alongSign + crossNorth * 22.5 * crossSign
            return .init(latitude: center.latitude + north / 111_132,
                         longitude: center.longitude + east / (111_320 * cos(center.latitude * .pi / 180)))
        }
        let rotated = [corner(-1, -1), corner(1, -1), corner(1, 1), corner(-1, 1)]
        XCTAssertLessThan(axisDifference(try SurveyPlanner.suggestedRouteHeading(rotated), heading), 1)
    }

    func testETAAddsDelayOnlyForCaptureOnReach() throws {
        let base = try SurveyPlanner.plan(name: "eta-capture", roi: rectangularROI)
        func estimate(_ action: SurveyCaptureAction) throws -> Double {
            var waypoint = base.waypoints[0]
            waypoint.kind = action == .captureOnReach ? .capturePoint : .transit
            waypoint.captureAction = action
            waypoint.captureIntervalMeters = nil
            var mission = base
            mission.waypoints = [waypoint]
            return SurveyExecutionStateMachine(mission: mission)
                .remainingEstimate(currentPosition: waypoint.point).totalSeconds
        }
        XCTAssertEqual(try estimate(.captureOnReach), SurveyETAPolicy.captureOnReachSeconds)
        XCTAssertEqual(try estimate(.none), 0)
    }

    func testPlannedETAIncludesYawGimbalAndPointCaptureBudgets() throws {
        let base = try SurveyPlanner.plan(name: "eta-actions", roi: rectangularROI)
        var start = base.waypoints[0]
        start.headingDegrees = 0
        start.gimbalPitchDegrees = -90
        start.captureAction = .none
        var end = start
        end.headingDegrees = 90
        end.gimbalPitchDegrees = -45
        end.kind = .capturePoint
        end.captureAction = .captureOnReach
        XCTAssertEqual(SurveyPlanner.estimateRouteSeconds(
            [start, end], constraints: base.constraints), 10)
    }

    func testPointCaptureSortieKeepsItsPhotoAndCameraBudget() throws {
        var mission = try SurveyPlanner.plan(name: "point-sortie", roi: rectangularROI)
        var waypoint = mission.waypoints[0]
        waypoint.kind = .capturePoint
        waypoint.captureAction = .captureOnReach
        waypoint.captureIntervalMeters = nil
        mission.waypoints = [waypoint]
        mission.estimatedPhotoCount = 1
        mission.estimatedFlightSeconds = SurveyETAPolicy.captureOnReachSeconds
        let sortie = try XCTUnwrap(SurveyPlanner.planSorties(mission).first)
        XCTAssertEqual(sortie.estimatedPhotoCount, 1)
        XCTAssertEqual(sortie.estimatedFlightSeconds, SurveyETAPolicy.captureOnReachSeconds)
    }

    func testConcaveSplitScanlinesKeepLocalConnectorsForEveryStartCorner() throws {
        func geo(_ north: Double, _ east: Double) -> SurveyGeoPoint {
            .init(latitude: 31 + north / 111_132,
                  longitude: 121 + east / (111_320 * cos(31 * .pi / 180)))
        }
        let concave = [
            geo(0, 0), geo(0, 1_000), geo(300, 1_000), geo(300, 700),
            geo(100, 700), geo(100, 300), geo(300, 300), geo(300, 0),
        ]
        let cornerModes: [SurveyStartPointMode] = [
            .firstRouteStart, .routeCorner2, .routeCorner3, .routeCorner4,
        ]
        func distance(_ a: SurveyGeoPoint, _ b: SurveyGeoPoint) -> Double {
            let north = (b.latitude - a.latitude) * 111_132
            let east = (b.longitude - a.longitude) * 111_320
                * cos((a.latitude + b.latitude) / 2 * .pi / 180)
            return hypot(north, east)
        }
        let corners = try cornerModes.map { mode -> SurveyMission in
            var constraints = SurveyConstraints()
            constraints.altitudeMetersAgl = 80
            constraints.routeHeadingDegrees = 90
            constraints.startPointMode = mode
            let mission = try SurveyPlanner.plan(name: "split-\(mode)", roi: concave,
                                                  constraints: constraints)
            let connectors = try zip(mission.surveyPasses(), mission.surveyPasses().dropFirst())
                .map { distance($0.0.end.point, $0.1.start.point) }
            XCTAssertLessThan(connectors.max()!, 550, "\(mode) created a remote jump")
            return mission
        }
        let reference = geo(-50, -50)
        var automaticConstraints = SurveyConstraints()
        automaticConstraints.altitudeMetersAgl = 80
        automaticConstraints.routeHeadingDegrees = 90
        automaticConstraints.startPointMode = .autoNearest
        let automatic = try SurveyPlanner.plan(name: "split-auto", roi: concave,
                                                constraints: automaticConstraints,
                                                takeoffPoint: reference)
        func routeCost(_ mission: SurveyMission) throws -> Double {
            let passes = try mission.surveyPasses()
            return distance(reference, mission.waypoints[0].point)
                + zip(passes, passes.dropFirst()).reduce(0) {
                    $0 + distance($1.0.end.point, $1.1.start.point)
                }
        }
        XCTAssertEqual(try corners.map(routeCost).min()!, try routeCost(automatic), accuracy: 0.01)
    }

    func testFixedNadirHeadingSurvivesAlternatingPassesAndStartCorners() throws {
        for collection in SurveyCollectionMode.allCases {
            for start in SurveyStartPointMode.allCases {
                var constraints = SurveyConstraints()
                constraints.altitudeMetersAgl = 30
                constraints.routeHeadingDegrees = 37
                constraints.collectionMode = collection
                constraints.enabledCaptureViews = [.nadir]
                constraints.startPointMode = start
                func planned(_ mode: SurveyObliqueHeadingMode) throws -> SurveyMission {
                    var value = constraints
                    value.obliqueHeadingMode = mode
                    return try SurveyPlanner.plan(name: "nadir-heading-regression",
                                                  roi: rectangularROI, constraints: value,
                                                  takeoffPoint: rectangularROI.last)
                }
                let tracking = try planned(.trackRoute)
                let fixed = try planned(.fixedCaptureDirection)
                let expected: Set<Int> = collection == .crosshatchNadir ? [37, 127] : [37]
                XCTAssertEqual(Set(fixed.waypoints.map { Int($0.headingDegrees.rounded()) }), expected,
                               "\(collection) / \(start)")
                XCTAssertEqual(tracking.waypoints.map(\.point), fixed.waypoints.map(\.point))
                XCTAssertEqual(tracking.waypoints.map(\.gimbalPitchDegrees),
                               fixed.waypoints.map(\.gimbalPitchDegrees))
                let headings = try tracking.surveyPasses().map { $0.start.headingDegrees }
                XCTAssertTrue(zip(headings, headings.dropFirst()).contains {
                    abs((($0.1 - $0.0 + 540).truncatingRemainder(dividingBy: 360)) - 180) > 170
                })
            }
        }
    }

    func testPositiveMarginAndConcavePolygonUseRealPolygonGeometry() throws {
        var base = SurveyConstraints(); base.altitudeMetersAgl = 30; base.routeHeadingDegrees = 90
        let noMargin = try SurveyPlanner.plan(name: "base", roi: rectangularROI, constraints: base)
        base.boundaryMarginMeters = 10
        let expanded = try SurveyPlanner.plan(name: "expanded", roi: rectangularROI, constraints: base)
        XCTAssertGreaterThan(expanded.estimatedPathMeters, noMargin.estimatedPathMeters)
        XCTAssertLessThan(expanded.waypoints.map { $0.point.longitude }.min()!, 121)
        XCTAssertGreaterThan(expanded.waypoints.map { $0.point.longitude }.max()!, 121.001)
        XCTAssertGreaterThan(try SurveyPlanner.targetArea(expanded).areaSquareMeters,
                             try SurveyPlanner.targetArea(noMargin).areaSquareMeters)

        let concave = [
            SurveyGeoPoint(latitude: 31.0000, longitude: 121.0000),
            SurveyGeoPoint(latitude: 31.0000, longitude: 121.0010),
            SurveyGeoPoint(latitude: 31.0003, longitude: 121.0010),
            SurveyGeoPoint(latitude: 31.0003, longitude: 121.0004),
            SurveyGeoPoint(latitude: 31.0008, longitude: 121.0004),
            SurveyGeoPoint(latitude: 31.0008, longitude: 121.0000),
        ]
        base.boundaryMarginMeters = 5
        let concaveMission = try SurveyPlanner.plan(name: "concave", roi: concave, constraints: base)
        XCTAssertFalse(concaveMission.waypoints.isEmpty)
        XCTAssertLessThan(concaveMission.waypoints.map { $0.point.longitude }.min()!, 121)
        XCTAssertGreaterThan(concaveMission.waypoints.map { $0.point.longitude }.max()!, 121.001)
    }

    func testPlannerRejectsSelfIntersectionAndWorldSizedROI() {
        let selfIntersecting = [
            SurveyGeoPoint(latitude: 31, longitude: 121),
            SurveyGeoPoint(latitude: 31.0006, longitude: 121.001),
            SurveyGeoPoint(latitude: 31.0006, longitude: 121),
            SurveyGeoPoint(latitude: 31, longitude: 121.001),
            SurveyGeoPoint(latitude: 31.0003, longitude: 121.0012),
        ]
        XCTAssertThrowsError(try SurveyPlanner.plan(name: "invalid", roi: selfIntersecting))
        XCTAssertThrowsError(try SurveyPlanner.plan(name: "world", roi: [
            .init(latitude: 30, longitude: 120), .init(latitude: 30, longitude: 121),
            .init(latitude: 31, longitude: 121), .init(latitude: 31, longitude: 120),
        ]))
    }

    func testSortiePlannerNeverSplitsCapturePass() throws {
        var constraints = SurveyConstraints(); constraints.altitudeMetersAgl = 30; constraints.speedMetersPerSecond = 2
        let mission = try SurveyPlanner.plan(name: "sorties", roi: rectangularROI, constraints: constraints)
        let sorties = try SurveyPlanner.planSorties(mission, usableSortieSeconds: 30)
        XCTAssertGreaterThan(sorties.count, 1)
        for pair in zip(sorties, sorties.dropFirst()) {
            XCTAssertEqual(pair.0.lastWaypointIndex + 1, pair.1.firstWaypointIndex)
        }
        XCTAssertEqual(sorties.map(\.estimatedPhotoCount).reduce(0, +), mission.estimatedPhotoCount)
    }

    func testCaptureControllerMatchesEndpointCooldownAndTimePolicies() throws {
        var controller = SurveyDistanceCaptureController()
        let start = waypoint(northMeters: 0, eastMeters: 0,
                             captureAction: .startDistanceInterval, captureIntervalMeters: 10)
        var end = waypoint(northMeters: 6, eastMeters: 0, captureAction: .stopDistanceInterval)
        end.kind = .passEnd
        XCTAssertTrue(try controller.onWaypointReached(start, position: origin,
                                                        nowElapsedMillis: 1_000, cameraReady: true))
        controller.onCaptureResult(position: origin, nowElapsedMillis: 1_280, success: true)
        XCTAssertFalse(controller.onPosition(waypointPoint(11, 0), nowElapsedMillis: 1_500,
                                             cameraReady: true))
        XCTAssertTrue(controller.onPosition(waypointPoint(11, 0), nowElapsedMillis: 3_100,
                                            cameraReady: true))
        controller.onCaptureResult(position: waypointPoint(11, 0), nowElapsedMillis: 3_380, success: true)
        XCTAssertTrue(try controller.onWaypointReached(end, position: waypointPoint(18, 0),
                                                       nowElapsedMillis: 5_100, cameraReady: true))
        controller.onCaptureResult(position: waypointPoint(18, 0), nowElapsedMillis: 5_380, success: true)
        XCTAssertFalse(controller.active)

        try controller.configure(mode: .time, timedCaptureIntervalSeconds: 3)
        XCTAssertTrue(try controller.onWaypointReached(start, position: origin,
                                                        nowElapsedMillis: 10_000, cameraReady: true))
        controller.onCaptureResult(position: origin, nowElapsedMillis: 10_280, success: true)
        XCTAssertFalse(controller.onPosition(origin, nowElapsedMillis: 12_500, cameraReady: true))
        XCTAssertTrue(controller.onPosition(origin, nowElapsedMillis: 13_000, cameraReady: true))
    }

    func testReplayLifecycleAndCaptureStateAreDeterministic() throws {
        let mission = try SurveyPlanner.plan(name: "replay", roi: rectangularROI)
        let replay = try SurveyMissionReplay(mission: mission, sampleSpacingMeters: 5)
        XCTAssertEqual(replay.snapshot().state, .idle)
        replay.start()
        for _ in 0..<3 { replay.advance() }
        let paused = replay.pause()
        replay.advance()
        XCTAssertEqual(replay.snapshot().sampleIndex, paused.sampleIndex)
        replay.resume()
        var sawCapture = replay.snapshot().captureActive
        var sawTransit = !replay.snapshot().captureActive
        while replay.snapshot().state != .completed {
            let value = replay.advance()
            sawCapture = sawCapture || value.captureActive
            sawTransit = sawTransit || !value.captureActive
        }
        XCTAssertEqual(replay.snapshot().progress, 1, accuracy: 1e-12)
        XCTAssertTrue(sawCapture); XCTAssertTrue(sawTransit)
        XCTAssertEqual(replay.stop().sampleIndex, 0)
    }

    func testSimulatorAndRealFlightExecutionGatesStaySeparate() throws {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 40
        constraints.speedMetersPerSecond = 1
        constraints.safeTakeoffAltitudeMeters = 30
        let mission = try SurveyPlanner.plan(name: "gate", roi: rectangularROI, constraints: constraints)
        let now: Int64 = 1_000_000
        let simulator = SurveyExecutionTelemetry(
            connected: true, simulatorActive: true, simulatorFlying: true,
            virtualStickEnabled: false, sticksActive: false,
            latitude: 31.0001, longitude: 121.0001, altitudeMeters: 10,
            updatedAtEpochMillis: now
        )
        XCTAssertTrue(SurveyExecutionGate.evaluate(mission: mission, telemetry: simulator,
                                                   nowEpochMillis: now, requireVirtualStick: false).allowed)
        let run = SurveyExecutionGate.evaluate(mission: mission, telemetry: simulator,
                                               nowEpochMillis: now, requireVirtualStick: true)
        XCTAssertEqual(run.blocks, [.virtualStickRequired])

        let real = SurveyExecutionTelemetry(
            connected: true, simulatorActive: false, simulatorFlying: false,
            virtualStickEnabled: false, sticksActive: false,
            latitude: 31.0001, longitude: 121.0001, altitudeMeters: 10,
            updatedAtEpochMillis: now, aircraftFlying: true,
            batteryPercent: 80, rcBatteryPercent: 80, rcSignalPercent: 90,
            satelliteCount: 18, gpsSignalUsable: true, homeLocationValid: true,
            goHomeHeightMeters: 60, maxFlightHeightMeters: 120,
            maxFlightRadiusMeters: 500, maxFlightRadiusEnabled: true,
            horizontalSpeedMetersPerSecond: 0.1
        )
        XCTAssertTrue(SurveyExecutionGate.evaluate(
            mission: mission, telemetry: real, nowEpochMillis: now,
            requireVirtualStick: false, environment: .realAircraftManualTakeoff
        ).allowed)
        var unrestricted = real
        unrestricted.maxFlightRadiusEnabled = false
        unrestricted.maxFlightRadiusMeters = 0
        let unrestrictedGate = SurveyExecutionGate.evaluate(
            mission: mission, telemetry: unrestricted, nowEpochMillis: now,
            requireVirtualStick: false, environment: .realAircraftManualTakeoff
        )
        XCTAssertFalse(unrestrictedGate.blocks.contains(.maxFlightRadiusRequired))
        XCTAssertFalse(unrestrictedGate.blocks.contains(.maxFlightRadiusTooSmall))
        var unsafe = real
        unsafe.batteryPercent = 29; unsafe.rcSignalPercent = 20; unsafe.simulatorActive = true
        let blocked = SurveyExecutionGate.evaluate(
            mission: mission, telemetry: unsafe, nowEpochMillis: now,
            requireVirtualStick: false, environment: .realAircraftManualTakeoff
        )
        XCTAssertTrue(blocked.blocks.isSuperset(of: [.simulatorMustBeOff, .aircraftBatteryLow, .rcSignalWeak]))
    }

    func testExecutionStateMachineAddsSafeTransitAndManualTakeoverPauses() throws {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 40; constraints.speedMetersPerSecond = 1
        constraints.safeTakeoffAltitudeMeters = 55
        let mission = try SurveyPlanner.plan(name: "state", roi: rectangularROI, constraints: constraints)
        let launch = SurveyGeoPoint(latitude: 30.9999, longitude: 120.9999, altitudeMeters: 8)
        let machine = SurveyExecutionStateMachine(mission: mission, launchPoint: launch)
        XCTAssertEqual(machine.currentPhase, .safeClimb)
        XCTAssertEqual(machine.currentTarget.point.altitudeMeters, 55)
        XCTAssertEqual(machine.currentTarget.gimbalPitchDegrees, 0,
                       "安全爬升和飞向首航点期间必须前视；抵达后才切任务俯角")
        let interpassTransitCount = max(
            0,
            mission.waypoints.filter { $0.kind == .passStart }.count - 1
        )
        XCTAssertEqual(
            machine.executionLegCount,
            mission.waypoints.count + 5 + interpassTransitCount,
            "正射相邻航带之间也应插入先对头、再平移的安全衔接段"
        )
        machine.requestArm(.init(allowed: true, blocks: [], startDistanceMeters: 0))
        machine.onVirtualStickReady(.init(allowed: true, blocks: [], startDistanceMeters: 0))
        XCTAssertEqual(machine.status.state, .running)
        XCTAssertTrue(machine.requiresHeadingAlignmentBeforeTranslation)
        machine.reachWaypoint()
        XCTAssertEqual(machine.currentPhase, .transitToStart)
        XCTAssertTrue(machine.requiresHeadingAlignmentBeforeTranslation)
        machine.reachWaypoint()
        XCTAssertEqual(machine.currentPhase, .survey)
        XCTAssertFalse(machine.requiresHeadingAlignmentBeforeTranslation)
        machine.validate(.init(allowed: false, blocks: [.manualTakeover, .telemetryStale],
                               startDistanceMeters: 0))
        XCTAssertEqual(machine.status.state, .paused)
        XCTAssertTrue(machine.status.reason?.contains("MANUAL_TAKEOVER") == true)
    }

    func testExecutionUsesSeparateHomeAndFacesTransitPath() throws {
        var constraints = SurveyConstraints()
        constraints.completionAction = .returnToHome
        constraints.safeTakeoffAltitudeMeters = 35
        let mission = try validMission(name: "home-contract", constraints: constraints)
        let current = waypointPoint(0, -20, up: 2)
        let home = SurveyGeoPoint(
            latitude: origin.latitude - 30 / 111_132,
            longitude: origin.longitude + 40 / (111_320 * cos(origin.latitude * .pi / 180)),
            altitudeMeters: 1.2
        )

        let legs = SurveyExecutionStateMachine.buildExecutionLegs(
            mission: mission, currentPoint: current, returnPoint: home
        )

        XCTAssertEqual(legs[1].phase, .transitToStart)
        XCTAssertEqual(legs[0].target.gimbalPitchDegrees, 0)
        XCTAssertEqual(legs[1].target.gimbalPitchDegrees, 0)
        XCTAssertEqual(legs[2].target.gimbalPitchDegrees,
                       mission.waypoints[0].gimbalPitchDegrees)
        XCTAssertEqual(legs[1].target.headingDegrees, 90, accuracy: 0.2)
        XCTAssertEqual(legs.suffix(3).map(\.phase), [.returnHome, .returnHome, .returnHome])
        XCTAssertEqual(legs.last?.target.point, home)
        XCTAssertNotEqual(legs.last?.target.point, current)

        let machine = SurveyExecutionStateMachine(
            mission: mission, currentPoint: current, returnPoint: home
        )
        machine.requestArm(.init(allowed: true, blocks: [], startDistanceMeters: 0))
        machine.onVirtualStickReady(.init(allowed: true, blocks: [], startDistanceMeters: 0))
        for _ in 0..<legs.count where machine.currentPhase != .returnHome {
            machine.reachWaypoint()
        }
        XCTAssertEqual(machine.currentPhase, .returnHome)
        XCTAssertEqual(machine.acceptDJIReturnHome().state, .completed)
        XCTAssertEqual(machine.status.waypointIndex, mission.waypoints.count - 1)
    }

    func testTrackRouteAddsForwardFacingInterPassTransit() throws {
        var constraints = SurveyConstraints()
        constraints.collectionMode = .obliqueFiveDirection
        constraints.obliqueHeadingMode = .trackRoute
        constraints.completionAction = .hover
        constraints.safeTakeoffAltitudeMeters = 30
        let altitude = constraints.effectiveFlightAltitudeMeters

        var firstStart = waypoint(
            northMeters: 0, eastMeters: 0, headingDegrees: 123,
            captureAction: .startDistanceInterval, captureIntervalMeters: 2
        )
        firstStart.point.altitudeMeters = altitude
        var firstEnd = waypoint(
            northMeters: 10, eastMeters: 0, headingDegrees: 123,
            captureAction: .stopDistanceInterval
        )
        firstEnd.kind = .passEnd; firstEnd.point.altitudeMeters = altitude
        var secondStart = waypoint(
            northMeters: 10, eastMeters: 10, headingDegrees: 47,
            captureAction: .startDistanceInterval, captureIntervalMeters: 2
        )
        secondStart.passIndex = 1; secondStart.point.altitudeMeters = altitude
        var secondEnd = waypoint(
            northMeters: 0, eastMeters: 10, headingDegrees: 47,
            captureAction: .stopDistanceInterval
        )
        secondEnd.kind = .passEnd; secondEnd.passIndex = 1
        secondEnd.point.altitudeMeters = altitude
        let mission = SurveyMission(
            name: "track-route", cameraProfile: .djiMini2, constraints: constraints,
            roi: [origin, waypointPoint(0, 12), waypointPoint(12, 12), waypointPoint(12, 0)],
            waypoints: [firstStart, firstEnd, secondStart, secondEnd],
            estimatedPathMeters: 30, estimatedPhotoCount: 12, estimatedFlightSeconds: 10
        )
        try mission.validate()
        let current = waypointPoint(0, -10)

        let legs = SurveyExecutionStateMachine.buildExecutionLegs(
            mission: mission, currentPoint: current, returnPoint: current
        )
        let surveyTransits = legs.filter { $0.phase == .survey && $0.missionWaypointIndex == nil }
        let missionLegs = legs.compactMap { leg -> SurveyExecutionLeg? in
            leg.missionWaypointIndex == nil ? nil : leg
        }

        XCTAssertEqual(legs[1].target.headingDegrees, 90, accuracy: 0.2)
        XCTAssertEqual(legs[1].target.gimbalPitchDegrees, 0)
        XCTAssertEqual(surveyTransits.count, 1)
        XCTAssertEqual(surveyTransits[0].target.point, secondStart.point)
        XCTAssertEqual(surveyTransits[0].target.headingDegrees, 90, accuracy: 0.2)
        XCTAssertEqual(missionLegs[0].target.headingDegrees, 0, accuracy: 0.2)
        XCTAssertEqual(missionLegs[1].target.headingDegrees, 0, accuracy: 0.2)
        XCTAssertEqual(missionLegs[2].target.headingDegrees, 180, accuracy: 0.2)
        XCTAssertEqual(missionLegs[3].target.headingDegrees, 180, accuracy: 0.2)

        var orthoConstraints = constraints
        orthoConstraints.collectionMode = .ortho
        let orthoMission = SurveyMission(
            name: "ortho-track-route", cameraProfile: .djiMini2,
            constraints: orthoConstraints, roi: mission.roi,
            waypoints: mission.waypoints, estimatedPathMeters: 30,
            estimatedPhotoCount: 12, estimatedFlightSeconds: 10
        )
        try orthoMission.validate()
        let orthoLegs = SurveyExecutionStateMachine.buildExecutionLegs(
            mission: orthoMission, currentPoint: current, returnPoint: current
        )
        XCTAssertEqual(
            orthoLegs.filter { $0.phase == .survey && $0.missionWaypointIndex == nil }.count,
            1,
            "正射航带之间也必须先对准下一航带再平移"
        )
    }

    func testOnlyInFlightCheckpointStatesAreRecoverable() {
        XCTAssertTrue(SurveyRuntimeCheckpointPolicy.canRestore(.arming))
        XCTAssertTrue(SurveyRuntimeCheckpointPolicy.canRestore(.running))
        XCTAssertTrue(SurveyRuntimeCheckpointPolicy.canRestore(.paused))
        XCTAssertFalse(SurveyRuntimeCheckpointPolicy.canRestore(.idle))
        XCTAssertFalse(SurveyRuntimeCheckpointPolicy.canRestore(.completed))
        XCTAssertFalse(SurveyRuntimeCheckpointPolicy.canRestore(.aborted))
    }

    func testCheckpointRestoreMapsLegacyWaypointAfterTransitLegs() throws {
        let mission = try SurveyPlanner.plan(name: "restore", roi: rectangularROI)
        let launch = SurveyGeoPoint(latitude: 30.9999, longitude: 120.9999, altitudeMeters: 8)
        let machine = SurveyExecutionStateMachine(mission: mission, launchPoint: launch)
        try machine.restorePaused(waypointIndex: 2, legIndex: .max)
        XCTAssertEqual(machine.currentPhase, .survey)
        XCTAssertEqual(machine.executionLegIndex, 5)
        XCTAssertEqual(machine.currentTarget.point, mission.waypoints[2].point)
        XCTAssertEqual(machine.currentTarget.captureAction, mission.waypoints[2].captureAction)
        XCTAssertEqual(machine.currentTarget.headingDegrees,
                       mission.waypoints[2].headingDegrees, accuracy: 1e-9)
    }

    func testReadinessEvidenceNeverImplicitlyAuthorizesRealFlight() throws {
        let mission = try SurveyPlanner.plan(name: "audit", roi: rectangularROI)
        let telemetry = SurveyRealFlightTelemetry(
            connected: true, flightStateFresh: true, flying: false, simulatorActive: false,
            batteryPercent: 90, rcBatteryPercent: 80, rcSignalPercent: 100,
            satelliteCount: 20, gpsSignalUsable: true, homeLocationValid: true,
            latitude: 31, longitude: 121, goHomeHeightMeters: 80,
            maxFlightHeightMeters: 120, maxFlightRadiusMeters: 500,
            maxFlightRadiusEnabled: true
        )
        let missing = SurveyRealFlightReadiness.evaluate(
            mission: mission, telemetry: telemetry,
            evidence: .init(simulatorRegressionPassed: false, failsafeRegressionPassed: false,
                            fruBenchDirectionVerified: false, cameraCalibrated: false,
                            operatingAreaReviewed: false)
        )
        XCTAssertFalse(missing.readyForReview)
        XCTAssertTrue(missing.blocks.contains(.simulatorRegressionRequired))
        let complete = SurveyRealFlightReadiness.evaluate(
            mission: mission, telemetry: telemetry,
            evidence: .init(simulatorRegressionPassed: true, failsafeRegressionPassed: true,
                            fruBenchDirectionVerified: true, cameraCalibrated: true,
                            operatingAreaReviewed: true)
        )
        XCTAssertTrue(complete.readyForReview)
    }

    func testRegressionMissionFactoryCreatesBoundedPreviewOnlyMissions() throws {
        let center = SurveyGeoPoint(latitude: 31.2304, longitude: 121.4737)
        let ortho = try SurveyRegressionMissionFactory.create(center: center, fiveDirection: false)
        let oblique = try SurveyRegressionMissionFactory.create(center: center, fiveDirection: true)
        XCTAssertEqual(ortho.constraints.collectionMode, .ortho)
        XCTAssertEqual(Set(oblique.waypoints.map(\.captureView)), SurveyCaptureView.standardSurveyViews)
        XCTAssertTrue(ortho.name.hasPrefix("DEBUG")); XCTAssertTrue(oblique.name.hasPrefix("DEBUG"))
    }

    func testShanghaiMapCoordinateRoundTripStaysSubMeter() {
        let wgs84 = SurveyGeoPoint(latitude: 31.2304, longitude: 121.4737)
        let gcj02 = ChinaMapCoordinateTransform.wgs84ToGCJ02(wgs84)
        let restored = ChinaMapCoordinateTransform.gcj02ToWGS84(gcj02)

        XCTAssertGreaterThan(distanceMeters(wgs84, gcj02), 100)
        XCTAssertLessThan(distanceMeters(wgs84, restored), 0.2)
    }

    func testChinaMapCalibrationCanBeDisabledWithoutChangingFlightCoordinates() {
        let wgs84 = SurveyGeoPoint(latitude: 31.2304, longitude: 121.4737)
        let automatic = ChinaMapCoordinateTransform.wgs84ToMap(wgs84, mode: .automatic)
        let disabled = ChinaMapCoordinateTransform.wgs84ToMap(wgs84, mode: .disabled)

        XCTAssertGreaterThan(distanceMeters(wgs84, automatic), 100)
        XCTAssertEqual(disabled, wgs84)
        XCTAssertEqual(
            ChinaMapCoordinateTransform.mapToWGS84(disabled, mode: .disabled), wgs84
        )
    }

    func testMapCoordinatesOutsideMainlandStayWGS84() {
        let overseas = [
            SurveyGeoPoint(latitude: 37.7749, longitude: -122.4194), // San Francisco
            SurveyGeoPoint(latitude: 37.5665, longitude: 126.9780), // Seoul
            SurveyGeoPoint(latitude: 27.7172, longitude: 85.3240),  // Kathmandu
            SurveyGeoPoint(latitude: 47.8864, longitude: 106.9057), // Ulaanbaatar
            SurveyGeoPoint(latitude: 21.0278, longitude: 105.8342), // Hanoi
        ]
        for point in overseas {
            XCTAssertTrue(ChinaMapCoordinateTransform.outsideMainlandChina(
                latitude: point.latitude, longitude: point.longitude
            ))
            XCTAssertEqual(ChinaMapCoordinateTransform.wgs84ToGCJ02(point), point)
            XCTAssertEqual(ChinaMapCoordinateTransform.gcj02ToWGS84(point), point)
        }
    }

    func testRepresentativeMainlandAndHainanCoordinatesUseGCJ02() {
        let mainland = [
            SurveyGeoPoint(latitude: 39.9042, longitude: 116.4074),
            SurveyGeoPoint(latitude: 43.8256, longitude: 87.6168),
            SurveyGeoPoint(latitude: 45.8038, longitude: 126.5349),
            SurveyGeoPoint(latitude: 20.0440, longitude: 110.1999),
        ]
        for point in mainland {
            XCTAssertFalse(ChinaMapCoordinateTransform.outsideMainlandChina(
                latitude: point.latitude, longitude: point.longitude
            ))
            XCTAssertGreaterThan(
                distanceMeters(point, ChinaMapCoordinateTransform.wgs84ToGCJ02(point)), 50
            )
        }
    }

    private func waypointPoint(_ north: Double, _ east: Double, up: Double = 0) -> SurveyGeoPoint {
        .init(
            latitude: origin.latitude + north / 111_132,
            longitude: origin.longitude + east / (111_320 * cos(origin.latitude * .pi / 180)),
            altitudeMeters: origin.altitudeMeters + up
        )
    }

    private func distanceMeters(_ a: SurveyGeoPoint, _ b: SurveyGeoPoint) -> Double {
        let north = (a.latitude - b.latitude) * 111_132
        let east = (a.longitude - b.longitude) * 111_320 * cos(a.latitude * .pi / 180)
        return hypot(north, east)
    }

    private var rectangularROI: [SurveyGeoPoint] {[
        .init(latitude: 31, longitude: 121),
        .init(latitude: 31, longitude: 121.001),
        .init(latitude: 31.0006, longitude: 121.001),
        .init(latitude: 31.0006, longitude: 121),
    ]}

    private func wrappedDegrees(_ value: Double) -> Double {
        var result = (value + 540).truncatingRemainder(dividingBy: 360) - 180
        if result < -180 { result += 360 }
        return result
    }

    private func axisDifference(_ actual: Double, _ expected: Double) -> Double {
        min(abs(wrappedDegrees(actual - expected)), abs(wrappedDegrees(actual - expected - 180)))
    }

    private func waypoint(northMeters: Double, eastMeters: Double, upMeters: Double = 0,
                          headingDegrees: Double = 0,
                          captureAction: SurveyCaptureAction = .none,
                          captureIntervalMeters: Double? = nil) -> SurveyWaypoint {
        .init(point: waypointPoint(northMeters, eastMeters, up: upMeters),
              headingDegrees: headingDegrees, gimbalPitchDegrees: -90,
              kind: .passStart, captureAction: captureAction,
              captureIntervalMeters: captureIntervalMeters, passIndex: 0)
    }

    private func validMission(name: String, constraints: SurveyConstraints = .init()) throws -> SurveyMission {
        var start = waypoint(northMeters: 0, eastMeters: 0,
                             captureAction: .startDistanceInterval, captureIntervalMeters: 2)
        start.point.altitudeMeters = constraints.effectiveFlightAltitudeMeters
        var end = waypoint(northMeters: 10, eastMeters: 0,
                           captureAction: .stopDistanceInterval)
        end.kind = .passEnd
        end.point.altitudeMeters = constraints.effectiveFlightAltitudeMeters
        let mission = SurveyMission(
            name: name, cameraProfile: .djiMini2, constraints: constraints,
            roi: [origin, waypointPoint(0, 10), waypointPoint(10, 10), waypointPoint(10, 0)],
            waypoints: [start, end], estimatedPathMeters: 10,
            estimatedPhotoCount: 6, estimatedFlightSeconds: 10 / constraints.speedMetersPerSecond
        )
        try mission.validate()
        return mission
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
