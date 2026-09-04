import Foundation

enum SurveyValidationError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        }
    }
}

struct SurveyGeoPoint: Codable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double = 0

    func validate() throws {
        guard latitude.isFinite, (-90.0...90.0).contains(latitude) else {
            throw SurveyValidationError.invalid("latitude must be in [-90, 90]")
        }
        guard longitude.isFinite, (-180.0...180.0).contains(longitude) else {
            throw SurveyValidationError.invalid("longitude must be in [-180, 180]")
        }
        guard altitudeMeters.isFinite else {
            throw SurveyValidationError.invalid("altitude must be finite")
        }
    }
}

enum ChinaMapCalibrationMode: String, CaseIterable, Identifiable {
    static let defaultsKey = "openfly.map.china-coordinate-calibration"

    case automatic
    case disabled

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "自动（中国大陆 GCJ‑02）"
        case .disabled: return "关闭（WGS‑84）"
        }
    }

    static var stored: ChinaMapCalibrationMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let mode = ChinaMapCalibrationMode(rawValue: raw) else { return .automatic }
        return mode
    }
}

/// Coordinate-system boundary shared with Android's Baidu-map implementation.
///
/// DJI telemetry, persisted missions, HIL and flight-control targets always stay
/// in WGS-84. Mainland-China map presentation uses GCJ-02, and map interaction is
/// converted back to WGS-84 before it can enter a mission.
enum ChinaMapCoordinateTransform {
    private static let semiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.00669342162296594323
    private static let mainlandChinaOutline: [(Double, Double)] = [
        (53.56, 122.34), (52.50, 120.00), (49.50, 116.70), (47.00, 116.50),
        (45.00, 114.00), (43.60, 112.00), (41.50, 110.50), (42.50, 107.50),
        (41.60, 104.50), (42.50, 101.50), (42.80, 96.50), (45.20, 95.00),
        (46.50, 90.00), (48.00, 89.00), (49.10, 87.80), (48.20, 82.00),
        (45.00, 82.30), (42.50, 80.20), (40.00, 74.00), (37.00, 74.50),
        (35.50, 78.00), (33.00, 79.00), (31.00, 80.00), (29.00, 82.00),
        (27.80, 88.10), (28.20, 92.50), (28.00, 97.30), (25.60, 98.20),
        (24.00, 97.60), (21.10, 101.10), (22.40, 103.40), (21.50, 107.00),
        (20.90, 108.10), (21.50, 108.80), (21.50, 110.00), (22.00, 113.50),
        (23.50, 117.50), (25.50, 120.50), (28.30, 121.80), (31.80, 122.20),
        (34.50, 120.50), (37.50, 122.70), (40.00, 122.00), (42.50, 124.50),
        (43.00, 129.00), (44.50, 131.50), (47.50, 134.80), (49.50, 130.50),
        (52.00, 126.50),
    ]
    private static let hainanOutline: [(Double, Double)] = [
        (20.18, 110.72), (19.20, 111.05), (18.15, 110.58),
        (18.05, 108.62), (19.15, 108.35), (20.15, 109.25),
    ]

    static func wgs84ToGCJ02(_ point: SurveyGeoPoint) -> SurveyGeoPoint {
        guard !outsideMainlandChina(latitude: point.latitude, longitude: point.longitude) else {
            return point
        }
        let offset = delta(latitude: point.latitude, longitude: point.longitude)
        return .init(latitude: point.latitude + offset.latitude,
                     longitude: point.longitude + offset.longitude,
                     altitudeMeters: point.altitudeMeters)
    }

    static func wgs84ToMap(_ point: SurveyGeoPoint,
                           mode: ChinaMapCalibrationMode = .stored) -> SurveyGeoPoint {
        mode == .automatic ? wgs84ToGCJ02(point) : point
    }

