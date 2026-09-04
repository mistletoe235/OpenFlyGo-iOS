import XCTest
@testable import DJIVLNiOS

final class PositionControllerTests: XCTestCase {
    func testVelocityModelStateIntegratesEveryUniqueFlightSample() {
        let start = Date()
        var estimator = VelocityModelStateEstimator()
        var telemetry = FlightTelemetry()
        telemetry.heading = 0
        telemetry.velocityNorth = 1
        telemetry.flightStateTimestamp = start
        estimator.update(telemetry)
        telemetry.flightStateTimestamp = start.addingTimeInterval(0.1)
        estimator.update(telemetry)
        telemetry.flightStateTimestamp = start.addingTimeInterval(0.2)
        estimator.update(telemetry)
        XCTAssertEqual(estimator.modelState[0], 0.2, accuracy: 0.0001)

        // A non-flight callback with the same flight timestamp must not integrate twice.
        telemetry.timestamp = start.addingTimeInterval(0.25)
        estimator.update(telemetry)
        XCTAssertEqual(estimator.modelState[0], 0.2, accuracy: 0.0001)
    }

    func testVelocityModelStateRotatesIntoInitialBodyFrameAndSkipsGaps() {
        let start = Date()
        var estimator = VelocityModelStateEstimator()
        var telemetry = FlightTelemetry()
        telemetry.heading = 90
        telemetry.velocityEast = 1
        telemetry.flightStateTimestamp = start
        estimator.update(telemetry)
        telemetry.heading = 100
        telemetry.flightStateTimestamp = start.addingTimeInterval(1)
        estimator.update(telemetry)
        XCTAssertEqual(estimator.modelState[0], 1, accuracy: 0.0001)
        XCTAssertEqual(estimator.modelState[1], 0, accuracy: 0.0001)
        XCTAssertEqual(estimator.modelState[3], 10 * .pi / 180, accuracy: 0.0001)

        telemetry.flightStateTimestamp = start.addingTimeInterval(3)
        estimator.update(telemetry)
        XCTAssertEqual(estimator.modelState[0], 1, accuracy: 0.0001)
    }

    func testOrinTrajectoryYawAndFlyThroughLimits() {
        XCTAssertEqual(
            OrinTrajectorySemantics.yawDeltaDegrees(forward: 2, right: 0.2),
            5.7106,
            accuracy: 0.001
        )
        XCTAssertEqual(OrinTrajectorySemantics.flyThroughRadius(segmentDistance: 0.5), 0.125, accuracy: 0.0001)
        XCTAssertEqual(OrinTrajectorySemantics.flyThroughRadius(segmentDistance: 3), 0.75, accuracy: 0.0001)
        XCTAssertEqual(OrinTrajectorySemantics.flyThroughTimeout(segmentDistance: 3), 20, accuracy: 0.0001)
    }

    func testVelocityCommandSlewLimiterBoundsAccelerationAndReversal() {
        let start = Date()
        var limiter = VelocityCommandSlewLimiter(
            maximumHorizontalAcceleration: 0.8,
            maximumVerticalAcceleration: 0.5,
            maximumYawAcceleration: 30
        )
        limiter.reset(at: start)
        let accelerated = limiter.limit(
            VelocityCommand(forward: 2, right: 0, up: 1, yawRate: 45),
            at: start.addingTimeInterval(0.1)
        )
        XCTAssertEqual(accelerated.forward, 0.08, accuracy: 0.001)
        XCTAssertEqual(accelerated.up, 0.05, accuracy: 0.001)
        XCTAssertEqual(accelerated.yawRate, 3, accuracy: 0.001)

        let reversed = limiter.limit(
            VelocityCommand(forward: -2, right: 0, up: -1, yawRate: -45),
            at: start.addingTimeInterval(0.2)
        )
        XCTAssertEqual(reversed.forward, 0, accuracy: 0.001)
        XCTAssertEqual(reversed.up, 0, accuracy: 0.001)
        XCTAssertEqual(reversed.yawRate, 0, accuracy: 0.001)

        limiter.reset(at: start.addingTimeInterval(0.2))
        XCTAssertEqual(limiter.current, .zero)
    }

    func testBodyForwardMapsToDJIRollAndBodyRightMapsToDJIPitch() {
        let axes = BodyVelocityToDJIAxes.map(VelocityCommand(
            forward: 2.0, right: -0.4, up: 0.0, yawRate: 12.0
        ))
        XCTAssertEqual(axes.roll, 2.0, accuracy: 0.001)
        XCTAssertEqual(axes.pitch, -0.4, accuracy: 0.001)
        XCTAssertEqual(axes.verticalThrottle, 0.0, accuracy: 0.001)
        XCTAssertEqual(axes.yaw, 12.0, accuracy: 0.001)
    }

