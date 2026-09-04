import Foundation

@MainActor
final class SurveyMissionStore: ObservableObject {
    @Published private(set) var versions: [SurveyMissionVersion] = []
    @Published private(set) var persistenceError: String?

    private let defaults: UserDefaults
    private let key: String
    private let activeKey: String

    init(defaults: UserDefaults = .standard,
         key: String = "openfly.survey.mission.library.v1",
         activeKey: String = "openfly.survey.active-mission.v1") {
        self.defaults = defaults
        self.key = key
        self.activeKey = activeKey
        reload()
    }

    func reload() {
        do {
            versions = try SurveyMissionLibrary.decode(defaults.string(forKey: key))
            persistenceError = nil
        } catch {
            // Fail closed: preserve the unread raw value and expose the error.
            versions = []
            persistenceError = "任务库读取失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func save(_ mission: SurveyMission) throws -> SurveyMissionVersion {
        let updated = try SurveyMissionLibrary.addVersion(existing: versions, mission: mission)
        try persist(updated)
        guard let added = updated.first else {
            throw SurveyValidationError.invalid("mission library did not retain the saved version")
        }
        return added
    }

    func importMissionJSON(_ raw: String) throws -> SurveyMission {
        let mission = try SurveyMissionJSON.decode(raw)
        _ = try save(mission)
        try persistActive(mission)
        return mission
    }

    func persistActive(_ mission: SurveyMission) throws {
        let raw = try SurveyMissionJSON.encode(mission)
        defaults.set(raw, forKey: activeKey)
        guard defaults.string(forKey: activeKey) == raw else {
            throw SurveyValidationError.invalid("active mission could not be persisted")
        }
    }

    func restoreActive() throws -> SurveyMission? {
        guard let raw = defaults.string(forKey: activeKey) else { return nil }
        return try SurveyMissionJSON.decode(raw)
    }

    func clearActive() {
        defaults.removeObject(forKey: activeKey)
    }

    func delete(versionID: String) throws {
        try persist(versions.filter { $0.versionID != versionID })
    }

    func clearError() { persistenceError = nil }

    private func persist(_ updated: [SurveyMissionVersion]) throws {
        let raw = try SurveyMissionLibrary.encode(updated)
        defaults.set(raw, forKey: key)
        guard defaults.string(forKey: key) == raw else {
            throw SurveyValidationError.invalid("mission library could not be persisted")
        }
        versions = updated
        persistenceError = nil
    }
}