    static func gcj02ToWGS84(_ point: SurveyGeoPoint) -> SurveyGeoPoint {
        guard !outsideMainlandChina(latitude: point.latitude, longitude: point.longitude) else {
            return point
        }
        var estimate = point
        // Match Android: fixed-point refinement avoids the several-meter error
        // left by subtracting a single forward offset.
        for _ in 0..<6 {
            let projected = wgs84ToGCJ02(estimate)
            estimate.latitude -= projected.latitude - point.latitude
            estimate.longitude -= projected.longitude - point.longitude
        }
        return estimate
    }

    static func mapToWGS84(_ point: SurveyGeoPoint,
                           mode: ChinaMapCalibrationMode = .stored) -> SurveyGeoPoint {
        mode == .automatic ? gcj02ToWGS84(point) : point
    }

    static func outsideMainlandChina(latitude: Double, longitude: Double) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return true }
        return !inside(latitude: latitude, longitude: longitude, outline: mainlandChinaOutline)
            && !inside(latitude: latitude, longitude: longitude, outline: hainanOutline)
    }

    private static func inside(latitude: Double, longitude: Double,
                               outline: [(Double, Double)]) -> Bool {
        var result = false
        var previous = outline.count - 1
        for index in outline.indices {
            let a = outline[index]
            let b = outline[previous]
            if (a.0 > latitude) != (b.0 > latitude),
               longitude < (b.1 - a.1) * (latitude - a.0) / (b.0 - a.0) + a.1 {
                result.toggle()
            }
            previous = index
        }
        return result
    }

    private static func delta(latitude: Double, longitude: Double)
        -> (latitude: Double, longitude: Double) {
        var latitudeOffset = transformLatitude(x: longitude - 105, y: latitude - 35)
        var longitudeOffset = transformLongitude(x: longitude - 105, y: latitude - 35)
        let latitudeRadians = latitude * .pi / 180
        var magic = sin(latitudeRadians)
        magic = 1 - eccentricitySquared * magic * magic
        let root = sqrt(magic)
        latitudeOffset = latitudeOffset * 180
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * root) * .pi)
        longitudeOffset = longitudeOffset * 180
            / (semiMajorAxis / root * cos(latitudeRadians) * .pi)
        return (latitudeOffset, longitudeOffset)
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var value = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y
            + 0.2 * sqrt(abs(x))
        value += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        value += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        value += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return value
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var value = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y
            + 0.1 * sqrt(abs(x))
        value += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        value += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        value += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return value
    }
}

/// Projects DJI Simulator's local NED position onto the map. DJI MSDK V4 names
/// the east-west component `positionX` (east positive), the north-south
/// component `positionY` (north positive), and uses Z down. Simulator execution
/// cannot rely on `DJIFlightControllerState.aircraftLocation`: on some
/// consumer-aircraft sessions that field becomes invalid while the raw
/// SimulatorState continues to be authoritative.
enum SurveySimulatorMapProjection {
    static func point(from simulator: FlightSimulatorStatus) -> SurveyGeoPoint? {
        guard simulator.active, simulator.stateReceived,
              simulator.originLatitudeDegrees.isFinite,
              simulator.originLongitudeDegrees.isFinite,
              simulator.positionX.isFinite, simulator.positionY.isFinite,
              simulator.positionZ.isFinite,
              (-90.0...90.0).contains(simulator.originLatitudeDegrees),
              (-180.0...180.0).contains(simulator.originLongitudeDegrees),
              abs(simulator.originLatitudeDegrees) > 1e-9
                || abs(simulator.originLongitudeDegrees) > 1e-9 else { return nil }
        let latitude = simulator.originLatitudeDegrees + simulator.positionY / 111_132
        let longitudeScale = 111_320 * cos(latitude * .pi / 180)
        guard longitudeScale.isFinite, abs(longitudeScale) > 1 else { return nil }
        let longitude = simulator.originLongitudeDegrees + simulator.positionX / longitudeScale
        guard (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude) else {
            return nil
        }
        return .init(latitude: latitude, longitude: longitude,
                     altitudeMeters: max(0, -simulator.positionZ))
    }
}

struct SurveyCameraProfile: Codable, Equatable {
    var id: String
    var imageWidthPixels: Int
    var imageHeightPixels: Int
    var horizontalFieldOfViewDegrees: Double
    var verticalFieldOfViewDegrees: Double
    var minimumCaptureIntervalSeconds: Double = 1

