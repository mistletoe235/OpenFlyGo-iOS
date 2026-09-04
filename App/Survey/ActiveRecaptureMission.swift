import Foundation

struct ActiveRecaptureMissionGroup: Equatable, Identifiable {
    var id: String { groupID }
    var groupID: String
    var order: Int
    var label: String
    var regionIDs: Set<String>
    var suggestedSurveyPhotos: Int
    var targetWGS84: ActiveMappingTarget?
}

enum ActiveRecaptureMissionGroupCatalog {
    private struct Definition {
        var groupID: String
        var order: Int
        var label: String
        var kinds: Set<String>
    }

    private static let v30Definitions = [
        Definition(groupID: "V30_HIGH_RISE", order: 1, label: "西侧高楼五向", kinds: ["HIGH_RISE_FIVE_DIRECTION"]),
        Definition(groupID: "V30_LARGE", order: 2, label: "东侧大区域五向", kinds: ["LARGE_FIVE_DIRECTION"]),
        Definition(groupID: "V30_SMALL_CROSS", order: 3, label: "小型交叉补拍", kinds: ["SMALL_CROSS"]),
        Definition(groupID: "V30_RISK_SCAN", order: 4, label: "零散风险补拍", kinds: ["V26_RISK_SCAN"]),
    ]

    static func groups(for mission: SurveyMission) -> [ActiveRecaptureMissionGroup] {
        let regions = (mission.activeMapping?.regions ?? []).sorted { $0.priority < $1.priority }
        guard !regions.isEmpty else { return [] }
        let knownKinds = Set(v30Definitions.flatMap(\.kinds))
        if regions.allSatisfy({ knownKinds.contains($0.kind) }) {
            return v30Definitions.compactMap { definition in
                let matching = regions.filter { definition.kinds.contains($0.kind) }
                guard !matching.isEmpty else { return nil }
                return .init(groupID: definition.groupID, order: definition.order,
                             label: definition.label, regionIDs: Set(matching.map(\.regionID)),
                             suggestedSurveyPhotos: matching.map(\.suggestedSurveyPhotos).reduce(0, +),
                             targetWGS84: averageTarget(matching.compactMap(\.targetWGS84)))
            }
        }
        return regions.enumerated().map { index, region in
            .init(groupID: region.regionID, order: index + 1,
                  label: region.kind.replacingOccurrences(of: "_", with: " "),
                  regionIDs: [region.regionID], suggestedSurveyPhotos: region.suggestedSurveyPhotos,
                  targetWGS84: region.targetWGS84)
        }
    }

    static func selectedGroupIDs(source: SurveyMission, selected: SurveyMission) -> Set<String> {
        let selectedRegions = Set(selected.activeMapping?.regions.map(\.regionID) ?? [])
        return Set(groups(for: source).filter { $0.regionIDs.isSubset(of: selectedRegions) }.map(\.groupID))
    }

    private static func averageTarget(_ targets: [ActiveMappingTarget]) -> ActiveMappingTarget? {
        guard !targets.isEmpty else { return nil }
        let count = Double(targets.count)
        let latitude = targets.reduce(0.0) { $0 + $1.latitude } / count
        let longitude = targets.reduce(0.0) { $0 + $1.longitude } / count
        let altitude = targets.reduce(0.0) { $0 + $1.absoluteAltitudeMeters } / count
        return .init(latitude: latitude, longitude: longitude, absoluteAltitudeMeters: altitude)
    }
}

enum ActiveRecaptureMissionRegionFilter {
    static func selectGroups(_ mission: SurveyMission, selectedGroupIDs: Set<String>) throws -> SurveyMission {
        let groups = ActiveRecaptureMissionGroupCatalog.groups(for: mission)
        let available = Set(groups.map(\.groupID))
        guard !selectedGroupIDs.isEmpty else { throw SurveyValidationError.invalid("至少选择一个主动补拍分组") }
        guard selectedGroupIDs.isSubset(of: available) else {
            throw SurveyValidationError.invalid("主动补拍选择包含未知分组")
        }
        if selectedGroupIDs == available { return mission }
        let selectedGroups = groups.filter { selectedGroupIDs.contains($0.groupID) }
        let regions = Set(selectedGroups.flatMap(\.regionIDs))
        var result = try select(mission, selectedRegionIDs: regions)
        result.name = "\(mission.name) · \(selectedGroups.count)/\(groups.count)组"
        return result
    }

