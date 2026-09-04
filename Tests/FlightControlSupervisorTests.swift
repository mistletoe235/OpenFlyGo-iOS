import XCTest
@testable import DJIVLNiOS

final class FlightControlSupervisorTests: XCTestCase {
    private let supervisor = FlightControlSupervisor()

    func testAllOperationalModes() {
        var telemetry = FlightTelemetry()
        XCTAssertEqual(resolve(telemetry).mode, .manual)
        XCTAssertEqual(resolve(telemetry, armed: true).mode, .holding)
        XCTAssertEqual(resolve(telemetry, armed: true, fresh: true).mode, .vlnStandby)
        XCTAssertEqual(resolve(telemetry, armed: true, fresh: true, executing: true).mode, .vlnExecuting)
        telemetry.mode = .returningHome; XCTAssertEqual(resolve(telemetry, armed: true).mode, .returningHome)
        telemetry.mode = .landing; XCTAssertEqual(resolve(telemetry, armed: true).mode, .landing)
        telemetry.connected = false; XCTAssertEqual(resolve(telemetry, emergency: true).mode, .failsafe)
    }

    func testManualTakeoverReturnsControlToRemote() {
        let state = resolve(FlightTelemetry(), armed: true, fresh: true, executing: true, takeover: true)
        XCTAssertEqual(state.mode, .manual)
        XCTAssertEqual(state.owner, .remote)
    }

    func testSurveyOwnershipIsExplicitAndManualTakeoverStillWins() {
        XCTAssertEqual(resolve(FlightTelemetry(), survey: .arming).mode, .surveyArming)
        let running = resolve(FlightTelemetry(), survey: .running)
        XCTAssertEqual(running.mode, .surveyExecuting)
        XCTAssertEqual(running.owner, .survey)
        XCTAssertEqual(resolve(FlightTelemetry(), survey: .paused).mode, .surveyPaused)
        XCTAssertEqual(resolve(FlightTelemetry(), takeover: true, survey: .running).owner, .remote)
    }

    private func resolve(_ telemetry: FlightTelemetry, emergency: Bool = false, armed: Bool = false,
                         fresh: Bool = false, executing: Bool = false, takeover: Bool = false,
                         survey: SurveyExecutionState = .idle) -> ControlSnapshot {
        supervisor.resolve(telemetry: telemetry, emergencyStopped: emergency, vlnArmed: armed,
                           commandFresh: fresh, commandExecuting: executing,
                           manualTakeover: takeover, surveyState: survey)
    }
}
