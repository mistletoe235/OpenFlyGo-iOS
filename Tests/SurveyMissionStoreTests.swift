import XCTest
@testable import DJIVLNiOS

@MainActor
final class SurveyMissionStoreTests: XCTestCase {
    func testStorePersistsVersionsAndDoesNotEraseCorruptRawData() throws {
        let suite = "SurveyMissionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "library"
        let activeKey = "active"
        let store = SurveyMissionStore(defaults: defaults, key: key, activeKey: activeKey)
        let mission = try makeMission()

        let first = try store.save(mission)
        let second = try store.save(mission)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(SurveyMissionStore(defaults: defaults, key: key, activeKey: activeKey).versions.count, 2)

        try store.persistActive(mission)
        XCTAssertEqual(try store.restoreActive()?.id, mission.id)
        store.clearActive()
        XCTAssertNil(try store.restoreActive())

        try store.delete(versionID: second.versionID)
        XCTAssertEqual(store.versions.map(\.versionID), [first.versionID])
        defaults.set("{not-json", forKey: key)
        let corrupted = SurveyMissionStore(defaults: defaults, key: key, activeKey: activeKey)
        XCTAssertTrue(corrupted.versions.isEmpty)
        XCTAssertNotNil(corrupted.persistenceError)
        XCTAssertEqual(defaults.string(forKey: key), "{not-json")
    }

    private func makeMission() throws -> SurveyMission {
        var constraints = SurveyConstraints()
        constraints.altitudeMetersAgl = 30
        constraints.speedMetersPerSecond = 1
        return try SurveyPlanner.plan(name: "persistent", roi: [
            .init(latitude: 31, longitude: 121),
            .init(latitude: 31, longitude: 121.0002),
            .init(latitude: 31.0002, longitude: 121.0002),
            .init(latitude: 31.0002, longitude: 121),
        ], constraints: constraints)
    }
}