    static let generic4By3 = SurveyCameraProfile(
        id: "generic-unverified-photo-4x3",
        imageWidthPixels: 4_000,
        imageHeightPixels: 3_000,
        horizontalFieldOfViewDegrees: 70,
        verticalFieldOfViewDegrees: 55,
        minimumCaptureIntervalSeconds: 2
    )

    /// Schema compatibility only. Live planning resolves the connected product.
    static let djiMini2 = SurveyCameraProfile(
        id: "dji-mini-2-photo-4x3",
        imageWidthPixels: 4_000,
        imageHeightPixels: 3_000,
        horizontalFieldOfViewDegrees: 73.7,
        verticalFieldOfViewDegrees: 53.1,
        minimumCaptureIntervalSeconds: 1.2
    )

    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SurveyValidationError.invalid("camera id must not be blank")
        }
        guard imageWidthPixels > 0, imageHeightPixels > 0 else {
            throw SurveyValidationError.invalid("image dimensions must be positive")
        }
        guard (1.0...179.0).contains(horizontalFieldOfViewDegrees),
              (1.0...179.0).contains(verticalFieldOfViewDegrees) else {
            throw SurveyValidationError.invalid("camera FOV must be in [1, 179]")
        }
        guard minimumCaptureIntervalSeconds.isFinite, minimumCaptureIntervalSeconds > 0 else {
            throw SurveyValidationError.invalid("minimum capture interval must be positive")
        }
    }
}

enum SurveyCollectionMode: String, Codable, CaseIterable {
    case ortho = "ORTHO"
    case crosshatchNadir = "CROSSHATCH_NADIR"
    case obliqueFiveDirection = "OBLIQUE_FIVE_DIRECTION"
}

enum SurveyAltitudeMode: String, Codable, CaseIterable {
    case aboveTargetSurface = "ABOVE_TARGET_SURFACE"
    case relativeToTakeoff = "RELATIVE_TO_TAKEOFF"
}

enum SurveyStartPointMode: String, Codable, CaseIterable {
    case autoNearest = "AUTO_NEAREST"
    case firstRouteStart = "FIRST_ROUTE_START"
    case routeCorner2 = "ROUTE_CORNER_2"
    case routeCorner3 = "ROUTE_CORNER_3"
    case routeCorner4 = "ROUTE_CORNER_4"
    case custom = "CUSTOM"
}

enum SurveyCompletionAction: String, Codable, CaseIterable {
    case returnToHome = "RETURN_TO_HOME"
    case hover = "HOVER"
    case returnToRouteStart = "RETURN_TO_ROUTE_START"
}

enum SurveyCaptureTriggerMode: String, Codable, CaseIterable {
    case distance = "DISTANCE"
    case time = "TIME"
}

enum SurveyTakeoffMode: String, Codable, CaseIterable {
    case manual = "MANUAL"
    case autoSimulatorOnly = "AUTO_SIMULATOR_ONLY"
}

enum SurveyObliqueHeadingMode: String, Codable, CaseIterable {
    case trackRoute = "TRACK_ROUTE"
    case fixedCaptureDirection = "FIXED_CAPTURE_DIRECTION"
}

struct SurveyConstraints: Codable, Equatable {
    var altitudeMetersAgl = 60.0
    var forwardOverlap = 0.80
    var sideOverlap = 0.70
    var speedMetersPerSecond = 3.0
    var obliqueSpeedMetersPerSecond = 3.0
    var gimbalPitchDegrees = -90.0
    var routeHeadingDegrees = 0.0
    var crosshatch = false
    var collectionMode: SurveyCollectionMode = .ortho
    var obliqueGimbalPitchDegrees = -45.0
    var boundaryMarginMeters = 0.0
    var altitudeMode: SurveyAltitudeMode = .aboveTargetSurface
    var targetSurfaceToTakeoffMeters = 0.0
    var safeTakeoffAltitudeMeters = 30.0
    var takeoffSpeedMetersPerSecond = 3.0
    var descentSpeedMetersPerSecond = 2.0
    var takeoffMode: SurveyTakeoffMode = .manual
    var startPointMode: SurveyStartPointMode = .autoNearest
    var completionAction: SurveyCompletionAction = .returnToHome
    var captureTriggerMode: SurveyCaptureTriggerMode = .distance
    var timedCaptureIntervalSeconds = 1.0
    var obliqueForwardOverlap = 0.70
    var obliqueSideOverlap = 0.60
    var obliqueHeadingMode: SurveyObliqueHeadingMode = .trackRoute
    var enabledCaptureViews: Set<SurveyCaptureView> = SurveyCaptureView.standardSurveyViews

