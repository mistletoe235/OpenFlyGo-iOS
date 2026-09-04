import Foundation

struct SurveyExecutionTelemetry: Equatable {
    var connected: Bool
    var simulatorActive: Bool
    var simulatorFlying: Bool
    var virtualStickEnabled: Bool
    var sticksActive: Bool
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double
    var updatedAtEpochMillis: Int64
    var aircraftFlying: Bool
    var batteryPercent: Int = 100
    var rcBatteryPercent: Int = 100
    var rcSignalPercent: Int = 100
    var satelliteCount: Int = 99
    var gpsSignalUsable: Bool = true
    var homeLocationValid: Bool = true
    var homeLatitude: Double = .nan
    var homeLongitude: Double = .nan
    var goHomeHeightMeters: Int = 120
    var maxFlightHeightMeters: Int = 120
    var maxFlightRadiusMeters: Int = 10_000
    var maxFlightRadiusEnabled: Bool = true
    var horizontalSpeedMetersPerSecond: Double = 0
    var verticalSpeedMetersPerSecond: Double = 0
    var goingHome: Bool = false
    var landing: Bool = false

    init(connected: Bool, simulatorActive: Bool, simulatorFlying: Bool,
         virtualStickEnabled: Bool, sticksActive: Bool, latitude: Double,
         longitude: Double, altitudeMeters: Double, updatedAtEpochMillis: Int64,
         aircraftFlying: Bool? = nil, batteryPercent: Int = 100,
         rcBatteryPercent: Int = 100, rcSignalPercent: Int = 100,
         satelliteCount: Int = 99, gpsSignalUsable: Bool = true,
         homeLocationValid: Bool = true, homeLatitude: Double = .nan,
         homeLongitude: Double = .nan, goHomeHeightMeters: Int = 120,
         maxFlightHeightMeters: Int = 120, maxFlightRadiusMeters: Int = 10_000,
         maxFlightRadiusEnabled: Bool = true,
         horizontalSpeedMetersPerSecond: Double = 0,
         verticalSpeedMetersPerSecond: Double = 0,
         goingHome: Bool = false, landing: Bool = false) {
        self.connected = connected; self.simulatorActive = simulatorActive
        self.simulatorFlying = simulatorFlying; self.virtualStickEnabled = virtualStickEnabled
        self.sticksActive = sticksActive; self.latitude = latitude; self.longitude = longitude
        self.altitudeMeters = altitudeMeters; self.updatedAtEpochMillis = updatedAtEpochMillis
        self.aircraftFlying = aircraftFlying ?? simulatorFlying
        self.batteryPercent = batteryPercent; self.rcBatteryPercent = rcBatteryPercent
        self.rcSignalPercent = rcSignalPercent; self.satelliteCount = satelliteCount
        self.gpsSignalUsable = gpsSignalUsable; self.homeLocationValid = homeLocationValid
        self.homeLatitude = homeLatitude; self.homeLongitude = homeLongitude
        self.goHomeHeightMeters = goHomeHeightMeters; self.maxFlightHeightMeters = maxFlightHeightMeters
        self.maxFlightRadiusMeters = maxFlightRadiusMeters
        self.maxFlightRadiusEnabled = maxFlightRadiusEnabled
        self.horizontalSpeedMetersPerSecond = horizontalSpeedMetersPerSecond
        self.verticalSpeedMetersPerSecond = verticalSpeedMetersPerSecond
        self.goingHome = goingHome; self.landing = landing
    }
}

enum SurveyExecutionEnvironment { case djiSimulator, realAircraftManualTakeoff }

enum SurveyExecutionGate {
    static let maximumTelemetryAgeMillis: Int64 = 1_500
    static let maximumMissionPathMeters = 100_000.0
    static let minimumMissionAltitudeMeters = 5.0
    static let maximumMissionAltitudeMeters = 120.0
    static let realMinimumBatteryPercent = 30
    static let realMinimumRCBatteryPercent = 30
    static let realMinimumRCSignalPercent = 40
    static let realMinimumSatellites = 12

