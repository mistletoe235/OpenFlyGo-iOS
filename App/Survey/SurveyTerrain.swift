import CryptoKit
import Foundation

enum SurfaceLayerRole: String, Codable { case terrainElevation, buildingFootprint, buildingHeightAboveGround, absoluteSurfaceElevation }
enum SurfaceUseLevel: String, Codable { case visualizationOnly, previewAndSimulation, realFlight }

struct GlobalSurfaceDataSource: Codable, Equatable {
    var id: String
    var displayName: String
    var role: SurfaceLayerRole
    var nominalResolutionMeters: Double?
    var globalCoverage: Bool
    var license: String
    var useLevel: SurfaceUseLevel
    var notes: String
}

enum GlobalSurfaceDataCatalog {
    static let mapzenTerrain = GlobalSurfaceDataSource(
        id: "mapzen-aws-terrain-tiles", displayName: "Mapzen Terrain Tiles on AWS Open Data",
        role: .terrainElevation, nominalResolutionMeters: 30, globalCoverage: true,
        license: "Mixed open sources; attribution required", useLevel: .previewAndSimulation,
        notes: "No-auth global bare-earth preview; China is primarily SRTM-scale terrain.")
    static let copernicusDEM = GlobalSurfaceDataSource(
        id: "copernicus-dem-glo-30", displayName: "Copernicus DEM GLO-30",
        role: .terrainElevation, nominalResolutionMeters: 30, globalCoverage: true,
        license: "Copernicus DEM licence", useLevel: .previewAndSimulation,
        notes: "Global fallback; too coarse and dated for building clearance.")
    static let overtureBuildings = GlobalSurfaceDataSource(
        id: "overture-buildings", displayName: "Overture Buildings", role: .buildingFootprint,
        nominalResolutionMeters: nil, globalCoverage: true, license: "ODbL 1.0",
        useLevel: .previewAndSimulation, notes: "Missing height remains unknown.")
    static let globalBuildingAtlas = GlobalSurfaceDataSource(
        id: "global-building-atlas-height", displayName: "GlobalBuildingAtlas Height",
        role: .buildingHeightAboveGround, nominalResolutionMeters: 3, globalCoverage: true,
        license: "CC BY-NC 4.0", useLevel: .previewAndSimulation,
        notes: "ML-estimated research/non-commercial building heights; not flight-certified.")
    static func userVerifiedDSM(resolutionMeters: Double) -> GlobalSurfaceDataSource {
        .init(id: "user-verified-dsm", displayName: "User verified surface DSM",
              role: .absoluteSurfaceElevation, nominalResolutionMeters: resolutionMeters,
              globalCoverage: false, license: "User supplied", useLevel: .realFlight,
              notes: "Recent, locally verified DSM aligned to the mission ROI.")
    }
}

struct TerrainRasterInfo: Codable, Equatable {
    var displayName: String
    var width: Int
    var height: Int
    var epsg: Int
    var noDataValue: Double?
    var pixelSizeX: Double
    var pixelSizeY: Double
    var minimumLatitude: Double
    var maximumLatitude: Double
    var minimumLongitude: Double
    var maximumLongitude: Double
}

protocol TerrainElevationSource {
    var info: TerrainRasterInfo { get }
    func elevationMeters(latitude: Double, longitude: Double) throws -> Double
}

struct CompositeSurfaceElevationSource: TerrainElevationSource {
    var terrain: any TerrainElevationSource
    var heightAboveGround: any TerrainElevationSource
    let info: TerrainRasterInfo

    init(terrain: any TerrainElevationSource, heightAboveGround: any TerrainElevationSource) throws {
        self.terrain = terrain; self.heightAboveGround = heightAboveGround
        let minimumLatitude = max(terrain.info.minimumLatitude, heightAboveGround.info.minimumLatitude)
        let maximumLatitude = min(terrain.info.maximumLatitude, heightAboveGround.info.maximumLatitude)
        let minimumLongitude = max(terrain.info.minimumLongitude, heightAboveGround.info.minimumLongitude)
        let maximumLongitude = min(terrain.info.maximumLongitude, heightAboveGround.info.maximumLongitude)
        guard minimumLatitude < maximumLatitude, minimumLongitude < maximumLongitude else {
            throw SurveyValidationError.invalid("地形与建筑高度图没有重叠覆盖范围")
        }
        info = .init(displayName: "\(terrain.info.displayName) + \(heightAboveGround.info.displayName)",
                     width: min(terrain.info.width, heightAboveGround.info.width),
                     height: min(terrain.info.height, heightAboveGround.info.height), epsg: 4326,
                     noDataValue: nil, pixelSizeX: max(terrain.info.pixelSizeX, heightAboveGround.info.pixelSizeX),
                     pixelSizeY: max(terrain.info.pixelSizeY, heightAboveGround.info.pixelSizeY),
                     minimumLatitude: minimumLatitude, maximumLatitude: maximumLatitude,
                     minimumLongitude: minimumLongitude, maximumLongitude: maximumLongitude)
    }

