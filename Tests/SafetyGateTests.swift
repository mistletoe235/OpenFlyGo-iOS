import XCTest
@testable import DJIVLNiOS

final class SafetyGateTests: XCTestCase {
    func testStopAtBoundaryIsBlocked() {
        var action = RelativeAction.zero
        action.stopScore = 0.7
        let result = SafetyGate().evaluate(action: action, telemetry: FlightTelemetry(), emergencyStopped: false)
        XCTAssertFalse(result.eligible)
        XCTAssertEqual(result.command, .zero)
    }

    func testCustomStopThresholdIsUsedInclusively() {
        var action = RelativeAction.zero
        action.stopScore = 0.6
        let telemetry = FlightTelemetry()
        XCTAssertTrue(SafetyGate().evaluate(
            action: action, telemetry: telemetry, emergencyStopped: false, stopThreshold: 0.7
        ).eligible)
        XCTAssertFalse(SafetyGate().evaluate(
            action: action, telemetry: telemetry, emergencyStopped: false, stopThreshold: 0.6
        ).eligible)
    }

    func testStaleTelemetryAndFrameAreBlocked() {
        var telemetry = FlightTelemetry()
        telemetry.timestamp = Date(timeIntervalSinceNow: -2)
        XCTAssertEqual(SafetyGate().evaluate(action: .zero, telemetry: telemetry, emergencyStopped: false).reason, "遥测已过期")
        telemetry.timestamp = Date(); telemetry.frameTimestamp = Date(timeIntervalSinceNow: -3)
        XCTAssertEqual(SafetyGate().evaluate(action: .zero, telemetry: telemetry, emergencyStopped: false).reason, "图像帧已过期")
    }

    func testCommandIsClamped() {
        let action = RelativeAction(forwardMeters: 20, rightMeters: -20, upMeters: 9, yawDegrees: 180, confidence: 1, stopScore: 0, reason: "test")
        let result = SafetyGate().evaluate(action: action, telemetry: FlightTelemetry(), emergencyStopped: false)
        XCTAssertTrue(result.eligible)
        XCTAssertEqual(result.command.forward, 4, accuracy: 0.001)
        XCTAssertEqual(result.command.right, -4, accuracy: 0.001)
        XCTAssertEqual(result.command.up, 1, accuracy: 0.001)
        XCTAssertEqual(result.command.yawRate, 45, accuracy: 0.001)
    }

    func testDisconnectAndEmergencyHavePriority() {
        var telemetry = FlightTelemetry(); telemetry.connected = false
        XCTAssertFalse(SafetyGate().evaluate(action: .zero, telemetry: telemetry, emergencyStopped: false).eligible)
        telemetry.connected = true
        XCTAssertEqual(SafetyGate().evaluate(action: .zero, telemetry: telemetry, emergencyStopped: true).reason, "急停已锁定")
    }
}