    static func evaluate(
        mission: SurveyMission,
        telemetry: SurveyExecutionTelemetry,
        nowEpochMillis: Int64,
        requireVirtualStick: Bool,
        allowNotFlying: Bool = false,
        allowGroundedPositionUnavailable: Bool = false,
        environment: SurveyExecutionEnvironment = .djiSimulator,
        checkPreflightReadiness: Bool = true
    ) -> SurveyExecutionGateResult {
        var blocks = Set<SurveyExecutionBlock>()
        if mission.terrainPlan != nil, !OpenFlyBuildFeatures.terrainFollowing {
            blocks.insert(.terrainFeatureDisabled)
        }
        if !telemetry.connected { blocks.insert(.aircraftDisconnected) }
        switch environment {
        case .djiSimulator:
            if !telemetry.simulatorActive { blocks.insert(.simulatorRequired) }
            if !telemetry.simulatorFlying && !allowNotFlying { blocks.insert(.simulatorNotFlying) }
        case .realAircraftManualTakeoff:
            if telemetry.simulatorActive { blocks.insert(.simulatorMustBeOff) }
            if !telemetry.aircraftFlying { blocks.insert(.realAircraftNotFlying) }
            if telemetry.goingHome || telemetry.landing {
                blocks.insert(.flightControllerFailsafeActive)
            }
            if !requireVirtualStick, telemetry.aircraftFlying,
               telemetry.altitudeMeters < 1.5
                || abs(telemetry.horizontalSpeedMetersPerSecond) > 1
                || abs(telemetry.verticalSpeedMetersPerSecond) > 0.5 {
                blocks.insert(.realAircraftNotStablyHovering)
            }
            if checkPreflightReadiness {
                if mission.constraints.takeoffMode != .manual { blocks.insert(.realRequiresManualTakeoff) }
                if telemetry.batteryPercent < realMinimumBatteryPercent { blocks.insert(.aircraftBatteryLow) }
                if telemetry.rcBatteryPercent < realMinimumRCBatteryPercent { blocks.insert(.rcBatteryLow) }
                if telemetry.rcSignalPercent < realMinimumRCSignalPercent { blocks.insert(.rcSignalWeak) }
                if telemetry.satelliteCount < realMinimumSatellites { blocks.insert(.gpsSatellitesLow) }
                if !telemetry.gpsSignalUsable { blocks.insert(.gpsSignalWeak) }
                if !telemetry.homeLocationValid { blocks.insert(.homeLocationRequired) }
            }
        }

        let age = nowEpochMillis - telemetry.updatedAtEpochMillis
        if age < 0 || age > maximumTelemetryAgeMillis { blocks.insert(.telemetryStale) }
        let positionUnavailable = !telemetry.latitude.isFinite || !telemetry.longitude.isFinite
        if positionUnavailable && !allowGroundedPositionUnavailable { blocks.insert(.gpsUnavailable) }
        if telemetry.sticksActive { blocks.insert(.manualTakeover) }
        if requireVirtualStick && !telemetry.virtualStickEnabled { blocks.insert(.virtualStickRequired) }

        if checkPreflightReadiness {
            if mission.coordinateFrame != "WGS84" { blocks.insert(.unsupportedCoordinateFrame) }
            if environment == .djiSimulator, mission.estimatedPathMeters > maximumMissionPathMeters {
                blocks.insert(.missionTooLong)
            }
            if !(minimumMissionAltitudeMeters...maximumMissionAltitudeMeters)
                .contains(mission.constraints.safeTakeoffAltitudeMeters)
                || mission.waypoints.contains(where: {
                    !(minimumMissionAltitudeMeters...maximumMissionAltitudeMeters).contains($0.point.altitudeMeters)
                }) {
                blocks.insert(.missionAltitudeUnsafe)
            }
            let nadir = try? SurveyCoveragePlanner.captureFeasibility(
                camera: mission.cameraProfile, constraints: mission.constraints
            )
            let oblique = try? SurveyCoveragePlanner.captureFeasibility(
                camera: mission.cameraProfile, constraints: mission.constraints, oblique: true
            )
            if nadir?.feasible != true
                || mission.constraints.collectionMode == .obliqueFiveDirection && oblique?.feasible != true {
                blocks.insert(.cameraTriggerUnsafe)
            }
        }

        let first = mission.waypoints.first?.point
        let startDistance = first.map {
            positionUnavailable ? .infinity : distanceMeters(telemetry.latitude, telemetry.longitude,
                                                             $0.latitude, $0.longitude)
        } ?? .infinity

        if checkPreflightReadiness, environment == .realAircraftManualTakeoff {
            if mission.terrainPlan?.realFlightVerified == false {
                blocks.insert(.terrainRealFlightNotVerified)
            }
            let maxAltitude = mission.waypoints.map(\.point.altitudeMeters).max()
                ?? mission.constraints.safeTakeoffAltitudeMeters
            if telemetry.goHomeHeightMeters <= 0 || Double(telemetry.goHomeHeightMeters) + 0.5 < maxAltitude {
                blocks.insert(.goHomeHeightUnsafe)
            }
            if telemetry.maxFlightHeightMeters <= 0 || Double(telemetry.maxFlightHeightMeters) + 0.5 < maxAltitude {
                blocks.insert(.maxFlightHeightTooLow)
            }
            if telemetry.maxFlightRadiusEnabled {
                if telemetry.maxFlightRadiusMeters <= 0 {
                    blocks.insert(.maxFlightRadiusRequired)
                } else {
                    let originLatitude = telemetry.homeLatitude.isFinite ? telemetry.homeLatitude : telemetry.latitude
                    let originLongitude = telemetry.homeLongitude.isFinite ? telemetry.homeLongitude : telemetry.longitude
                    if mission.waypoints.contains(where: {
                        distanceMeters(originLatitude, originLongitude,
                                       $0.point.latitude, $0.point.longitude) > Double(telemetry.maxFlightRadiusMeters)
                    }) { blocks.insert(.maxFlightRadiusTooSmall) }
                }
            }
        }
        return .init(allowed: blocks.isEmpty, blocks: blocks, startDistanceMeters: startDistance)
    }

