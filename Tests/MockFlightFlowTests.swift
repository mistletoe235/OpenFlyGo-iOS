import XCTest
@testable import DJIVLNiOS

@MainActor
final class MockFlightFlowTests: XCTestCase {
    func testGroundedSimulatorSampleRemainsUsableButMovingSampleMustStayFresh() {
        let now: UInt64 = 2_000_000_000
        var state = FlightSimulatorStatus(
            available: true,
            active: true,
            stateReceived: true,
            sampleMonotonicNanoseconds: 1_000_000_000
        )

        XCTAssertTrue(SimulatorRawStatePolicy.hasAuthoritativeSample(state, now: now))
        XCTAssertTrue(
            SimulatorRawStatePolicy.isReadyForControl(state, now: now),
            "MSDK4 iOS may keep a confirmed stationary ground sample until a state transition"
        )

        state.motorsOn = true
        XCTAssertFalse(SimulatorRawStatePolicy.isReadyForControl(state, now: now))
        state.sampleMonotonicNanoseconds = now - 499_999_999
        XCTAssertTrue(SimulatorRawStatePolicy.isReadyForControl(state, now: now))

        state.motorsOn = false
        state.flying = true
        state.sampleMonotonicNanoseconds = now - 500_000_001
        XCTAssertFalse(SimulatorRawStatePolicy.isReadyForControl(state, now: now))
    }

    func testSimulatorSamplePolicyRejectsMissingInactiveAndFutureSamples() {
        let now: UInt64 = 2_000
        var state = FlightSimulatorStatus(active: true, stateReceived: true)
        XCTAssertFalse(SimulatorRawStatePolicy.hasAuthoritativeSample(state, now: now))

        state.sampleMonotonicNanoseconds = 1_000
        state.active = false
        XCTAssertFalse(SimulatorRawStatePolicy.isReadyForControl(state, now: now))

        state.active = true
        state.sampleMonotonicNanoseconds = now + 1
        XCTAssertFalse(SimulatorRawStatePolicy.isReadyForControl(state, now: now))
    }

    func testGroundedSimulatorNavigationAcceptsRealGPSEvidenceDespiteManualDisplayMode() {
        let simulator = FlightSimulatorStatus(
            available: true,
            active: true,
            stateReceived: true,
            motorsOn: false,
            flying: false,
            sampleMonotonicNanoseconds: 1
        )
        var telemetry = FlightTelemetry()
        telemetry.mode = .manual
        telemetry.satellites = 18
        telemetry.gpsSignalLevel = 5
        telemetry.aircraftLocationValid = true
        telemetry.homeLocationSet = true

        XCTAssertTrue(
            SimulatorNavigationReadiness.isReady(
                simulator: simulator,
                telemetry: telemetry
            ),
            "the exact 12 Pro ground state from the device log must not deadlock takeoff"
        )
    }

    func testSimulatorNavigationStillFailsClosedWithoutGPSEvidenceOrOnceAirborne() {
        var simulator = FlightSimulatorStatus(
            available: true,
            active: true,
            stateReceived: true,
            sampleMonotonicNanoseconds: 1
        )
        var telemetry = FlightTelemetry()
        telemetry.mode = .manual
        telemetry.satellites = 18
        telemetry.gpsSignalLevel = 5
        telemetry.aircraftLocationValid = true
        telemetry.homeLocationSet = true

        telemetry.homeLocationSet = false
        XCTAssertFalse(SimulatorNavigationReadiness.isReady(simulator: simulator, telemetry: telemetry))
        telemetry.homeLocationSet = true
        telemetry.aircraftLocationValid = false
        XCTAssertFalse(SimulatorNavigationReadiness.isReady(simulator: simulator, telemetry: telemetry))
        telemetry.aircraftLocationValid = true
        telemetry.satellites = 5
        XCTAssertFalse(SimulatorNavigationReadiness.isReady(simulator: simulator, telemetry: telemetry))
        telemetry.satellites = 18
        telemetry.gpsSignalLevel = 1
        XCTAssertFalse(SimulatorNavigationReadiness.isReady(simulator: simulator, telemetry: telemetry))

        telemetry.gpsSignalLevel = 5
        simulator.motorsOn = true
        XCTAssertFalse(SimulatorNavigationReadiness.isReady(simulator: simulator, telemetry: telemetry))
        telemetry.mode = .gps
        XCTAssertTrue(SimulatorNavigationReadiness.isReady(simulator: simulator, telemetry: telemetry))
    }