    var effectiveFlightAltitudeMeters: Double {
        altitudeMode == .aboveTargetSurface
            ? altitudeMetersAgl + targetSurfaceToTakeoffMeters
            : altitudeMetersAgl
    }

    func speed(for captureView: SurveyCaptureView) -> Double {
        captureView == .nadir ? speedMetersPerSecond : obliqueSpeedMetersPerSecond
    }

    var maximumSurveySpeedMetersPerSecond: Double {
        collectionMode == .obliqueFiveDirection
            ? enabledCaptureViews.map(speed(for:)).max() ?? speedMetersPerSecond
            : speedMetersPerSecond
    }

    func validate() throws {
        guard altitudeMetersAgl.isFinite, altitudeMetersAgl > 0 else {
            throw SurveyValidationError.invalid("altitude must be positive")
        }
        guard (0...0.95).contains(forwardOverlap), (0...0.95).contains(sideOverlap),
              (0...0.95).contains(obliqueForwardOverlap), (0...0.95).contains(obliqueSideOverlap) else {
            throw SurveyValidationError.invalid("overlap must be in [0, 0.95]")
        }
        guard speedMetersPerSecond.isFinite, speedMetersPerSecond > 0,
              obliqueSpeedMetersPerSecond.isFinite, obliqueSpeedMetersPerSecond > 0,
              takeoffSpeedMetersPerSecond.isFinite, takeoffSpeedMetersPerSecond > 0,
              descentSpeedMetersPerSecond.isFinite, descentSpeedMetersPerSecond > 0 else {
            throw SurveyValidationError.invalid("survey speed must be positive")
        }
        guard (-90...30).contains(gimbalPitchDegrees),
              (-90...30).contains(obliqueGimbalPitchDegrees) else {
            throw SurveyValidationError.invalid("gimbal pitch is outside the supported range")
        }
        guard routeHeadingDegrees.isFinite, boundaryMarginMeters.isFinite,
              boundaryMarginMeters >= 0, targetSurfaceToTakeoffMeters.isFinite else {
            throw SurveyValidationError.invalid("survey geometry parameters are invalid")
        }
        guard safeTakeoffAltitudeMeters.isFinite, safeTakeoffAltitudeMeters > 0,
              timedCaptureIntervalSeconds.isFinite, timedCaptureIntervalSeconds > 0,
              effectiveFlightAltitudeMeters > 0 else {
            throw SurveyValidationError.invalid("survey altitude or capture interval is invalid")
        }
        if collectionMode == .obliqueFiveDirection, enabledCaptureViews.isEmpty {
            throw SurveyValidationError.invalid("an oblique mission must enable at least one capture view")
        }
    }
}

enum SurveyWaypointKind: String, Codable {
    case transit = "TRANSIT", passStart = "PASS_START", passEnd = "PASS_END"
    case capturePoint = "CAPTURE_POINT"
}
enum SurveyCaptureAction: String, Codable {
    case none = "NONE", startDistanceInterval = "START_DISTANCE_INTERVAL"
    case stopDistanceInterval = "STOP_DISTANCE_INTERVAL", captureOnReach = "CAPTURE_ON_REACH"
}
enum SurveyCaptureView: String, Codable, CaseIterable {
    case nadir = "NADIR", forwardOblique = "FORWARD_OBLIQUE"
    case backwardOblique = "BACKWARD_OBLIQUE", leftOblique = "LEFT_OBLIQUE"
    case rightOblique = "RIGHT_OBLIQUE", localOblique = "LOCAL_OBLIQUE"

