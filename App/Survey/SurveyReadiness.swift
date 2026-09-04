import Foundation

struct SurveyRealFlightEvidence: Equatable {
    var simulatorRegressionPassed: Bool
    var failsafeRegressionPassed: Bool
    var fruBenchDirectionVerified: Bool
    var cameraCalibrated: Bool
    var operatingAreaReviewed: Bool
}

struct SurveyRealFlightTelemetry: Equatable {
    var connected: Bool
    var flightStateFresh: Bool
    var flying: Bool
    var simulatorActive: Bool
    var batteryPercent: Int
    var rcBatteryPercent: Int
    var rcSignalPercent: Int
    var satelliteCount: Int
    var gpsSignalUsable: Bool
    var homeLocationValid: Bool
    var latitude: Double
    var longitude: Double
    var goHomeHeightMeters: Int
    var maxFlightHeightMeters: Int
    var maxFlightRadiusMeters: Int
    var maxFlightRadiusEnabled: Bool
}

enum SurveyRealFlightBlock: String, Codable, Hashable {
    case missionRequired = "MISSION_REQUIRED"
    case aircraftDisconnected = "AIRCRAFT_DISCONNECTED"
    case telemetryStale = "TELEMETRY_STALE"
    case aircraftMustBeOnGround = "AIRCRAFT_MUST_BE_ON_GROUND"
    case simulatorMustBeOff = "SIMULATOR_MUST_BE_OFF"
    case batteryBelow30Percent = "BATTERY_BELOW_30_PERCENT"
    case rcBatteryBelow30Percent = "RC_BATTERY_BELOW_30_PERCENT"
    case rcSignalWeak = "RC_SIGNAL_WEAK"
    case gpsBelow12Satellites = "GPS_BELOW_12_SATELLITES"
    case gpsSignalWeak = "GPS_SIGNAL_WEAK"
    case homeLocationRequired = "HOME_LOCATION_REQUIRED"
    case goHomeHeightNotConfigured = "GO_HOME_HEIGHT_NOT_CONFIGURED"
    case goHomeHeightBelowMission = "GO_HOME_HEIGHT_BELOW_MISSION"
    case maxFlightHeightTooLow = "MAX_FLIGHT_HEIGHT_TOO_LOW"
    case maxFlightRadiusRequired = "MAX_FLIGHT_RADIUS_REQUIRED"
    case maxFlightRadiusTooSmall = "MAX_FLIGHT_RADIUS_TOO_SMALL"
    case simulatorRegressionRequired = "SIMULATOR_REGRESSION_REQUIRED"
    case failsafeRegressionRequired = "FAILSAFE_REGRESSION_REQUIRED"
    case fruBenchVerificationRequired = "FRU_BENCH_VERIFICATION_REQUIRED"
    case cameraCalibrationRequired = "CAMERA_CALIBRATION_REQUIRED"
    case operatingAreaReviewRequired = "OPERATING_AREA_REVIEW_REQUIRED"
}

struct SurveyRealFlightReadinessReport: Equatable {
    var readyForReview: Bool
    var blocks: Set<SurveyRealFlightBlock>
}

/// Audit report only. A successful report never authorizes or unlocks real flight.
enum SurveyRealFlightReadiness {
    static let minimumAircraftBatteryPercent = 30
    static let minimumRCBatteryPercent = 30
    static let minimumRCSignalPercent = 40
    static let minimumSatelliteCount = 12