    static func select(_ mission: SurveyMission, selectedRegionIDs: Set<String>) throws -> SurveyMission {
        guard let metadata = mission.activeMapping else {
            throw SurveyValidationError.invalid("只有主动补拍任务可以按区域筛选")
        }
        let available = Set(metadata.regions.map(\.regionID))
        guard !selectedRegionIDs.isEmpty else { throw SurveyValidationError.invalid("至少选择一个主动补拍区域") }
        guard selectedRegionIDs.isSubset(of: available) else {
            throw SurveyValidationError.invalid("主动补拍选择包含未知区域")
        }
        if selectedRegionIDs == available { return mission }

        let sourcePasses = try mission.surveyPasses()
        let metadataByPass = Dictionary(uniqueKeysWithValues: metadata.passes.map { ($0.passIndex, $0) })
        let selectedPositions = try sourcePasses.indices.filter { position in
            guard let item = metadataByPass[sourcePasses[position].start.passIndex] else {
                throw SurveyValidationError.invalid("主动补拍航段元数据缺失")
            }
            return selectedRegionIDs.contains(item.regionID) && item.captureRole != "NONE"
        }
        guard let first = selectedPositions.first, let last = selectedPositions.last else {
            throw SurveyValidationError.invalid("所选区域没有可执行航段")
        }

        var waypoints: [SurveyWaypoint] = []
        var passMetadata: [ActiveMappingPassMetadata] = []
        var sourceToOutput: [Int: Int] = [:]
        var nextPass = 0
        for position in first...last {
            let sourcePass = sourcePasses[position]
            guard let item = metadataByPass[sourcePass.start.passIndex] else {
                throw SurveyValidationError.invalid("主动补拍航段元数据缺失")
            }
            let selected = selectedRegionIDs.contains(item.regionID) && item.captureRole != "NONE"
            let outputPass = nextPass
            nextPass += 1
            if selected {
                waypoints += sourcePass.waypoints.map { value in
                    var result = value; result.passIndex = outputPass; return result
                }
                var output = item; output.passIndex = outputPass; passMetadata.append(output)
                sourceToOutput[sourcePass.start.passIndex] = outputPass
            } else {
                waypoints += sourcePass.waypoints.map { value in
                    var result = value
                    result.kind = .transit; result.captureAction = .none
                    result.captureIntervalMeters = nil; result.passIndex = outputPass
                    return result
                }
                var output = item
                output.passIndex = outputPass; output.regionID = "SELECTION_TRANSIT"
                output.role = "SELECTION_TRANSIT"; output.captureRole = "NONE"
                output.requiredForReconstructionBridge = false
                passMetadata.append(output)
            }
        }

        let regions = metadata.regions.filter { selectedRegionIDs.contains($0.regionID) }.map { source in
            var result = source
            result.passIndices = source.passIndices.compactMap { sourceToOutput[$0] }
            return result
        }
        let photoCount = try captureCount(waypoints)
        let surveyPhotos = min(photoCount, regions.map(\.suggestedSurveyPhotos).reduce(0, +))
        let path = zip(waypoints, waypoints.dropFirst()).reduce(0) {
            $0 + SurveyCaptureSchedule.distance($1.0.point, $1.1.point)
        }
        let selectionKey = regions.sorted { $0.priority < $1.priority }.map(\.regionID).joined(separator: ",")
        var active = metadata
        active.selectionMethod += ":ios_region_filter"
        active.sourceCaptureCount = photoCount
        active.surveyCaptureCount = surveyPhotos
        active.bridgeCaptureCount = photoCount - surveyPhotos
        active.sourceEstimatedRouteDistanceMeters = path
        active.regions = regions
        active.passes = passMetadata
        var result = mission
        result.id = "\(mission.id)|\(selectionKey)"
        result.name = "\(mission.name) · \(regions.count)/\(metadata.regions.count)组"
        result.roi = boundingROI(waypoints.map(\.point))
        result.waypoints = waypoints
        result.estimatedPathMeters = path
        result.estimatedPhotoCount = photoCount
        result.estimatedFlightSeconds = SurveyPlanner.estimateRouteSeconds(waypoints, constraints: mission.constraints)
        result.activeMapping = active
        _ = try ActiveRecaptureMissionValidator.validate(result)
        return result
    }

    private static func captureCount(_ waypoints: [SurveyWaypoint]) throws -> Int {
        var mission = SurveyMission(name: "count", cameraProfile: .generic4By3,
                                    constraints: .init(), roi: boundingROI(waypoints.map(\.point)),
                                    waypoints: waypoints, estimatedPathMeters: 0,
                                    estimatedPhotoCount: 0, estimatedFlightSeconds: 0)
        let passes = try mission.surveyPasses()
        let count = passes.reduce(0) { total, pass in
            if pass.isPointCapture { return total + 1 }
            guard let interval = pass.start.captureIntervalMeters else { return total }
            let distance = zip(pass.waypoints, pass.waypoints.dropFirst()).reduce(0) {
                $0 + SurveyCaptureSchedule.distance($1.0.point, $1.1.point)
            }
            return total + max(2, Int(ceil(distance / interval)) + 1)
        }
        mission.estimatedPhotoCount = count
        return count
    }