    private static func distanceMeters(_ latA: Double, _ lonA: Double,
                                       _ latB: Double, _ lonB: Double) -> Double {
        let north = (latB - latA) * 111_132
        let east = (lonB - lonA) * 111_320 * cos((latA + latB) / 2 * .pi / 180)
        return hypot(north, east)
    }
}

struct SurveyExecutionLeg: Equatable {
    var phase: SurveyExecutionPhase
    var target: SurveyWaypoint
    var missionWaypointIndex: Int?
}

struct SurveyExecutionStatus: Equatable {
    var state: SurveyExecutionState
    var waypointIndex: Int
    var reason: String?
}

struct SurveyRemainingEstimate: Equatable {
    var currentSectionSeconds: Double
    var totalSeconds: Double
}

/// Pure state machine. DJI side effects remain in a separately audited adapter.
final class SurveyExecutionStateMachine {
    private let mission: SurveyMission
    private let legs: [SurveyExecutionLeg]
    private var pausedRecoveryPoint: SurveyGeoPoint?
    private var resumeTarget: SurveyWaypoint?
    private(set) var executionLegIndex = 0
    private(set) var status = SurveyExecutionStatus(state: .idle, waypointIndex: 0, reason: nil)

    var currentPhase: SurveyExecutionPhase { resumeTarget == nil ? legs[executionLegIndex].phase : .recoveryToPause }
    var currentMissionWaypointIndex: Int? {
        resumeTarget == nil ? legs[executionLegIndex].missionWaypointIndex : nil
    }
    /// Android V5 aligns heading before every synthetic transit/recovery leg.
    /// Mission waypoints keep their smooth simultaneous translation/yaw behavior.
    var requiresHeadingAlignmentBeforeTranslation: Bool {
        resumeTarget != nil || legs[executionLegIndex].missionWaypointIndex == nil
    }
    var currentTarget: SurveyWaypoint {
        if let resumeTarget { return resumeTarget }
        if status.state == .paused, let pausedRecoveryPoint {
            var target = legs[executionLegIndex].target
            target.point = pausedRecoveryPoint; target.kind = .transit
            target.captureAction = .none; target.captureIntervalMeters = nil; target.gimbalPitchDegrees = 0
            return target
        }
        return legs[executionLegIndex].target
    }
    var executionLegCount: Int { legs.count }

