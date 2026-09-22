import XCTest
@testable import DJIVLNiOS

final class SurveyStoppedCapturePosePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let target = SurveyWaypoint(
        point: .init(latitude: 31, longitude: 121, altitudeMeters: 40),
        headingDegrees: 1, gimbalPitchDegrees: -45,
        kind: .capturePoint, captureAction: .captureOnReach, passIndex: 0
    )

    private func freshTelemetry() -> FlightTelemetry {
        var telemetry = FlightTelemetry()
        telemetry.connected = true
        telemetry.aircraftLocationValid = true
        telemetry.altitude = 40
        telemetry.heading = 359
        telemetry.gimbalPitch = -45
        telemetry.horizontalSpeed = 0
        telemetry.flightStateTimestamp = now
        telemetry.gimbalStateTimestamp = now
        return telemetry
    }

    private func aligned(_ telemetry: FlightTelemetry) -> Bool {
        SurveyStoppedCapturePosePolicy.aligned(
            telemetry: telemetry, target: target, position: target.point, now: now
        )
    }

    func testFreshAlignedPoseAcceptsHeadingWraparound() {
        XCTAssertTrue(aligned(freshTelemetry()))
    }

    func testMissingStaleAndFutureGimbalSamplesCannotBeRefreshedByFlightTelemetry() {
        let timestamps: [Date?] = [nil, now.addingTimeInterval(-1.01), now.addingTimeInterval(0.01)]
        for timestamp in timestamps {
            var telemetry = freshTelemetry()
            telemetry.gimbalStateTimestamp = timestamp
            XCTAssertFalse(aligned(telemetry))
        }
        var telemetry = freshTelemetry()
        telemetry.flightStateTimestamp = now.addingTimeInterval(-1.01)
        XCTAssertFalse(aligned(telemetry))
    }

    func testMotionAndPoseErrorsBlockCaptureWithoutWeakeningFreshness() {
        var telemetry = freshTelemetry()
        telemetry.horizontalSpeed = 0.36
        XCTAssertFalse(aligned(telemetry))
        telemetry = freshTelemetry()
        telemetry.heading = 5
        XCTAssertFalse(aligned(telemetry))
        telemetry = freshTelemetry()
        telemetry.altitude = 41.01
        XCTAssertFalse(aligned(telemetry))
        telemetry = freshTelemetry()
        telemetry.connected = false
        XCTAssertFalse(aligned(telemetry))
    }

    func testInterruptedPoseRestartsStableDwell() {
        let initial = SurveyStoppedCapturePosePolicy.updateStableSince(aligned: true, previous: 0, now: 1_000)
        XCTAssertFalse(SurveyStoppedCapturePosePolicy.stable(since: initial, now: 1_799))
        XCTAssertTrue(SurveyStoppedCapturePosePolicy.stable(since: initial, now: 1_800))
        let interrupted = SurveyStoppedCapturePosePolicy.updateStableSince(aligned: false, previous: initial, now: 1_850)
        XCTAssertEqual(interrupted, 0)
        let resumed = SurveyStoppedCapturePosePolicy.updateStableSince(aligned: true, previous: interrupted, now: 2_000)
        XCTAssertFalse(SurveyStoppedCapturePosePolicy.stable(since: resumed, now: 2_100))
    }
}