    func testRelativePositionConvertsToBoundedVelocity() {
        let action = RelativeAction(forwardMeters: 1, rightMeters: -2, upMeters: 0.5, yawDegrees: 10, confidence: 1, stopScore: 0, reason: "test")
        let command = PositionController().command(for: action)
        XCTAssertEqual(command.forward, 0.8, accuracy: 0.001)
        XCTAssertEqual(command.right, -1.6, accuracy: 0.001)
        XCTAssertEqual(command.up, 0.35, accuracy: 0.001)
        XCTAssertEqual(command.yawRate, 9, accuracy: 0.001)
    }

    func testExtremeActionIsClamped() {
        let action = RelativeAction(forwardMeters: 99, rightMeters: -99, upMeters: 9, yawDegrees: -100, confidence: 1, stopScore: 0, reason: "test")
        let command = PositionController().command(for: action)
        XCTAssertEqual(command.forward, 4)
        XCTAssertEqual(command.right, -4)
        XCTAssertEqual(command.up, 1)
        XCTAssertEqual(command.yawRate, -45)
    }

    func testGPSClosedLoopReachesOneMeterSimulatorTarget() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.heading = 0
        telemetry.simulatorActive = true
        telemetry.aircraftLocationValid = true
        let action = RelativeAction(
            forwardMeters: 1, rightMeters: 0, upMeters: 0, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        let loop = RelativePositionClosedLoop()
        let initial = try loop.start(action: action, telemetry: telemetry, mode: .gps, now: now)
        XCTAssertFalse(initial.terminal)
        XCTAssertGreaterThan(initial.command.forward, 0)

        telemetry.aircraft.latitude += 1 / 111_319.49
        telemetry.timestamp = now.addingTimeInterval(0.1)
        let reached = loop.step(telemetry: telemetry, now: telemetry.timestamp)
        XCTAssertTrue(reached.terminal)
        XCTAssertTrue(reached.successful)
        XCTAssertEqual(reached.command, .zero)
    }

    func testVelocityEstimateClosesWithoutGPS() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.aircraftLocationValid = false
        telemetry.heading = 0
        telemetry.velocityNorth = 1
        telemetry.horizontalSpeed = 1
        let action = RelativeAction(
            forwardMeters: 1, rightMeters: 0, upMeters: 0, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        let loop = RelativePositionClosedLoop()
        _ = try loop.start(action: action, telemetry: telemetry, mode: .velocityEstimate, now: now)

        var step: RelativePositionClosedLoop.Step?
        for index in 1...4 {
            telemetry.timestamp = now.addingTimeInterval(Double(index) * 0.2)
            step = loop.step(telemetry: telemetry, now: telemetry.timestamp)
        }
        XCTAssertTrue(step?.terminal == true)
        XCTAssertTrue(step?.successful == true)
    }

    func testZeroModelZAlwaysLeavesDJIVerticalVelocityCenteredDespiteAltitudeDrift() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.aircraftLocationValid = false
        telemetry.altitude = 10
        let action = RelativeAction(
            forwardMeters: 1, rightMeters: 0, upMeters: 0, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        let loop = RelativePositionClosedLoop()
        let initial = try loop.start(action: action, telemetry: telemetry, mode: .velocityEstimate, now: now)
        XCTAssertEqual(initial.command.up, 0, accuracy: 0.001)

        telemetry.altitude = 9.4
        telemetry.verticalSpeed = 0.2
        telemetry.timestamp = now.addingTimeInterval(0.2)
        let drifted = loop.step(telemetry: telemetry, now: telemetry.timestamp)
        XCTAssertEqual(drifted.command.up, 0, accuracy: 0.001)
        XCTAssertEqual(drifted.verticalErrorMeters, 0, accuracy: 0.001)
    }