    func remainingEstimate(
        currentPosition: SurveyGeoPoint?,
        currentHeadingDegrees: Double = .nan,
        currentHorizontalSpeedMetersPerSecond: Double = .nan,
        currentVerticalSpeedMetersPerSecond: Double = .nan
    ) -> SurveyRemainingEstimate {
        guard status.state != .completed, legs.indices.contains(executionLegIndex) else {
            return .init(currentSectionSeconds: 0, totalSeconds: 0)
        }
        let sectionEnd = currentSectionEndIndex()
        var total = 0.0, section = 0.0
        var from = currentPosition ?? (executionLegIndex > 0 ? legs[executionLegIndex - 1].target.point : currentTarget.point)
        var previousTarget = executionLegIndex > 0 ? legs[executionLegIndex - 1].target : nil
        for index in executionLegIndex..<legs.count {
            let leg = legs[index]
            let horizontalDistance = Self.distanceMeters(from, leg.target.point)
            let verticalDistance = abs(leg.target.point.altitudeMeters - from.altitudeMeters)
            let configuredHorizontal = speed(for: leg)
            let configuredVertical = verticalSpeed(for: leg, fromAltitudeMeters: from.altitudeMeters)
            let horizontalSpeed = index == executionLegIndex
                ? effectiveLiveSpeed(currentHorizontalSpeedMetersPerSecond, configured: configuredHorizontal)
                : configuredHorizontal
            let verticalSpeed = index == executionLegIndex
                ? effectiveLiveSpeed(abs(currentVerticalSpeedMetersPerSecond), configured: configuredVertical)
                : configuredVertical
            var seconds = max(horizontalDistance / horizontalSpeed, verticalDistance / verticalSpeed)
            let previousHeading = index == executionLegIndex && currentHeadingDegrees.isFinite
                ? currentHeadingDegrees : previousTarget?.headingDegrees
            if let previousHeading {
                let yawDelta = Self.shortestAngleDegrees(previousHeading, leg.target.headingDegrees)
                if yawDelta > SurveyWaypointFollower.headingToleranceDegrees {
                    seconds += 2 + yawDelta / SurveyWaypointFollower.maxYawRateDegreesPerSecond
                }
            }
            if let previousTarget,
               abs(previousTarget.gimbalPitchDegrees - leg.target.gimbalPitchDegrees) > 5 {
                seconds += 3
            }
            seconds += SurveyETAPolicy.captureDelaySeconds(for: leg.target.captureAction)
            total += seconds
            if index <= sectionEnd { section += seconds }
            from = leg.target.point
            previousTarget = leg.target
        }
        return .init(currentSectionSeconds: section, totalSeconds: total)
    }

    init(mission: SurveyMission, launchPoint: SurveyGeoPoint? = nil) {
        self.mission = mission
        legs = Self.buildExecutionLegs(
            mission: mission, currentPoint: launchPoint, returnPoint: launchPoint
        )
    }

    init(mission: SurveyMission, currentPoint: SurveyGeoPoint?,
         returnPoint: SurveyGeoPoint?) {
        self.mission = mission
        legs = Self.buildExecutionLegs(
            mission: mission, currentPoint: currentPoint, returnPoint: returnPoint
        )
    }

