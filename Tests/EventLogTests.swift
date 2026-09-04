import XCTest
@testable import DJIVLNiOS

@MainActor
final class EventLogTests: XCTestCase {
    func testLogIsBoundedAndSnapshotExportsJSON() throws {
        let log = EventLog()
        for index in 0..<105 { log.append("输出", "event \(index)") }
        XCTAssertEqual(log.events.count, 100)
        let url = try XCTUnwrap(log.snapshot(
            telemetry: FlightTelemetry(),
            control: ControlSnapshot(mode: .manual, owner: .remote, reason: "test")
        ))
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["controlMode"] as? String, "人工控制")
    }
}