    func testRelativeVerticalTargetUsesMeasuredVelocityIntegration() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.aircraftLocationValid = false
        telemetry.altitude = 1.2
        let action = RelativeAction(
            forwardMeters: 0, rightMeters: 0, upMeters: 0.4, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        let loop = RelativePositionClosedLoop()
        let initial = try loop.start(action: action, telemetry: telemetry, mode: .velocityEstimate, now: now)
        XCTAssertEqual(initial.command.up, 0.2, accuracy: 0.001)

        var step = initial
        telemetry.verticalSpeed = 0.2
        for index in 1...8 {
            telemetry.timestamp = now.addingTimeInterval(Double(index) * 0.2)
            step = loop.step(telemetry: telemetry, now: telemetry.timestamp)
        }
        XCTAssertFalse(step.terminal)
        XCTAssertEqual(step.command.up, 0, accuracy: 0.001)

        telemetry.verticalSpeed = 0
        telemetry.timestamp = now.addingTimeInterval(1.8)
        step = loop.step(telemetry: telemetry, now: telemetry.timestamp)
        XCTAssertTrue(step.terminal)
        XCTAssertTrue(step.successful)
        XCTAssertEqual(step.command.up, 0, accuracy: 0.001)
    }

    func testBarometerDriftDoesNotCreateVerticalProgress() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.aircraftLocationValid = false
        telemetry.altitude = 10
        let action = RelativeAction(
            forwardMeters: 0, rightMeters: 0, upMeters: 0.4, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        let loop = RelativePositionClosedLoop()
        _ = try loop.start(action: action, telemetry: telemetry, mode: .velocityEstimate, now: now)

        telemetry.altitude = 8.5
        telemetry.verticalSpeed = 0
        telemetry.timestamp = now.addingTimeInterval(0.2)
        let step = loop.step(telemetry: telemetry, now: telemetry.timestamp)
        XCTAssertEqual(step.verticalErrorMeters, 0.4, accuracy: 0.001)
        XCTAssertEqual(step.command.up, 0.2, accuracy: 0.001)
    }

    func testVerticalTargetAndLowAltitudeDescentSafetyLimits() {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.aircraftLocationValid = false
        telemetry.altitude = 10
        telemetry.downwardHeightValid = true
        telemetry.downwardHeight = 1.0

        let excessive = RelativeAction(
            forwardMeters: 0, rightMeters: 0, upMeters: 0.6, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        XCTAssertThrowsError(try RelativePositionClosedLoop().start(
            action: excessive, telemetry: telemetry, mode: .velocityEstimate, now: now
        ))

        let tooLow = RelativeAction(
            forwardMeters: 0, rightMeters: 0, upMeters: -0.3, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        XCTAssertThrowsError(try RelativePositionClosedLoop().start(
            action: tooLow, telemetry: telemetry, mode: .velocityEstimate, now: now
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("0.8m"))
        }
    }

    func testGPSModeRejectsInvalidIndoorLocation() {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.aircraftLocationValid = false
        XCTAssertThrowsError(try RelativePositionClosedLoop().start(
            action: .zero, telemetry: telemetry, mode: .gps, now: now
        ))
    }

    func testVelocityEstimateUsesSelectedHorizontalLimit() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.aircraftLocationValid = false
        let action = RelativeAction(
            forwardMeters: 3, rightMeters: 0, upMeters: 0, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        let step = try RelativePositionClosedLoop().start(
            action: action, telemetry: telemetry, mode: .velocityEstimate,
            maximumHorizontalSpeed: 0.3, now: now
        )
        XCTAssertEqual(step.command.forward, 0.3, accuracy: 0.001)
        XCTAssertEqual(step.command.right, 0, accuracy: 0.001)
    }

    func testOrdinaryGPSUsesSelectedHorizontalLimitWithoutOuterCap() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.simulatorActive = false
        telemetry.aircraftLocationValid = true
        let action = RelativeAction(
            forwardMeters: 3, rightMeters: 0, upMeters: 0, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        let step = try RelativePositionClosedLoop().start(
            action: action, telemetry: telemetry, mode: .gps,
            maximumHorizontalSpeed: 3.4, now: now
        )
        XCTAssertEqual(step.command.forward, 1.8, accuracy: 0.001)
    }

    func testSelectedHorizontalLimitIsClampedOnlyAtFourMetersPerSecond() throws {
        let now = Date()
        var telemetry = FlightTelemetry()
        telemetry.timestamp = now
        telemetry.aircraftLocationValid = false
        let action = RelativeAction(
            forwardMeters: 10, rightMeters: 0, upMeters: 0, yawDegrees: 0,
            confidence: 1, stopScore: 0, reason: "test"
        )
        let step = try RelativePositionClosedLoop().start(
            action: action, telemetry: telemetry, mode: .velocityEstimate,
            maximumHorizontalSpeed: 9, now: now
        )
        XCTAssertEqual(step.command.forward, 4, accuracy: 0.001)
    }
}