    @discardableResult func requestArm(_ gate: SurveyExecutionGateResult) -> SurveyExecutionStatus {
        status = gate.allowed
            ? .init(state: .arming, waypointIndex: 0, reason: nil)
            : .init(state: .aborted, waypointIndex: 0, reason: "arm blocked: \(blockText(gate))")
        return status
    }

    @discardableResult func onVirtualStickReady(_ gate: SurveyExecutionGateResult) -> SurveyExecutionStatus {
        guard status.state == .arming else { return status }
        status = gate.allowed
            ? .init(state: .running, waypointIndex: 0, reason: nil)
            : .init(state: .paused, waypointIndex: 0, reason: "run blocked: \(blockText(gate))")
        return status
    }

    @discardableResult func validate(_ gate: SurveyExecutionGateResult) -> SurveyExecutionStatus {
        guard status.state == .running else { return status }
        if !gate.allowed {
            status = .init(state: .paused, waypointIndex: status.waypointIndex,
                           reason: "runtime gate: \(blockText(gate))")
        }
        return status
    }

    @discardableResult func reachWaypoint() -> SurveyExecutionStatus {
        guard status.state == .running else { return status }
        if resumeTarget != nil {
            resumeTarget = nil; pausedRecoveryPoint = nil
            return status
        }
        let next = executionLegIndex + 1
        if next >= legs.count {
            status = .init(state: .completed, waypointIndex: mission.waypoints.count - 1, reason: nil)
        } else {
            executionLegIndex = next
            status = .init(state: .running,
                           waypointIndex: legs[next].missionWaypointIndex ?? status.waypointIndex,
                           reason: nil)
        }
        return status
    }

    /// Completes a custom mission only after DJI accepted the native RTH
    /// request. The app must not keep flying the return path with Virtual Stick.
    @discardableResult func acceptDJIReturnHome() -> SurveyExecutionStatus {
        guard status.state == .running,
              mission.constraints.completionAction == .returnToHome,
              currentPhase == .returnHome else { return status }
        resumeTarget = nil
        pausedRecoveryPoint = nil
        executionLegIndex = max(0, legs.count - 1)
        status = .init(state: .completed,
                       waypointIndex: max(0, mission.waypoints.count - 1), reason: nil)
        return status
    }

    @discardableResult func pause(reason: String? = nil, recoveryPoint: SurveyGeoPoint? = nil) -> SurveyExecutionStatus {
        if status.state == .running || status.state == .arming {
            status.state = .paused; status.reason = reason
            pausedRecoveryPoint = recoveryPoint; resumeTarget = nil
        }
        return status
    }

    @discardableResult func resume(_ gate: SurveyExecutionGateResult,
                                   currentPoint: SurveyGeoPoint? = nil) -> SurveyExecutionStatus {
        guard status.state == .paused else { return status }
        guard gate.allowed else { status.reason = "resume blocked: \(blockText(gate))"; return status }
        if let currentPoint, let recovery = pausedRecoveryPoint,
           Self.distanceMeters(currentPoint, recovery) > SurveyWaypointFollower.horizontalToleranceMeters {
            var target = legs[executionLegIndex].target
            target.point = recovery; target.headingDegrees = Self.bearingDegrees(from: currentPoint, to: recovery)
            target.gimbalPitchDegrees = 0; target.kind = .transit
            target.captureAction = .none; target.captureIntervalMeters = nil
            resumeTarget = target
        } else { pausedRecoveryPoint = nil }
        status.state = .running; status.reason = nil
        return status
    }

    @discardableResult func abort(reason: String) -> SurveyExecutionStatus {
        status.state = .aborted; status.reason = reason; return status
    }