    static func evaluate(mission: SurveyMission?, telemetry: SurveyRealFlightTelemetry,
                         evidence: SurveyRealFlightEvidence) -> SurveyRealFlightReadinessReport {
        var blocks = Set<SurveyRealFlightBlock>()
        if mission == nil { blocks.insert(.missionRequired) }
        if !telemetry.connected { blocks.insert(.aircraftDisconnected) }
        if !telemetry.flightStateFresh { blocks.insert(.telemetryStale) }
        if telemetry.flying { blocks.insert(.aircraftMustBeOnGround) }
        if telemetry.simulatorActive { blocks.insert(.simulatorMustBeOff) }
        if telemetry.batteryPercent < minimumAircraftBatteryPercent { blocks.insert(.batteryBelow30Percent) }
        if telemetry.rcBatteryPercent < minimumRCBatteryPercent { blocks.insert(.rcBatteryBelow30Percent) }
        if telemetry.rcSignalPercent < minimumRCSignalPercent { blocks.insert(.rcSignalWeak) }
        if telemetry.satelliteCount < minimumSatelliteCount { blocks.insert(.gpsBelow12Satellites) }
        if !telemetry.gpsSignalUsable { blocks.insert(.gpsSignalWeak) }
        if !telemetry.homeLocationValid { blocks.insert(.homeLocationRequired) }
        if let mission {
            let maximumAltitude = mission.waypoints.map(\.point.altitudeMeters).max()
                ?? mission.constraints.safeTakeoffAltitudeMeters
            if telemetry.goHomeHeightMeters <= 0 {
                blocks.insert(.goHomeHeightNotConfigured)
            } else if Double(telemetry.goHomeHeightMeters) + 0.5 < maximumAltitude {
                blocks.insert(.goHomeHeightBelowMission)
            }
            if telemetry.maxFlightHeightMeters <= 0
                || Double(telemetry.maxFlightHeightMeters) + 0.5 < maximumAltitude {
                blocks.insert(.maxFlightHeightTooLow)
            }
            if telemetry.maxFlightRadiusEnabled {
                if telemetry.maxFlightRadiusMeters <= 0 {
                    blocks.insert(.maxFlightRadiusRequired)
                } else {
                    let maximumDistance = mission.waypoints.map {
                        distanceMeters(telemetry.latitude, telemetry.longitude,
                                       $0.point.latitude, $0.point.longitude)
                    }.max() ?? .infinity
                    if !maximumDistance.isFinite || maximumDistance > Double(telemetry.maxFlightRadiusMeters) {
                        blocks.insert(.maxFlightRadiusTooSmall)
                    }
                }
            }
        }
        if !evidence.simulatorRegressionPassed { blocks.insert(.simulatorRegressionRequired) }
        if !evidence.failsafeRegressionPassed { blocks.insert(.failsafeRegressionRequired) }
        if !evidence.fruBenchDirectionVerified { blocks.insert(.fruBenchVerificationRequired) }
        if !evidence.cameraCalibrated { blocks.insert(.cameraCalibrationRequired) }
        if !evidence.operatingAreaReviewed { blocks.insert(.operatingAreaReviewRequired) }
        return .init(readyForReview: blocks.isEmpty, blocks: blocks)
    }

    private static func distanceMeters(_ latA: Double, _ lonA: Double,
                                       _ latB: Double, _ lonB: Double) -> Double {
        let north = (latB - latA) * 111_132
        let east = (lonB - lonA) * 111_320 * cos((latA + latB) / 2 * .pi / 180)
        return hypot(north, east)
    }
}

enum SurveyRegressionMissionFactory {
    /// Creates a deterministic nearby mission. It never starts execution.
    static func create(center: SurveyGeoPoint, fiveDirection: Bool) throws -> SurveyMission {
        guard center.latitude.isFinite, center.longitude.isFinite else {
            throw SurveyValidationError.invalid("debug mission center must be finite")
        }
        let latitudeDelta = 25 / 111_132.0
        let longitudeDelta = 20 / (111_320 * cos(center.latitude * .pi / 180))
        let roi = [
            SurveyGeoPoint(latitude: center.latitude + latitudeDelta,
                           longitude: center.longitude - longitudeDelta),
            SurveyGeoPoint(latitude: center.latitude + latitudeDelta,
                           longitude: center.longitude + longitudeDelta),
            SurveyGeoPoint(latitude: center.latitude - latitudeDelta,
                           longitude: center.longitude + longitudeDelta),
            SurveyGeoPoint(latitude: center.latitude - latitudeDelta,
                           longitude: center.longitude - longitudeDelta),
        ]
        let constraints = try SurveyParameterPolicy.createConstraints(
            altitudeMetersAgl: 30, routeHeadingDegrees: 0,
            forwardOverlapPercent: 80, sideOverlapPercent: 70,
            speedMetersPerSecond: 2, gimbalPitchDegrees: fiveDirection ? -45 : -90,
            boundaryMarginMeters: 3, obliqueFiveDirection: fiveDirection,
            safeTakeoffAltitudeMeters: 20, takeoffSpeedMetersPerSecond: 3,
            obliqueForwardOverlapPercent: 70, obliqueSideOverlapPercent: 60
        )
        return try SurveyPlanner.plan(
            name: fiveDirection ? "DEBUG 五向回归 50x40m" : "DEBUG 正射回归 50x40m",
            roi: roi, camera: .djiMini2, constraints: constraints, takeoffPoint: center
        )
    }
}