    static let standardSurveyViews: Set<SurveyCaptureView> = [
        .nadir, .forwardOblique, .backwardOblique, .leftOblique, .rightOblique,
    ]
}

struct SurveyWaypoint: Codable, Equatable {
    var point: SurveyGeoPoint
    var headingDegrees: Double
    var gimbalPitchDegrees: Double
    var kind: SurveyWaypointKind
    var captureAction: SurveyCaptureAction
    var captureIntervalMeters: Double?
    var passIndex: Int
    var captureView: SurveyCaptureView = .nadir

    func validate() throws {
        try point.validate()
        guard headingDegrees.isFinite, gimbalPitchDegrees.isFinite, passIndex >= 0 else {
            throw SurveyValidationError.invalid("survey waypoint contains invalid values")
        }
        if captureAction == .startDistanceInterval {
            guard let captureIntervalMeters, captureIntervalMeters.isFinite, captureIntervalMeters > 0 else {
                throw SurveyValidationError.invalid("capture interval is required at pass start")
            }
        }
    }
}

struct SurveyPassWaypoints: Equatable {
    var firstWaypointIndex: Int
    var lastWaypointIndex: Int
    var waypoints: [SurveyWaypoint]

    var start: SurveyWaypoint { waypoints[0] }
    var end: SurveyWaypoint { waypoints[waypoints.count - 1] }
    var isPointCapture: Bool {
        waypoints.count == 1 && start.kind == .capturePoint && start.captureAction == .captureOnReach
    }
    var isTransitOnly: Bool {
        waypoints.allSatisfy { $0.kind == .transit && $0.captureAction == .none }
    }
}

struct ActiveMappingTarget: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var absoluteAltitudeMeters: Double
}

struct ActiveMappingRegionMetadata: Codable, Equatable {
    var regionID: String
    var priority: Int
    var kind: String
    var riskScore: Double
    var reasons: [String] = []
    var targetWGS84: ActiveMappingTarget? = nil
    var passIndices: [Int] = []
    var suggestedSurveyPhotos = 0
}

struct ActiveMappingPassMetadata: Codable, Equatable {
    var passIndex: Int
    var regionID: String
    var role: String
    var captureRole: String
    var source: String
    var requiredForReconstructionBridge: Bool
}

struct ActiveMappingMetadata: Codable, Equatable {
    var schemaVersion = 1
    var selectionMethod: String
    var groundTruthUsed: Bool
    var gsUsedForSelection: Bool
    var ordinaryGPSUsed: Bool
    var sourceCaptureCount: Int
    var surveyCaptureCount: Int
    var bridgeCaptureCount: Int
    var sourceEstimatedRouteDistanceMeters: Double
    var regions: [ActiveMappingRegionMetadata] = []
    var passes: [ActiveMappingPassMetadata] = []

    func validate() throws {
        guard schemaVersion >= 1, !selectionMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceCaptureCount >= 0, surveyCaptureCount >= 0, bridgeCaptureCount >= 0,
              sourceEstimatedRouteDistanceMeters.isFinite,
              sourceEstimatedRouteDistanceMeters >= 0 else {
            throw SurveyValidationError.invalid("active mapping metadata is invalid")
        }
    }
}

enum SurveyTerrainSourceKind: String, Codable {
    case surfaceDSM = "SURFACE_DSM"
    case bareEarth = "BARE_EARTH"
}

enum SurveyTerrainTakeoffReferenceSource: String, Codable {
    case homeLocation = "HOME_LOCATION"
    case aircraftLocation = "AIRCRAFT_LOCATION"
}

struct SurveyTerrainTakeoffReference: Codable, Equatable {
    var point: SurveyGeoPoint
    var source: SurveyTerrainTakeoffReferenceSource
    var capturedAtEpochMillis: Int64
}

