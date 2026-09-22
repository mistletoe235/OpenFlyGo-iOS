import XCTest
@testable import DJIVLNiOS

@MainActor
final class SurveyRuntimeTests: XCTestCase {
    func testPhysicalCameraGeometryReadbackIsRequiredBeforeControl() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        provider.camera.surveyGeometryRequired = true
        runtime.updateCamera(provider.camera)
        XCTAssertTrue(runtime.preflight(mission).blocks.contains(.cameraGeometryUnverified))
        runtime.startSimulator(mission, anotherControllerActive: false)
        XCTAssertTrue(provider.virtualStickRequests.isEmpty)
        provider.camera.surveyCameraProfile = mission.cameraProfile
        provider.camera.surveyCameraUpdatedAt = Date()
        runtime.updateCamera(provider.camera)
        XCTAssertTrue(runtime.preflight(mission).allowed)
        provider.camera.surveyCameraUpdatedAt = Date().addingTimeInterval(-3)
        runtime.updateCamera(provider.camera)
        XCTAssertTrue(runtime.preflight(mission).blocks.contains(.cameraGeometryUnverified))
        provider.camera.surveyCameraUpdatedAt = Date()
        provider.camera.surveyCameraProfile?.horizontalFieldOfViewDegrees = 60
        runtime.updateCamera(provider.camera)
        XCTAssertTrue(runtime.preflight(mission).blocks.contains(.cameraGeometryUnverified))
        runtime.abort("test cleanup")
    }

    func testCameraGeometryChangePausesAndBlocksResumeUntilReadbackMatches() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        provider.camera.surveyGeometryRequired = true
        provider.camera.surveyCameraProfile = mission.cameraProfile
        provider.camera.surveyCameraUpdatedAt = Date()
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        XCTAssertEqual(provider.virtualStickRequests, [true])
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }
        XCTAssertEqual(runtime.snapshot.state, .running)
        provider.camera.surveyCameraProfile = nil
        runtime.updateCamera(provider.camera)
        await waitUntil { runtime.snapshot.state == .paused }
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertEqual(provider.commands.last, .zero)
        XCTAssertEqual(provider.virtualStickRequests.last, false)
        let requestCount = provider.virtualStickRequests.count
        runtime.resume(anotherControllerActive: false)
        XCTAssertEqual(provider.virtualStickRequests.count, requestCount)
        XCTAssertTrue(runtime.snapshot.gateBlocks.contains(.cameraGeometryUnverified))
        provider.camera.surveyCameraProfile = mission.cameraProfile
        provider.camera.surveyCameraUpdatedAt = Date()
        runtime.updateCamera(provider.camera)
        XCTAssertEqual(runtime.snapshot.state, .paused)
        runtime.abort("test cleanup")
    }

    func testRuntimeAcquiresSimulatorControlAndManualTakeoverReleasesIt() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)

        XCTAssertTrue(runtime.preflight(mission).allowed)
        runtime.startSimulator(mission, anotherControllerActive: false)
        XCTAssertEqual(runtime.snapshot.state, .arming)
        XCTAssertEqual(provider.virtualStickRequests, [true])

        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }
        XCTAssertEqual(runtime.snapshot.state, .running)

        runtime.manualTakeover()
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertEqual(provider.commands.last, .zero)
        XCTAssertEqual(provider.virtualStickRequests.last, false)
    }

    func testRuntimeDisconnectFailSafePausesZerosAndRestoresCheckpoint() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        provider.telemetry.connected = false
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .paused }
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertEqual(provider.commands.last, .zero)
        XCTAssertEqual(provider.virtualStickRequests.last, false)
        XCTAssertNotNil(runtime.snapshot.recoverableMissionName)

        let restored = SurveyRuntimeController(provider: provider, log: EventLog())
        restored.updateTelemetry(provider.telemetry)
        restored.updateSimulator(provider.simulatorStatus)
        restored.updateCamera(provider.camera)
        XCTAssertEqual(restored.restorePersistedMission()?.id, mission.id)
        XCTAssertEqual(restored.snapshot.state, .paused)
        runtime.abort("test cleanup")
    }

    func testPlannerPresentationAndRestoreAreReadOnlyDuringLiveExecution() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        let baseline = runtime.snapshot
        for _ in 0..<10 {
            XCTAssertEqual(runtime.liveMissionForPresentation?.id, mission.id)
            XCTAssertEqual(runtime.restorePersistedMission()?.id, mission.id)
            XCTAssertEqual(runtime.snapshot.state, .running)
            XCTAssertEqual(runtime.snapshot.missionID, baseline.missionID)
            XCTAssertEqual(runtime.snapshot.legIndex, baseline.legIndex)
            XCTAssertEqual(runtime.snapshot.waypointIndex, baseline.waypointIndex)
        }
        XCTAssertFalse(provider.virtualStickRequests.contains(false))
        runtime.abort("test cleanup")
    }

    func testDJIFailsafeModeImmediatelyPausesZerosAndKeepsCheckpoint() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }
        XCTAssertEqual(runtime.snapshot.state, .running)

        provider.telemetry.mode = .emergency
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)

        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertTrue(runtime.snapshot.message.contains("保护状态"))
        XCTAssertEqual(provider.commands.last, .zero)
        XCTAssertEqual(provider.virtualStickRequests.last, false)
        XCTAssertNotNil(runtime.snapshot.recoverableMissionName)
        runtime.abort("test cleanup")
    }

    func testPreflightRejectsStaleTelemetryAndCompetingController() throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        provider.telemetry.flightStateTimestamp = Date(timeIntervalSinceNow: -5)
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        XCTAssertTrue(runtime.preflight(mission).blocks.contains(.telemetryStale))

        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        runtime.startSimulator(mission, anotherControllerActive: true)
        XCTAssertEqual(provider.virtualStickRequests, [])
    }

    func testPreflightRejectsUnavailableCameraStorage() throws {
        let provider = SurveyFakeProvider()
        provider.camera.sdInserted = false
        provider.camera.storageReady = false
        provider.camera.photosRemaining = 0
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)

        let result = runtime.preflight(try makeMission())

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.blocks.contains(.cameraUnavailable))
    }

    func testPreflightRejectsCameraWhileRecording() throws {
        let provider = SurveyFakeProvider()
        provider.camera.recording = true
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)

        let result = runtime.preflight(try makeMission())

        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.blocks.contains(.cameraUnavailable))
    }

    func testHeldRemoteSticksBlockResumeAfterManualTakeover() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        provider.telemetry.sticksActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .paused }
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertEqual(provider.virtualStickRequests.last, false)

        runtime.resume(anotherControllerActive: false)
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertTrue(runtime.snapshot.gateBlocks.contains(.manualTakeover))
        XCTAssertTrue(runtime.snapshot.message.contains("检测到摇杆接管"))
        runtime.abort("test cleanup")
    }

    func testRealFlightResumeRevalidatesPreflightBeforeAndAfterVirtualStick() async throws {
        let provider = SurveyFakeProvider()
        provider.simulatorStatus.active = false
        provider.simulatorStatus.stateReceived = false
        provider.simulatorStatus.flying = false
        provider.telemetry.simulatorActive = false
        provider.telemetry.aircraftBattery = 80
        provider.telemetry.rcBattery = 80
        provider.telemetry.signal = 90
        provider.telemetry.satellites = 18
        provider.telemetry.gpsSignalLevel = 5
        provider.telemetry.homeLocationSet = true
        provider.telemetry.goHomeHeightMeters = 100
        provider.telemetry.maxFlightHeightMeters = 120
        provider.telemetry.maxFlightRadiusMeters = 1_000
        provider.telemetry.maxFlightRadiusEnabled = true

        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        XCTAssertTrue(runtime.preflight(mission).allowed)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }
        runtime.pause(reason: "test pause")

        let requestsBeforeBlockedResume = provider.virtualStickRequests.count
        provider.telemetry.aircraftBattery = 20
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        runtime.resume(anotherControllerActive: false)
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertTrue(runtime.snapshot.gateBlocks.contains(.aircraftBatteryLow))
        XCTAssertEqual(provider.virtualStickRequests.count, requestsBeforeBlockedResume)

        provider.telemetry.aircraftBattery = 80
        provider.telemetry.mode = .gps
        provider.telemetry.virtualStickActive = false
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        runtime.resume(anotherControllerActive: false)
        XCTAssertEqual(runtime.snapshot.state, .arming)
        provider.telemetry.aircraftBattery = 20
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .paused }
        XCTAssertTrue(runtime.snapshot.gateBlocks.contains(.aircraftBatteryLow))
        XCTAssertEqual(provider.virtualStickRequests.last, false)
        runtime.abort("test cleanup")
    }

    func testAutomaticTakeoffWaitsForStableSimulatorBeforeVirtualStick() async throws {
        let provider = SurveyFakeProvider()
        provider.telemetry.flying = false
        provider.telemetry.altitude = 0
        provider.simulatorStatus.flying = false
        provider.simulatorStatus.motorsOn = false
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        var mission = try makeMission()
        mission.constraints.takeoffMode = .autoSimulatorOnly
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)

        runtime.startSimulator(mission, anotherControllerActive: false)
        XCTAssertEqual(provider.takeOffRequests, 1)
        XCTAssertEqual(provider.virtualStickRequests, [])
        XCTAssertEqual(runtime.snapshot.state, .arming)

        provider.telemetry.flying = true
        provider.telemetry.altitude = 1.2
        provider.telemetry.verticalSpeed = 0
        provider.telemetry.flightStateTimestamp = Date()
        provider.simulatorStatus.flying = true
        provider.simulatorStatus.motorsOn = true
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        await waitUntil(iterations: 35) { provider.virtualStickRequests.last == true }
        XCTAssertEqual(provider.virtualStickRequests.last, true)
        runtime.abort("test cleanup")
    }

    func testAutomaticTakeoffSDKCallbackFailureAbortsImmediately() throws {
        let provider = SurveyFakeProvider()
        provider.telemetry.flying = false
        provider.telemetry.altitude = 0
        provider.simulatorStatus.flying = false
        provider.simulatorStatus.motorsOn = false
        provider.takeOffCallbackError = FlightActionError.unavailable("simulator takeoff rejected")
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        var mission = try makeMission()
        mission.constraints.takeoffMode = .autoSimulatorOnly
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)

        runtime.startSimulator(mission, anotherControllerActive: false)

        XCTAssertEqual(provider.takeOffRequests, 1)
        XCTAssertEqual(runtime.snapshot.state, .aborted)
        XCTAssertTrue(runtime.snapshot.message.contains("自动起飞失败"))
        XCTAssertEqual(provider.commands.last, .zero)
        XCTAssertEqual(provider.virtualStickRequests.last, false)
    }

    func testRealLowBatteryPausesAndCanRequestImmediateReturnHome() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        provider.simulatorStatus.active = false
        provider.simulatorStatus.flying = false
        runtime.updateSimulator(provider.simulatorStatus)
        provider.telemetry.aircraftBattery = 19
        provider.telemetry.flying = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)

        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertNotNil(runtime.snapshot.lowBatteryReturnSeconds)
        XCTAssertEqual(provider.virtualStickRequests.last, false)
        runtime.issueLowBatteryReturnNow()
        XCTAssertEqual(provider.returnHomeRequests, 0)
        XCTAssertTrue(provider.telemetry.virtualStickActive)
        provider.telemetry.virtualStickActive = false
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        XCTAssertEqual(provider.returnHomeRequests, 1)
        runtime.updateTelemetry(provider.telemetry)
        XCTAssertEqual(provider.returnHomeRequests, 1)
        XCTAssertNil(runtime.snapshot.lowBatteryReturnSeconds)
        runtime.abort("test cleanup")
    }

    func testLowBatteryReturnFallsBackAfterVirtualStickReleaseTimeout() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        provider.simulatorStatus.active = false
        provider.simulatorStatus.flying = false
        runtime.updateSimulator(provider.simulatorStatus)
        provider.telemetry.aircraftBattery = 19
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        runtime.issueLowBatteryReturnNow()

        XCTAssertEqual(provider.returnHomeRequests, 0)
        await waitUntil(iterations: 40) { provider.returnHomeRequests == 1 }
        XCTAssertEqual(provider.returnHomeRequests, 1)
        runtime.abort("test cleanup")
    }

    func testLowBatteryReturnWaitsForActualDJICallbackAndRetriesAfterRejection() async throws {
        let provider = SurveyFakeProvider()
        provider.returnHomeCallbackError = FlightActionError.unavailable("RTH rejected")
        let log = EventLog()
        let runtime = SurveyRuntimeController(provider: provider, log: log)
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        provider.simulatorStatus.active = false
        provider.simulatorStatus.flying = false
        runtime.updateSimulator(provider.simulatorStatus)
        provider.telemetry.aircraftBattery = 19
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        runtime.issueLowBatteryReturnNow()
        provider.telemetry.virtualStickActive = false
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)

        XCTAssertEqual(provider.returnHomeRequests, 1)
        XCTAssertTrue(log.events.contains(where: { $0.message.contains("RTH rejected") }))
        XCTAssertNotNil(runtime.snapshot.lowBatteryReturnSeconds,
                        "a rejected callback should re-arm the low-battery retry countdown")
        runtime.abort("test cleanup")
    }

    func testAlternatingRuntimeReadinessFaultsCannotResetGraceForever() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        provider.simulatorStatus.active = false
        provider.simulatorStatus.flying = false
        runtime.updateSimulator(provider.simulatorStatus)
        provider.telemetry.signal = 20
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        try await Task.sleep(nanoseconds: 1_100_000_000)

        provider.telemetry.signal = 100
        provider.telemetry.satellites = 4
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)

        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertTrue(runtime.snapshot.gateBlocks.contains(.gpsSatellitesLow))
        XCTAssertEqual(provider.commands.last, .zero)
        XCTAssertEqual(provider.virtualStickRequests.last, false)
        runtime.abort("test cleanup")
    }

    func testLowBatteryReturnReleaseWaitCanBeCancelledByLanding() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        provider.simulatorStatus.active = false
        provider.simulatorStatus.flying = false
        runtime.updateSimulator(provider.simulatorStatus)
        provider.telemetry.aircraftBattery = 19
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        runtime.issueLowBatteryReturnNow()
        provider.telemetry.flying = false
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)

        await waitUntil(iterations: 35) { provider.returnHomeRequests > 0 }
        XCTAssertEqual(provider.returnHomeRequests, 0)
        runtime.abort("test cleanup")
    }

    func testAbortedCheckpointIsDiscardedInsteadOfRestoredAsPaused() throws {
        let missionKey = "openfly.survey.active-mission.v1"
        let checkpointKey = "openfly.survey.execution-checkpoint.v2"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: missionKey)
        defaults.removeObject(forKey: checkpointKey)
        defer {
            defaults.removeObject(forKey: missionKey)
            defaults.removeObject(forKey: checkpointKey)
        }
        let mission = try makeMission()
        let checkpoint = try SurveyExecutionCheckpoint(
            missionID: mission.id, waypointIndex: 0, state: .aborted,
            updatedAtEpochMillis: 1, executionLegIndex: 0, phase: .safeClimb
        )
        defaults.set(try SurveyMissionJSON.encode(mission), forKey: missionKey)
        defaults.set(try SurveyExecutionCheckpointJSON.encode(checkpoint), forKey: checkpointKey)

        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)

        XCTAssertNil(runtime.snapshot.recoverableMissionName)
        XCTAssertNil(runtime.restorePersistedMission())
        XCTAssertNil(defaults.string(forKey: checkpointKey))
        XCTAssertNotEqual(runtime.snapshot.state, .paused)
    }

    func testRecoverableAbortCompatibilityPausesAndKeepsCheckpoint() async throws {
        let provider = SurveyFakeProvider()
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        let mission = try makeMission()
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        runtime.startSimulator(mission, anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }

        runtime.abort("外部停止", clearCheckpoint: false)

        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertEqual(provider.commands.last, .zero)
        XCTAssertEqual(provider.virtualStickRequests.last, false)
        XCTAssertNotNil(runtime.snapshot.recoverableMissionName)
        runtime.abort("test cleanup")
    }

    func testRestoredDeferredNadirCaptureStillPausesAtStripEnd() async throws {
        let missionKey = "openfly.survey.active-mission.v1"
        let checkpointKey = "openfly.survey.execution-checkpoint.v2"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: missionKey)
        defaults.removeObject(forKey: checkpointKey)
        defer {
            defaults.removeObject(forKey: missionKey)
            defaults.removeObject(forKey: checkpointKey)
        }
        let mission = try makeMission()
        let firstPass = try XCTUnwrap(try mission.surveyPasses().first)
        let checkpoint = try SurveyExecutionCheckpoint(
            missionID: mission.id, waypointIndex: firstPass.lastWaypointIndex,
            state: .paused, updatedAtEpochMillis: 1, executionLegIndex: .max,
            phase: .survey,
            recoveryPoint: mission.waypoints[firstPass.lastWaypointIndex].point,
            pendingCaptureStartWaypointIndex: firstPass.firstWaypointIndex
        )
        defaults.set(try SurveyMissionJSON.encode(mission), forKey: missionKey)
        defaults.set(try SurveyExecutionCheckpointJSON.encode(checkpoint), forKey: checkpointKey)

        let provider = SurveyFakeProvider()
        let end = mission.waypoints[firstPass.lastWaypointIndex]
        provider.telemetry.aircraft = .init(latitude: end.point.latitude, longitude: end.point.longitude)
        provider.telemetry.altitude = end.point.altitudeMeters
        provider.telemetry.heading = end.headingDegrees
        provider.telemetry.gimbalPitch = -85
        provider.telemetry.gimbalPitchAtStop = true
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)

        XCTAssertEqual(runtime.restorePersistedMission()?.id, mission.id)
        XCTAssertEqual(runtime.snapshot.state, .paused)
        runtime.resume(anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)

        await waitUntil(iterations: 30) { runtime.snapshot.state == .paused }
        XCTAssertEqual(runtime.snapshot.state, .paused)
        XCTAssertTrue(runtime.snapshot.message.contains("全程受云台下限限制"))
        XCTAssertEqual(runtime.snapshot.waypointIndex, firstPass.firstWaypointIndex)
        XCTAssertEqual(runtime.snapshot.currentTarget?.point,
                       mission.waypoints[firstPass.firstWaypointIndex].point)
        XCTAssertEqual(runtime.snapshot.currentTarget?.headingDegrees ?? .nan,
                       mission.waypoints[firstPass.firstWaypointIndex].headingDegrees,
                       accuracy: 1e-9)
        XCTAssertEqual(provider.commands.last, .zero)
        XCTAssertEqual(provider.virtualStickRequests.last, false)

        let rewoundRaw = try XCTUnwrap(defaults.string(forKey: checkpointKey))
        let rewound = try SurveyExecutionCheckpointJSON.decode(rewoundRaw)
        XCTAssertEqual(rewound.waypointIndex, firstPass.firstWaypointIndex)
        XCTAssertNil(rewound.recoveryPoint)
        XCTAssertNil(rewound.activeCaptureIntervalMeters)
        XCTAssertNil(rewound.pendingCaptureStartWaypointIndex)

        runtime.resume(anotherControllerActive: false)
        await waitUntil { runtime.snapshot.state == .running }
        XCTAssertEqual(runtime.snapshot.currentTarget?.point,
                       mission.waypoints[firstPass.firstWaypointIndex].point)
        XCTAssertEqual(runtime.snapshot.currentTarget?.headingDegrees ?? .nan,
                       mission.waypoints[firstPass.firstWaypointIndex].headingDegrees,
                       accuracy: 1e-9)
        XCTAssertNotEqual(runtime.snapshot.waypointIndex, firstPass.lastWaypointIndex)
        runtime.abort("test cleanup")
    }

    func testDeferredCaptureDoesNotStartDuringRecoveryAndPersistsActiveTransition() async throws {
        let missionKey = "openfly.survey.active-mission.v1"
        let checkpointKey = "openfly.survey.execution-checkpoint.v2"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: missionKey)
        defaults.removeObject(forKey: checkpointKey)
        defer {
            defaults.removeObject(forKey: missionKey)
            defaults.removeObject(forKey: checkpointKey)
        }
        let mission = try makeMission()
        let pass = try XCTUnwrap(try mission.surveyPasses().first)
        let start = mission.waypoints[pass.firstWaypointIndex]
        let end = mission.waypoints[pass.lastWaypointIndex]
        let recoveryPoint = SurveyGeoPoint(
            latitude: (start.point.latitude + end.point.latitude) / 2,
            longitude: (start.point.longitude + end.point.longitude) / 2,
            altitudeMeters: (start.point.altitudeMeters + end.point.altitudeMeters) / 2
        )
        let checkpoint = try SurveyExecutionCheckpoint(
            missionID: mission.id, waypointIndex: pass.lastWaypointIndex,
            state: .paused, updatedAtEpochMillis: 1, executionLegIndex: .max,
            phase: .survey, recoveryPoint: recoveryPoint,
            pendingCaptureStartWaypointIndex: pass.firstWaypointIndex
        )
        defaults.set(try SurveyMissionJSON.encode(mission), forKey: missionKey)
        defaults.set(try SurveyExecutionCheckpointJSON.encode(checkpoint), forKey: checkpointKey)

        let provider = SurveyFakeProvider()
        provider.telemetry.aircraft = .init(latitude: start.point.latitude, longitude: start.point.longitude)
        provider.telemetry.altitude = start.point.altitudeMeters
        provider.telemetry.gimbalPitch = 0
        provider.telemetry.gimbalPitchAtStop = false
        let runtime = SurveyRuntimeController(provider: provider, log: EventLog())
        runtime.updateTelemetry(provider.telemetry)
        runtime.updateSimulator(provider.simulatorStatus)
        runtime.updateCamera(provider.camera)
        XCTAssertEqual(runtime.restorePersistedMission()?.id, mission.id)

        runtime.resume(anotherControllerActive: false)
        provider.telemetry.virtualStickActive = true
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.state == .running }
        XCTAssertEqual(runtime.snapshot.phase, .recoveryToPause)
        try? await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(provider.takePhotoRequests, 0)

        let recoveryTarget = try XCTUnwrap(runtime.snapshot.currentTarget)
        provider.telemetry.aircraft = .init(latitude: recoveryTarget.point.latitude,
                                            longitude: recoveryTarget.point.longitude)
        provider.telemetry.altitude = recoveryTarget.point.altitudeMeters
        provider.telemetry.heading = recoveryTarget.headingDegrees
        provider.telemetry.gimbalPitch = 0
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { runtime.snapshot.phase == .survey }
        XCTAssertEqual(runtime.snapshot.phase, .survey)

        provider.telemetry.gimbalPitch = -90
        provider.telemetry.flightStateTimestamp = Date()
        runtime.updateTelemetry(provider.telemetry)
        await waitUntil { provider.takePhotoRequests == 1 }
        XCTAssertEqual(provider.takePhotoRequests, 1)

        let activeRaw = try XCTUnwrap(defaults.string(forKey: checkpointKey))
        let active = try SurveyExecutionCheckpointJSON.decode(activeRaw)
        XCTAssertNil(active.pendingCaptureStartWaypointIndex)
        XCTAssertEqual(try XCTUnwrap(active.activeCaptureIntervalMeters),
                       try XCTUnwrap(start.captureIntervalMeters), accuracy: 1e-6)
        runtime.abort("test cleanup")
    }

    func testSurveyControlTickUsesAndroidTwentyFiveHertzCadence() {
        XCTAssertEqual(SurveyRuntimeController.controlIntervalSeconds, 0.04, accuracy: 1e-12)
        XCTAssertEqual(SurveyRuntimeController.virtualStickReleaseFallbackMillis, 1_500)
        XCTAssertEqual(SurveyRuntimeController.runtimeReadinessGraceMillis, 1_500)
    }

    private func makeMission() throws -> SurveyMission {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 30
        constraints.safeTakeoffAltitudeMeters = 20
        constraints.speedMetersPerSecond = 1
        let center = SurveyGeoPoint(latitude: 31.2304, longitude: 121.4737)
        return try SurveyPlanner.plan(
            name: "runtime-test",
            roi: [
                .init(latitude: center.latitude - 0.00008, longitude: center.longitude - 0.00008),
                .init(latitude: center.latitude - 0.00008, longitude: center.longitude + 0.00008),
                .init(latitude: center.latitude + 0.00008, longitude: center.longitude + 0.00008),
                .init(latitude: center.latitude + 0.00008, longitude: center.longitude - 0.00008),
            ],
            constraints: constraints,
            takeoffPoint: center
        )
    }

    private func waitUntil(iterations: Int = 30,
                           _ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<iterations {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

@MainActor
final class SurveyFakeProvider: DJIFlightProvider {
    var telemetry: FlightTelemetry = {
        var value = FlightTelemetry()
        value.connected = true
        value.flying = true
        value.aircraftLocationValid = true
        value.aircraft = .init(latitude: 31.2304, longitude: 121.4737)
        value.home = value.aircraft
        value.altitude = 10
        value.heading = 0
        value.gimbalPitch = -90
        value.satellites = 18
        value.gpsSignalLevel = 5
        value.homeLocationSet = true
        value.flightStateTimestamp = Date()
        return value
    }()
    var camera = CameraStatus(connected: true, sdInserted: true,
                              photosRemaining: 1_000, message: "相机就绪")
    var latestFrame: CameraFrame?
    var simulatorStatus = FlightSimulatorStatus(available: true, active: true,
                                                 stateReceived: true, motorsOn: true,
                                                 flying: true, message: "仿真飞行中")
    var onTelemetry: ((FlightTelemetry) -> Void)?
    var onCamera: ((CameraStatus) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onSimulator: ((FlightSimulatorStatus) -> Void)?
    var onManualTakeover: (() -> Void)?
    var onDiagnostic: ((String, String) -> Void)?
    let providerName = "SurveyFakeProvider"
    var virtualStickRequests: [Bool] = []
    var commands: [VelocityCommand] = []
    var takeOffRequests = 0
    var takeOffCallbackError: Error?
    var returnHomeRequests = 0
    var returnHomeCallbackError: Error?
    var takePhotoRequests = 0
    var deferSurveyPhotoCompletion = false
    var pendingPhotoCompletions: [(Error?) -> Void] = []

    func start() {}
    func stop() {}
    func resumeConnection() {}
    func pauseConnection() {}
    func takeOff() throws { takeOffRequests += 1 }
    func takeOff(completion: @escaping (Error?) -> Void) {
        takeOffRequests += 1
        completion(takeOffCallbackError)
    }
    func land() throws {}
    func cancelLanding() throws {}
    func returnHome() throws { returnHomeRequests += 1 }
    func returnHome(completion: @escaping (Error?) -> Void) {
        returnHomeRequests += 1
        completion(returnHomeCallbackError)
    }
    func cancelReturnHome() throws {}
    func setVirtualStick(enabled: Bool) { virtualStickRequests.append(enabled) }
    func send(_ command: VelocityCommand) { commands.append(command) }
    func setGimbalPitch(degrees: Double) throws {}
    func takePhoto() throws { takePhotoRequests += 1 }
    func takeSurveyPhoto(completion: @escaping (Error?) -> Void) {
        takePhotoRequests += 1
        if deferSurveyPhotoCompletion { pendingPhotoCompletions.append(completion) }
        else { completion(nil) }
    }
    func toggleRecording() throws {}
    func captureModelFrame() async throws -> CameraFrame { throw FlightActionError.unavailable("unused") }
    func setSimulator(enabled: Bool) async throws {}
    func simulateDisconnect() {}
    func simulateStaleTelemetry() {}
    func simulateManualTakeover() {}
    func simulateCameraError() {}
}