    private static func boundingROI(_ points: [SurveyGeoPoint]) -> [SurveyGeoPoint] {
        let latitude = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let latPadding = 5 / 111_132.0
        let lonPadding = 5 / max(1, 111_320 * cos(latitude * .pi / 180))
        let minLat = points.map(\.latitude).min()! - latPadding
        let maxLat = points.map(\.latitude).max()! + latPadding
        let minLon = points.map(\.longitude).min()! - lonPadding
        let maxLon = points.map(\.longitude).max()! + lonPadding
        let altitude = points.map(\.altitudeMeters).min()!
        return [.init(latitude: minLat, longitude: minLon, altitudeMeters: altitude),
                .init(latitude: minLat, longitude: maxLon, altitudeMeters: altitude),
                .init(latitude: maxLat, longitude: maxLon, altitudeMeters: altitude),
                .init(latitude: maxLat, longitude: minLon, altitudeMeters: altitude)]
    }
}

struct ActiveRecaptureValidationReport: Equatable {
    var captureCount: Int
    var pointCaptureCount: Int
    var continuousPassCount: Int
    var minimumAltitudeMeters: Double
    var maximumAltitudeMeters: Double
    var maximumAdjacentDistanceMeters: Double
    var maximumYawStepDegrees: Double
    var maximumGimbalPitchStepDegrees: Double
}

enum ActiveRecaptureMissionValidator {
    static let minimumAltitudeMeters = 5.0
    static let maximumAltitudeMeters = 120.0
    static let maximumAdjacentDistanceMeters = 25.0
    static let maximumYawStepDegrees = 45.0
    static let maximumGimbalPitchStepDegrees = 15.0
    private static let obsoleteSelectionMethod = "existing seven-region micro-sequences + Android SurveyPlanner R8/R9 five-direction scan + established automatic bridge rule"

    static func validate(_ mission: SurveyMission) throws -> ActiveRecaptureValidationReport {
        guard let metadata = mission.activeMapping else {
            throw SurveyValidationError.invalid("主动补拍任务缺少 active_mapping 元数据")
        }
        guard metadata.selectionMethod != obsoleteSelectionMethod else {
            throw SurveyValidationError.invalid("已明确禁止导入和执行过期的 two_buildings R8/R9 研究任务")
        }
        let passes = try mission.surveyPasses()
        let schedule = try SurveyCaptureSchedule.build(mission)
        guard schedule.count == metadata.sourceCaptureCount,
              metadata.surveyCaptureCount + metadata.bridgeCaptureCount == metadata.sourceCaptureCount,
              metadata.passes.count == passes.count,
              metadata.passes.map(\.passIndex) == passes.map(\.start.passIndex) else {
            throw SurveyValidationError.invalid("主动补拍任务的拍摄计数或航段元数据不一致")
        }
        let passIndices = Set(passes.map(\.start.passIndex))
        guard metadata.regions.flatMap(\.passIndices).allSatisfy(passIndices.contains) else {
            throw SurveyValidationError.invalid("主动补拍区域引用了未知航段")
        }
        let altitudes = mission.waypoints.map(\.point.altitudeMeters)
        guard altitudes.allSatisfy({ minimumAltitudeMeters...maximumAltitudeMeters ~= $0 }) else {
            throw SurveyValidationError.invalid("主动补拍航点高度超出 5–120 m")
        }
        let pairs = Array(zip(mission.waypoints, mission.waypoints.dropFirst()))
        let maxDistance = pairs.map { SurveyCaptureSchedule.distance($0.0.point, $0.1.point) }.max() ?? 0
        let maxYaw = pairs.map { angleDifference($0.0.headingDegrees, $0.1.headingDegrees) }.max() ?? 0
        let maxPitch = pairs.map { abs($0.0.gimbalPitchDegrees - $0.1.gimbalPitchDegrees) }.max() ?? 0
        guard maxDistance <= maximumAdjacentDistanceMeters + 1e-6,
              maxYaw <= maximumYawStepDegrees + 1e-6,
              maxPitch <= maximumGimbalPitchStepDegrees + 1e-6 else {
            throw SurveyValidationError.invalid("主动补拍相邻航点距离、偏航或云台步长超限")
        }
        let highRise = Set(metadata.passes.filter { $0.regionID == "R8_R9" }.map(\.passIndex))
        if !highRise.isEmpty {
            let views = Set(passes.filter { highRise.contains($0.start.passIndex) }.map(\.start.captureView))
            guard SurveyCaptureView.standardSurveyViews.isSubset(of: views) else {
                throw SurveyValidationError.invalid("R8_R9 必须包含正射和四个倾斜方向")
            }
        }
        let pointCaptures = passes.filter(\.isPointCapture)
        guard pointCaptures.allSatisfy({ $0.start.captureView == .localOblique }) else {
            throw SurveyValidationError.invalid("精确主动补拍点必须使用 LOCAL_OBLIQUE")
        }
        return .init(captureCount: schedule.count, pointCaptureCount: pointCaptures.count,
                     continuousPassCount: passes.count - pointCaptures.count,
                     minimumAltitudeMeters: altitudes.min()!, maximumAltitudeMeters: altitudes.max()!,
                     maximumAdjacentDistanceMeters: maxDistance, maximumYawStepDegrees: maxYaw,
                     maximumGimbalPitchStepDegrees: maxPitch)
    }

    private static func angleDifference(_ a: Double, _ b: Double) -> Double {
        abs((b - a + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}