    @discardableResult func restorePaused(waypointIndex: Int, legIndex: Int? = nil,
                                          recoveryPoint: SurveyGeoPoint? = nil) throws -> SurveyExecutionStatus {
        guard mission.waypoints.indices.contains(waypointIndex) else {
            throw SurveyValidationError.invalid("checkpoint waypoint is out of range")
        }
        executionLegIndex = legIndex.flatMap { legs.indices.contains($0) ? $0 : nil }
            ?? legs.firstIndex(where: { $0.missionWaypointIndex == waypointIndex }) ?? 0
        status = .init(state: .paused, waypointIndex: waypointIndex,
                       reason: "restored after process restart")
        pausedRecoveryPoint = recoveryPoint; resumeTarget = nil
        return status
    }

    func recoveryPoint() -> SurveyGeoPoint? { pausedRecoveryPoint }

    private func currentSectionEndIndex() -> Int {
        let current = legs[executionLegIndex]
        var end = executionLegIndex
        if current.phase == .survey {
            while end + 1 < legs.count, legs[end + 1].phase == .survey,
                  legs[end + 1].target.passIndex == current.target.passIndex { end += 1 }
        } else {
            while end + 1 < legs.count, legs[end + 1].phase == current.phase { end += 1 }
        }
        return end
    }

    private func speed(for leg: SurveyExecutionLeg) -> Double {
        max(0.2, leg.phase == .safeClimb
            ? mission.constraints.takeoffSpeedMetersPerSecond
            : mission.constraints.speed(for: leg.target.captureView))
    }

    private func verticalSpeed(for leg: SurveyExecutionLeg, fromAltitudeMeters: Double) -> Double {
        return max(0.2, leg.target.point.altitudeMeters < fromAltitudeMeters
            ? mission.constraints.descentSpeedMetersPerSecond
            : mission.constraints.takeoffSpeedMetersPerSecond)
    }

    private func effectiveLiveSpeed(_ actual: Double, configured: Double) -> Double {
        guard actual.isFinite, actual >= 0.1 else { return configured }
        return max(0.2, min(configured * 1.25, max(configured * 0.35, actual)))
    }

    @discardableResult func reset() -> SurveyExecutionStatus {
        executionLegIndex = 0
        status = .init(state: .idle, waypointIndex: 0, reason: nil)
        return status
    }

    static func buildExecutionLegs(mission: SurveyMission,
                                   launchPoint: SurveyGeoPoint?) -> [SurveyExecutionLeg] {
        buildExecutionLegs(
            mission: mission, currentPoint: launchPoint, returnPoint: launchPoint
        )
    }