    func elevationMeters(latitude: Double, longitude: Double) throws -> Double {
        let height = try heightAboveGround.elevationMeters(latitude: latitude, longitude: longitude)
        guard height >= 0 else { throw SurveyValidationError.invalid("建筑相对高度不能为负数") }
        return try terrain.elevationMeters(latitude: latitude, longitude: longitude) + height
    }
}

struct SurveyTerrainSafetyReport: Equatable {
    var controlPointCount: Int
    var minimumTerrainElevationMeters: Double
    var maximumTerrainElevationMeters: Double
    var minimumWaypointAltitudeMeters: Double
    var maximumWaypointAltitudeMeters: Double
    var maximumRequiredVerticalSpeedMetersPerSecond: Double
}

struct SurveyTerrainPlanResult: Equatable { var mission: SurveyMission; var safety: SurveyTerrainSafetyReport }

enum SurveyTerrainPlanner {
    static let defaultSampleSpacingMeters = 3.0
    static let maximumTerrainControlPoints = 20_000
    static let aircraftClearanceRadiusMeters = 2.0

    private struct Control {
        var point: SurveyGeoPoint; var template: SurveyWaypoint
        var terrainElevation: Double; var flightAltitude: Double
    }

    static func apply(to mission: SurveyMission, terrain: any TerrainElevationSource,
                      takeoffPoint: SurveyGeoPoint, sourceSHA256: String,
                      takeoffReference: SurveyTerrainTakeoffReference? = nil,
                      sourceKind: SurveyTerrainSourceKind = .surfaceDSM,
                      bareEarthBaseSHA256: String? = nil,
                      sampleSpacingMeters: Double = defaultSampleSpacingMeters) throws -> SurveyTerrainPlanResult {
        guard mission.constraints.altitudeMode == .aboveTargetSurface else {
            throw SurveyValidationError.invalid("DSM 仿地要求高度模式为相对目标面")
        }
        guard sourceSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw SurveyValidationError.invalid("DSM SHA-256 无效")
        }
        guard (2...50).contains(sampleSpacingMeters) else {
            throw SurveyValidationError.invalid("DSM 采样间距必须在 2–50 m")
        }
        let takeoffTerrain = try terrain.elevationMeters(latitude: takeoffPoint.latitude, longitude: takeoffPoint.longitude)
        var elevations: [Double] = []
        func clearance(_ point: SurveyGeoPoint) throws -> Double {
            let latOffset = aircraftClearanceRadiusMeters / 111_132
            let lonOffset = aircraftClearanceRadiusMeters / (111_320 * cos(point.latitude * .pi / 180))
            let points = [point,
                .init(latitude: point.latitude + latOffset, longitude: point.longitude),
                .init(latitude: point.latitude - latOffset, longitude: point.longitude),
                .init(latitude: point.latitude, longitude: point.longitude + lonOffset),
                .init(latitude: point.latitude, longitude: point.longitude - lonOffset)]
            let values = try points.map { try terrain.elevationMeters(latitude: $0.latitude, longitude: $0.longitude) }
            elevations += values
            return values.max()!
        }
        let safeVertical = SurveyWaypointFollower.maxVerticalSpeedMetersPerSecond * 0.9
        let maximumSlope = safeVertical / mission.constraints.maximumSurveySpeedMetersPerSecond
        var passes: [[Control]] = try mission.surveyPasses().map { pass in
            let path = densify(pass.waypoints.map(\.point), spacing: sampleSpacingMeters)
            return try path.enumerated().map { index, point in
                let elevation = try clearance(point)
                var template = index == 0 ? pass.start : (index == path.count - 1 ? pass.end : pass.start)
                if index > 0, index < path.count - 1 {
                    template.kind = .transit; template.captureAction = .none; template.captureIntervalMeters = nil
                }
                return .init(point: point, template: template, terrainElevation: elevation,
                             flightAltitude: mission.constraints.altitudeMetersAgl + elevation - takeoffTerrain)
            }
        }
        guard passes.reduce(0, { $0 + $1.count }) <= maximumTerrainControlPoints else {
            throw SurveyValidationError.invalid("DSM 航线控制点超过 \(maximumTerrainControlPoints)；请缩小规划区或降低航带密度")
        }
        for passIndex in passes.indices {
            guard passes[passIndex].count > 1 else { continue }
            for index in 1..<passes[passIndex].count {
                let d = SurveyCaptureSchedule.distance(passes[passIndex][index - 1].point, passes[passIndex][index].point)
                passes[passIndex][index].flightAltitude = max(passes[passIndex][index].flightAltitude,
                    passes[passIndex][index - 1].flightAltitude - maximumSlope * d)
            }
            for index in stride(from: passes[passIndex].count - 2, through: 0, by: -1) {
                let d = SurveyCaptureSchedule.distance(passes[passIndex][index].point, passes[passIndex][index + 1].point)
                passes[passIndex][index].flightAltitude = max(passes[passIndex][index].flightAltitude,
                    passes[passIndex][index + 1].flightAltitude - maximumSlope * d)
            }
        }
        var generated: [SurveyWaypoint] = []
        var maximumVerticalSpeed = 0.0
        for controls in passes {
            for control in controls {
                guard (5...120).contains(control.flightAltitude) else {
                    throw SurveyValidationError.invalid(String(format: "DSM 航点相对高度 %.1f m 超出 5–120 m", control.flightAltitude))
                }
                var waypoint = control.template
                waypoint.point = control.point; waypoint.point.altitudeMeters = control.flightAltitude
                if let previous = generated.last, previous.passIndex == waypoint.passIndex {
                    let horizontal = SurveyCaptureSchedule.distance(previous.point, waypoint.point)
                    if horizontal > 0.1 {
                        maximumVerticalSpeed = max(maximumVerticalSpeed,
                            abs(waypoint.point.altitudeMeters - previous.point.altitudeMeters) / horizontal
                            * mission.constraints.maximumSurveySpeedMetersPerSecond)
                    }
                }
                generated.append(waypoint)
            }
        }
        var result = mission; result.waypoints = generated
        result.terrainPlan = .init(sourceName: terrain.info.displayName, sourceSHA256: sourceSHA256.lowercased(),
            epsg: terrain.info.epsg, targetAGLMeters: mission.constraints.altitudeMetersAgl,
            takeoffTerrainElevationMeters: takeoffTerrain, sampleSpacingMeters: sampleSpacingMeters,
            minimumTerrainElevationMeters: elevations.min()!, maximumTerrainElevationMeters: elevations.max()!,
            minimumWaypointAltitudeMeters: generated.map(\.point.altitudeMeters).min()!,
            maximumWaypointAltitudeMeters: generated.map(\.point.altitudeMeters).max()!,
            takeoffReference: takeoffReference,
            sourceKind: sourceKind,
            bareEarthBaseSHA256: bareEarthBaseSHA256)
        try result.validate()
        return .init(mission: result, safety: .init(controlPointCount: generated.count,
            minimumTerrainElevationMeters: elevations.min()!, maximumTerrainElevationMeters: elevations.max()!,
            minimumWaypointAltitudeMeters: result.terrainPlan!.minimumWaypointAltitudeMeters,
            maximumWaypointAltitudeMeters: result.terrainPlan!.maximumWaypointAltitudeMeters,
            maximumRequiredVerticalSpeedMetersPerSecond: maximumVerticalSpeed))
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func densify(_ points: [SurveyGeoPoint], spacing: Double) -> [SurveyGeoPoint] {
        var result = [points[0]]
        for (start, end) in zip(points, points.dropFirst()) {
            let pieces = max(1, Int(ceil(SurveyCaptureSchedule.distance(start, end) / spacing)))
            for index in 1...pieces {
                let ratio = Double(index) / Double(pieces)
                result.append(.init(latitude: start.latitude + (end.latitude - start.latitude) * ratio,
                                    longitude: start.longitude + (end.longitude - start.longitude) * ratio,
                                    altitudeMeters: start.altitudeMeters + (end.altitudeMeters - start.altitudeMeters) * ratio))
            }
        }
        return result
    }
}