    func testRawSimulatorPublisherUsesSessionGenerationInsteadOfSDKObjectIdentity() {
        let publisher = DJIRawSimulatorStatePublisher()
        let firstSession = publisher.beginSession(active: true)
        let state = FlightSimulatorStatus(
            available: true,
            active: true,
            stateReceived: true,
            sampleMonotonicNanoseconds: 1_000
        )
        XCTAssertNotNil(publisher.publish(
            sessionGeneration: firstSession,
            state,
            receivedAt: 1_000
        ))

        let secondSession = publisher.beginSession(active: true)
        XCTAssertNil(publisher.publish(
            sessionGeneration: firstSession,
            state,
            receivedAt: 2_000
        ), "a queued callback from the old DJI session must be rejected")
        XCTAssertNotNil(publisher.publish(
            sessionGeneration: secondSession,
            state,
            receivedAt: 2_000
        ), "the current session must not depend on DJI wrapper object identity")

        publisher.beginSession(active: false)
        XCTAssertNil(publisher.publish(
            sessionGeneration: secondSession,
            state,
            receivedAt: 3_000
        ), "disconnect must invalidate the active callback session")
    }

    func testDJIFlightStateReceiptPreservesCallbackTimeAndRejectsQueuedOlderState() {
        let callbackTime = Date(timeIntervalSince1970: 100)
        let receipt = DJIFlightStateReceipt(
            wallClock: callbackTime,
            monotonicNanoseconds: 2_000
        )

        XCTAssertEqual(receipt.wallClock, callbackTime)
        XCTAssertTrue(receipt.isNewer(than: 1_999))
        XCTAssertFalse(receipt.isNewer(than: 2_000))
        XCTAssertFalse(receipt.isNewer(than: 2_001))
        XCTAssertEqual(Date(timeIntervalSince1970: 105).timeIntervalSince(receipt.wallClock), 5)
    }

    func testTakeoffVirtualStickAndManualTakeover() throws {
        let provider = MockFlightProvider()
        var takeover = false
        provider.onManualTakeover = {
            takeover = true
            provider.setVirtualStick(enabled: false)
        }
        try provider.takeOff()
        XCTAssertTrue(provider.telemetry.flying)
        provider.setVirtualStick(enabled: true)
        provider.send(VelocityCommand(forward: 1, right: 0, up: 0, yawRate: 0))
        provider.simulateManualTakeover()
        XCTAssertTrue(takeover)
        XCTAssertFalse(provider.telemetry.virtualStickActive)
        XCTAssertEqual(provider.telemetry.mode, .gps)
    }

    func testRTHAndLandingCanBeCancelled() throws {
        let provider = MockFlightProvider(); try provider.takeOff()
        try provider.returnHome(); XCTAssertEqual(provider.telemetry.mode, .returningHome)
        try provider.cancelReturnHome(); XCTAssertEqual(provider.telemetry.mode, .gps)
        try provider.land(); XCTAssertEqual(provider.telemetry.mode, .landing)
        try provider.cancelLanding(); XCTAssertEqual(provider.telemetry.mode, .gps)
    }

    func testCameraMockOperationsAndError() throws {
        let provider = MockFlightProvider(); let before = provider.camera.photosRemaining
        try provider.takePhoto(); XCTAssertEqual(provider.camera.photosRemaining, before - 1)
        try provider.toggleRecording(); XCTAssertTrue(provider.camera.recording)
        provider.simulateCameraError(); XCTAssertFalse(provider.camera.connected)
        XCTAssertThrowsError(try provider.takePhoto())
    }
}