    static func buildExecutionLegs(mission: SurveyMission,
                                   currentPoint: SurveyGeoPoint?,
                                   returnPoint: SurveyGeoPoint?) -> [SurveyExecutionLeg] {
        // Match Android V5: every non-oblique route follows the flight line;
        // five-direction routes only opt out when fixed camera heading is used.
        // This also inserts a forward-facing synthetic leg between ortho strips,
        // avoiding a combined yaw + sideways translation into the next strip.
        let trackRoute = mission.constraints.collectionMode != .obliqueFiveDirection
            || mission.constraints.obliqueHeadingMode == .trackRoute
        var routeHeadingsByPass: [Int: Double] = [:]
        if trackRoute {
            for (passIndex, waypoints) in Dictionary(
                grouping: mission.waypoints, by: \SurveyWaypoint.passIndex
            ) {
                guard let start = waypoints.first(where: { $0.kind == .passStart }),
                      let end = waypoints.first(where: { $0.kind == .passEnd }) else { continue }
                let heading = bearingDegrees(from: start.point, to: end.point)
                routeHeadingsByPass[passIndex] = abs(heading) < 1e-9 ? 0 : heading
            }
        }
        let surveyWaypoints = mission.waypoints.map { waypoint -> SurveyWaypoint in
            guard let heading = routeHeadingsByPass[waypoint.passIndex] else { return waypoint }
            var value = waypoint
            value.headingDegrees = heading
            return value
        }
        guard let first = surveyWaypoints.first, let last = surveyWaypoints.last else { return [] }
        let safeAltitude = max(mission.constraints.safeTakeoffAltitudeMeters, first.point.altitudeMeters)
        func transit(_ point: SurveyGeoPoint, phase: SurveyExecutionPhase,
                     heading: Double = first.headingDegrees,
                     pitch: Double = -90) -> SurveyExecutionLeg {
            .init(phase: phase,
                  target: .init(point: point, headingDegrees: heading,
                                gimbalPitchDegrees: pitch, kind: .transit,
                                captureAction: .none, captureIntervalMeters: nil,
                                passIndex: 0),
                  missionWaypointIndex: nil)
        }
        var result: [SurveyExecutionLeg] = []
        if let currentPoint {
            result.append(transit(.init(latitude: currentPoint.latitude, longitude: currentPoint.longitude,
                                        altitudeMeters: safeAltitude),
                                  phase: .safeClimb, pitch: 0))
            result.append(transit(.init(latitude: first.point.latitude, longitude: first.point.longitude,
                                        altitudeMeters: safeAltitude),
                                  phase: .transitToStart,
                                  heading: bearingDegrees(from: currentPoint, to: first.point),
                                  pitch: 0))
        }
        var previousSurveyPoint: SurveyGeoPoint?
        for (index, waypoint) in surveyWaypoints.enumerated() {
            if trackRoute, waypoint.kind == .passStart, let previousSurveyPoint {
                result.append(transit(
                    waypoint.point, phase: .survey,
                    heading: bearingDegrees(from: previousSurveyPoint, to: waypoint.point),
                    pitch: waypoint.gimbalPitchDegrees
                ))
            }
            result.append(.init(phase: .survey, target: waypoint, missionWaypointIndex: index))
            previousSurveyPoint = waypoint.point
        }
        if mission.constraints.completionAction == .returnToHome, let returnPoint {
            let heading = bearingDegrees(from: last.point, to: returnPoint)
            result.append(transit(.init(latitude: last.point.latitude, longitude: last.point.longitude,
                                        altitudeMeters: safeAltitude),
                                  phase: .returnHome, heading: last.headingDegrees, pitch: 0))
            result.append(transit(.init(latitude: returnPoint.latitude, longitude: returnPoint.longitude,
                                        altitudeMeters: safeAltitude),
                                  phase: .returnHome, heading: heading, pitch: 0))
            result.append(transit(returnPoint, phase: .returnHome, heading: heading, pitch: -90))
        } else if mission.constraints.completionAction == .returnToRouteStart {
            let heading = bearingDegrees(from: last.point, to: first.point)
            result.append(transit(.init(latitude: last.point.latitude, longitude: last.point.longitude,
                                        altitudeMeters: safeAltitude),
                                  phase: .returnToStart, heading: last.headingDegrees, pitch: 0))
            result.append(transit(.init(latitude: first.point.latitude, longitude: first.point.longitude,
                                        altitudeMeters: safeAltitude),
                                  phase: .returnToStart, heading: heading, pitch: 0))
            result.append(transit(first.point, phase: .returnToStart, heading: heading, pitch: -90))
        }
        return result
    }

    private func blockText(_ gate: SurveyExecutionGateResult) -> String {
        gate.blocks.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func bearingDegrees(from: SurveyGeoPoint, to: SurveyGeoPoint) -> Double {
        let fromLatitude = from.latitude * .pi / 180
        let toLatitude = to.latitude * .pi / 180
        let longitudeDelta = (to.longitude - from.longitude) * .pi / 180
        let y = sin(longitudeDelta) * cos(toLatitude)
        let x = cos(fromLatitude) * sin(toLatitude)
            - sin(fromLatitude) * cos(toLatitude) * cos(longitudeDelta)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func distanceMeters(_ a: SurveyGeoPoint, _ b: SurveyGeoPoint) -> Double {
        hypot((b.latitude - a.latitude) * 111_132,
              (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) * .pi / 360))
    }

    private static func shortestAngleDegrees(_ a: Double, _ b: Double) -> Double {
        abs((b - a + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
}