struct SurveyTerrainPlan: Codable, Equatable {
    var sourceName: String
    var sourceSHA256: String
    var epsg: Int
    var targetAGLMeters: Double
    var takeoffTerrainElevationMeters: Double
    var sampleSpacingMeters: Double
    var minimumTerrainElevationMeters: Double
    var maximumTerrainElevationMeters: Double
    var minimumWaypointAltitudeMeters: Double
    var maximumWaypointAltitudeMeters: Double
    var realFlightVerified = false
    var takeoffReference: SurveyTerrainTakeoffReference? = nil
    var sourceKind: SurveyTerrainSourceKind = .surfaceDSM
    var bareEarthBaseSHA256: String? = nil
}

struct SurveyMission: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var createdAtEpochMillis = Int64(Date().timeIntervalSince1970 * 1_000)
    var coordinateFrame = "WGS84"
    var cameraProfile: SurveyCameraProfile
    var constraints: SurveyConstraints
    var roi: [SurveyGeoPoint]
    var waypoints: [SurveyWaypoint]
    var estimatedPathMeters: Double
    var estimatedPhotoCount: Int
    var estimatedFlightSeconds: Double
    var terrainPlan: SurveyTerrainPlan? = nil
    var activeMapping: ActiveMappingMetadata? = nil

    func surveyPasses() throws -> [SurveyPassWaypoints] {
        var result: [SurveyPassWaypoints] = []
        var first = 0
        while first < waypoints.count {
            let passIndex = waypoints[first].passIndex
            var last = first
            while last + 1 < waypoints.count, waypoints[last + 1].passIndex == passIndex { last += 1 }
            let group = Array(waypoints[first...last])
            result.append(.init(firstWaypointIndex: first, lastWaypointIndex: last, waypoints: group))
            first = last + 1
        }
        guard Set(result.map(\.start.passIndex)).count == result.count else {
            throw SurveyValidationError.invalid("survey pass indices must be contiguous groups")
        }
        return result
    }

    func validate() throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SurveyValidationError.invalid("mission identity must not be blank")
        }
        try cameraProfile.validate()
        try constraints.validate()
        guard roi.count >= 3 else { throw SurveyValidationError.invalid("mission ROI requires at least three points") }
        try roi.forEach { try $0.validate() }
        guard estimatedPathMeters.isFinite, estimatedPathMeters >= 0,
              estimatedPhotoCount >= 0, estimatedFlightSeconds.isFinite, estimatedFlightSeconds >= 0 else {
            throw SurveyValidationError.invalid("mission estimates are invalid")
        }
        guard !waypoints.isEmpty else { throw SurveyValidationError.invalid("mission requires waypoints") }
        try waypoints.forEach { try $0.validate() }
        try activeMapping?.validate()
        for (index, pass) in try surveyPasses().enumerated() {
            let start = pass.start, end = pass.end
            if pass.isPointCapture {
                guard start.captureIntervalMeters == nil else {
                    throw SurveyValidationError.invalid("point capture \(index) must not define a capture interval")
                }
                continue
            }
            if pass.isTransitOnly {
                guard pass.waypoints.allSatisfy({ $0.captureIntervalMeters == nil }) else {
                    throw SurveyValidationError.invalid("transit unit \(index) must not define a capture interval")
                }
                continue
            }
            guard pass.waypoints.count >= 2 else {
                throw SurveyValidationError.invalid("survey pass \(index) is incomplete")
            }
            guard start.kind == .passStart, start.captureAction == .startDistanceInterval,
                  end.kind == .passEnd, end.captureAction == .stopDistanceInterval,
                  start.passIndex == end.passIndex, start.captureView == end.captureView else {
                throw SurveyValidationError.invalid("survey pass \(index) is incomplete")
            }
            let interior = pass.waypoints.dropFirst().dropLast()
            guard interior.allSatisfy({ waypoint in
                waypoint.kind == .transit && waypoint.captureAction == .none
                    && waypoint.passIndex == start.passIndex && waypoint.captureView == start.captureView
            }) else {
                throw SurveyValidationError.invalid("survey pass \(index) contains an invalid terrain control point")
            }
        }
    }
}
