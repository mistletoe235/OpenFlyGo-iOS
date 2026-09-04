import Foundation

enum SurveyMissionCaptureViewFilter {
    static func select(_ mission: SurveyMission, enabledViews: Set<SurveyCaptureView>) throws -> SurveyMission {
        guard mission.activeMapping == nil else {
            throw SurveyValidationError.invalid("主动补拍任务的采集组由任务文件固定，不能重新筛选")
        }
        guard mission.constraints.collectionMode == .obliqueFiveDirection else {
            throw SurveyValidationError.invalid("only oblique missions can select route groups")
        }
        guard !enabledViews.isEmpty else { throw SurveyValidationError.invalid("至少保留 1 组航线") }
        guard enabledViews.isSubset(of: mission.constraints.enabledCaptureViews) else {
            throw SurveyValidationError.invalid("当前任务不包含新选择的航线组，请重新导入 DSM 后生成")
        }
        let selected = try mission.surveyPasses().filter { enabledViews.contains($0.start.captureView) }
        let waypoints = selected.enumerated().flatMap { passIndex, pass in
            pass.waypoints.map { waypoint -> SurveyWaypoint in
                var result = waypoint; result.passIndex = passIndex; return result
            }
        }
        guard !waypoints.isEmpty else { throw SurveyValidationError.invalid("所选航线组没有可执行航点") }
        var constraints = mission.constraints; constraints.enabledCaptureViews = enabledViews
        var filtered = mission
        filtered.id = UUID().uuidString
        filtered.createdAtEpochMillis = Int64(Date().timeIntervalSince1970 * 1_000)
        filtered.constraints = constraints
        filtered.waypoints = waypoints
        filtered.estimatedPathMeters = zip(waypoints, waypoints.dropFirst()).reduce(0) { $0 + SurveyCaptureSchedule.distance($1.0.point, $1.1.point) }
        filtered.estimatedPhotoCount = selected.reduce(0) { total, pass in
            if pass.isPointCapture { return total + 1 }
            guard let interval = pass.start.captureIntervalMeters else { return total }
            let length = zip(pass.waypoints, pass.waypoints.dropFirst()).reduce(0) { $0 + SurveyCaptureSchedule.distance($1.0.point, $1.1.point) }
            return total + max(2, Int(ceil(length / interval)) + 1)
        }
        filtered.estimatedFlightSeconds = SurveyPlanner.estimateRouteSeconds(waypoints, constraints: constraints)
        try filtered.validate()
        return filtered
    }
}
