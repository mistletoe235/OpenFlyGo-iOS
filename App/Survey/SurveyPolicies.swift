import Foundation

enum SurveyParameterPolicy {
    static func createConstraints(
        altitudeMetersAgl: Double,
        routeHeadingDegrees: Double,
        forwardOverlapPercent: Double,
        sideOverlapPercent: Double,
        speedMetersPerSecond: Double,
        obliqueSpeedMetersPerSecond: Double? = nil,
        gimbalPitchDegrees: Double,
        boundaryMarginMeters: Double,
        obliqueFiveDirection: Bool,
        targetSurfaceToTakeoffMeters: Double = 0,
        safeTakeoffAltitudeMeters: Double = 30,
        takeoffSpeedMetersPerSecond: Double = 3,
        descentSpeedMetersPerSecond: Double = 2,
        obliqueForwardOverlapPercent: Double = 70,
        obliqueSideOverlapPercent: Double = 60,
        altitudeMode: SurveyAltitudeMode = .aboveTargetSurface,
        startPointMode: SurveyStartPointMode = .autoNearest,
        completionAction: SurveyCompletionAction = .returnToHome,
        captureTriggerMode: SurveyCaptureTriggerMode = .distance,
        timedCaptureIntervalSeconds: Double = 1,
        takeoffMode: SurveyTakeoffMode = .manual,
        enabledCaptureViews: Set<SurveyCaptureView> = SurveyCaptureView.standardSurveyViews,
        obliqueHeadingMode: SurveyObliqueHeadingMode = .trackRoute
    ) throws -> SurveyConstraints {
        try require((10...120).contains(altitudeMetersAgl), "高度必须在 10–120 m")
        try require(routeHeadingDegrees.isFinite, "航向必须是有效数字")
        try require((50...90).contains(forwardOverlapPercent), "前向重叠率必须在 50–90%")
        try require((40...90).contains(sideOverlapPercent), "旁向重叠率必须在 40–90%")
        try require((0.5...10).contains(speedMetersPerSecond), "规划速度必须在 0.5–10.0 m/s")
        let obliqueSpeed = obliqueSpeedMetersPerSecond ?? speedMetersPerSecond
        try require((0.5...10).contains(obliqueSpeed), "倾斜速度必须在 0.5–10.0 m/s")
        let pitchRange = obliqueFiveDirection ? -80.0 ... -30.0 : -90.0 ... -30.0
        try require(pitchRange.contains(gimbalPitchDegrees), obliqueFiveDirection
                    ? "五向倾斜俯角必须在 -80° 到 -30°"
                    : "云台俯角必须在 -90° 到 -30°")
        try require((0...30).contains(boundaryMarginMeters), "边界外扩必须在 0–30 m")
        try require((-500...500).contains(targetSurfaceToTakeoffMeters), "目标面高差必须在 -500–500 m")
        try require((5...120).contains(safeTakeoffAltitudeMeters), "安全起飞高度必须在 5–120 m")
        try require((0.5...6).contains(takeoffSpeedMetersPerSecond), "上升速度必须在 0.5–6.0 m/s")
        try require((0.5...6).contains(descentSpeedMetersPerSecond), "下降速度必须在 0.5–6.0 m/s")
        try require((50...90).contains(obliqueForwardOverlapPercent), "倾斜前向重叠率必须在 50–90%")
        try require((40...90).contains(obliqueSideOverlapPercent), "倾斜旁向重叠率必须在 40–90%")
        try require((1...60).contains(timedCaptureIntervalSeconds), "定时拍照间隔必须在 1–60 s")
        let effectiveAltitude = altitudeMode == .aboveTargetSurface
            ? altitudeMetersAgl + targetSurfaceToTakeoffMeters : altitudeMetersAgl
        try require((5...120).contains(effectiveAltitude), "航点相对起飞点高度必须在 5–120 m")

        var value = SurveyConstraints()
        value.altitudeMetersAgl = altitudeMetersAgl
        value.forwardOverlap = forwardOverlapPercent / 100
        value.sideOverlap = sideOverlapPercent / 100
        value.speedMetersPerSecond = speedMetersPerSecond
        value.obliqueSpeedMetersPerSecond = obliqueSpeed
        value.gimbalPitchDegrees = -90
        value.routeHeadingDegrees = routeHeadingDegrees.truncatingRemainder(dividingBy: 360) < 0
            ? routeHeadingDegrees.truncatingRemainder(dividingBy: 360) + 360
            : routeHeadingDegrees.truncatingRemainder(dividingBy: 360)
        value.collectionMode = obliqueFiveDirection ? .obliqueFiveDirection : .ortho
        value.obliqueGimbalPitchDegrees = gimbalPitchDegrees
        value.boundaryMarginMeters = boundaryMarginMeters
        value.altitudeMode = altitudeMode
        value.targetSurfaceToTakeoffMeters = targetSurfaceToTakeoffMeters
        value.safeTakeoffAltitudeMeters = safeTakeoffAltitudeMeters
        value.takeoffSpeedMetersPerSecond = takeoffSpeedMetersPerSecond
        value.descentSpeedMetersPerSecond = descentSpeedMetersPerSecond
        value.takeoffMode = takeoffMode
        value.obliqueForwardOverlap = obliqueForwardOverlapPercent / 100
        value.obliqueSideOverlap = obliqueSideOverlapPercent / 100
        value.startPointMode = startPointMode
        value.completionAction = completionAction
        value.captureTriggerMode = captureTriggerMode
        value.timedCaptureIntervalSeconds = timedCaptureIntervalSeconds
        value.enabledCaptureViews = enabledCaptureViews
        value.obliqueHeadingMode = obliqueHeadingMode
        try value.validate()
        return value
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SurveyValidationError.invalid(message) }
    }
}

enum SurveyExecutionState: String, Codable { case idle = "IDLE", arming = "ARMING", running = "RUNNING", paused = "PAUSED", completed = "COMPLETED", aborted = "ABORTED" }
enum SurveyExecutionPhase: String, Codable { case safeClimb = "SAFE_CLIMB", transitToStart = "TRANSIT_TO_START", recoveryToPause = "RECOVERY_TO_PAUSE", survey = "SURVEY", returnHome = "RETURN_HOME", returnToStart = "RETURN_TO_START" }
enum SurveyExecutionBlock: String, Codable, Hashable { case aircraftDisconnected = "AIRCRAFT_DISCONNECTED", simulatorRequired = "SIMULATOR_REQUIRED", simulatorNotFlying = "SIMULATOR_NOT_FLYING", simulatorMustBeOff = "SIMULATOR_MUST_BE_OFF", realAircraftNotFlying = "REAL_AIRCRAFT_NOT_FLYING", realAircraftNotStablyHovering = "REAL_AIRCRAFT_NOT_STABLY_HOVERING", realRequiresManualTakeoff = "REAL_REQUIRES_MANUAL_TAKEOFF", telemetryStale = "TELEMETRY_STALE", gpsUnavailable = "GPS_UNAVAILABLE", manualTakeover = "MANUAL_TAKEOVER", virtualStickRequired = "VIRTUAL_STICK_REQUIRED", unsupportedCoordinateFrame = "UNSUPPORTED_COORDINATE_FRAME", missionTooLong = "MISSION_TOO_LONG", missionAltitudeUnsafe = "MISSION_ALTITUDE_UNSAFE", cameraUnavailable = "CAMERA_UNAVAILABLE", cameraTriggerUnsafe = "CAMERA_TRIGGER_UNSAFE", aircraftBatteryLow = "AIRCRAFT_BATTERY_LOW", rcBatteryLow = "RC_BATTERY_LOW", rcSignalWeak = "RC_SIGNAL_WEAK", gpsSatellitesLow = "GPS_SATELLITES_LOW", gpsSignalWeak = "GPS_SIGNAL_WEAK", homeLocationRequired = "HOME_LOCATION_REQUIRED", goHomeHeightUnsafe = "GO_HOME_HEIGHT_UNSAFE", maxFlightHeightTooLow = "MAX_FLIGHT_HEIGHT_TOO_LOW", maxFlightRadiusRequired = "MAX_FLIGHT_RADIUS_REQUIRED", maxFlightRadiusTooSmall = "MAX_FLIGHT_RADIUS_TOO_SMALL", flightControllerFailsafeActive = "FLIGHT_CONTROLLER_FAILSAFE_ACTIVE", terrainFeatureDisabled = "TERRAIN_FEATURE_DISABLED", terrainRealFlightNotVerified = "TERRAIN_REAL_FLIGHT_NOT_VERIFIED" }

struct SurveyExecutionGateResult: Equatable {
    var allowed: Bool
    var blocks: Set<SurveyExecutionBlock>
    var startDistanceMeters: Double
}

struct SurveyFollowerPose: Equatable {
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double
    var headingDegrees: Double
}

struct SurveyFollowerCommand: Equatable {
    var reached: Bool
    var horizontalErrorMeters: Double
    var verticalErrorMeters: Double
    var forwardMetersPerSecond: Double
    var rightMetersPerSecond: Double
    var upMetersPerSecond: Double
    var yawRateDegreesPerSecond: Double
}

enum SurveyWaypointFollower {
    static let horizontalToleranceMeters = 1.2
    static let verticalToleranceMeters = 0.4
    static let headingToleranceDegrees = 6.0
    static let maxVerticalSpeedMetersPerSecond = 0.5
    static let maxYawRateDegreesPerSecond = 30.0

    static func command(
        pose: SurveyFollowerPose,
        target: SurveyWaypoint,
        maximumHorizontalSpeedMetersPerSecond: Double,
        maximumVerticalSpeedMetersPerSecond: Double = maxVerticalSpeedMetersPerSecond,
        alignHeadingBeforeHorizontalMotion: Bool = false
    ) throws -> SurveyFollowerCommand {
        guard (0.1...10).contains(maximumHorizontalSpeedMetersPerSecond),
              (0.1...10).contains(maximumVerticalSpeedMetersPerSecond) else {
            throw SurveyValidationError.invalid("survey speed must be in [0.1, 10.0] m/s")
        }
        let northError = (target.point.latitude - pose.latitude) * 111_132
        let eastError = (target.point.longitude - pose.longitude) * 111_320
            * cos(pose.latitude * .pi / 180)
        let horizontalError = hypot(northError, eastError)
        let verticalError = target.point.altitudeMeters - pose.altitudeMeters
        let headingError = wrapDegrees(target.headingDegrees - pose.headingDegrees)
        let reached = horizontalError <= horizontalToleranceMeters
            && abs(verticalError) <= verticalToleranceMeters
            && abs(headingError) <= headingToleranceDegrees
        if reached {
            return .init(reached: true, horizontalErrorMeters: horizontalError,
                         verticalErrorMeters: verticalError, forwardMetersPerSecond: 0,
                         rightMetersPerSecond: 0, upMetersPerSecond: 0, yawRateDegreesPerSecond: 0)
        }
        let heading = pose.headingDegrees * .pi / 180
        var forward = (northError * cos(heading) + eastError * sin(heading)) * 0.55
        var right = (-northError * sin(heading) + eastError * cos(heading)) * 0.55
        // Match Android V5: transit/recovery legs rotate toward the target
        // before translating. Without this gate the aircraft yaws and applies
        // body-right velocity at the same time, visibly side-slipping toward
        // the route start.
        if alignHeadingBeforeHorizontalMotion,
           abs(headingError) > headingToleranceDegrees {
            forward = 0
            right = 0
        }
        let horizontalSpeed = hypot(forward, right)
        if horizontalSpeed > maximumHorizontalSpeedMetersPerSecond {
            let scale = maximumHorizontalSpeedMetersPerSecond / horizontalSpeed
            forward *= scale; right *= scale
        }
        return .init(
            reached: false, horizontalErrorMeters: horizontalError, verticalErrorMeters: verticalError,
            forwardMetersPerSecond: forward, rightMetersPerSecond: right,
            upMetersPerSecond: min(max(verticalError * 0.5, -maximumVerticalSpeedMetersPerSecond), maximumVerticalSpeedMetersPerSecond),
            yawRateDegreesPerSecond: min(max(headingError * 0.8, -maxYawRateDegreesPerSecond), maxYawRateDegreesPerSecond)
        )
    }

    private static func wrapDegrees(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { wrapped -= 360 }
        if wrapped < -180 { wrapped += 360 }
        return wrapped
    }
}

enum SurveyFailsafeAction: Equatable { case `continue`, pauseZeroAndRelease, abortZeroAndRelease }
struct SurveyFailsafeDecision: Equatable { var action: SurveyFailsafeAction; var reason: String? }

enum SurveyExecutionWatchdog {
    static func inspect(state: SurveyExecutionState, gate: SurveyExecutionGateResult,
                        trustedDJITelemetry: Bool, nowElapsedMillis: Int64,
                        waypointDeadlineElapsedMillis: Int64) -> SurveyFailsafeDecision {
        guard state == .running else { return .init(action: .continue, reason: nil) }
        guard trustedDJITelemetry else {
            // A DJI link dropout is recoverable in the mobile runtime: zero,
            // release control and retain the checkpoint for an explicit resume.
            return .init(action: .pauseZeroAndRelease, reason: "untrusted DJI telemetry")
        }
        guard gate.allowed else {
            return .init(action: .pauseZeroAndRelease,
                         reason: "runtime gate: \(gate.blocks.map(\.rawValue).sorted().joined(separator: ","))")
        }
        guard waypointDeadlineElapsedMillis > 0, nowElapsedMillis < waypointDeadlineElapsedMillis else {
            return .init(action: .pauseZeroAndRelease, reason: "waypoint tracking timeout")
        }
        return .init(action: .continue, reason: nil)
    }
}

enum SurveyLowBatteryPolicy {
    static let autoReturnThresholdPercent = 20
    static let autoReturnCountdownMillis: Int64 = 5_000

    static func shouldTrigger(batteryPercent: Int, aircraftFlying: Bool, simulatorActive: Bool,
                              executionState: SurveyExecutionState?) -> Bool {
        (0..<autoReturnThresholdPercent).contains(batteryPercent) && aircraftFlying && !simulatorActive
            && [.arming, .running, .paused].contains(executionState)
    }
}

enum SurveyExternalInterventionPolicy {
    static func reason(mode: AircraftFlightMode, smartReturnToHomeState: String?,
                       locallyInitiatedReturnHome: Bool = false) -> String? {
        let smartRTH = smartReturnToHomeState?.uppercased() ?? "UNKNOWN"
        if !locallyInitiatedReturnHome,
           smartRTH == "COUNTING_DOWN" || smartRTH == "EXECUTED" {
            return "检测到 DJI 智能低电量返航：\(smartRTH)"
        }
        switch mode {
        case .returningHome:
            return locallyInitiatedReturnHome ? nil : "检测到 DJI/遥控器返航介入"
        case .landing: return "检测到 DJI/遥控器降落介入"
        case .emergency: return "检测到 DJI 飞控保护介入"
        default: return nil
        }
    }
}

enum SurveyCaptureSourcePolicy {
    static func usesHILVirtualFrame(hilVirtualFramesEnabled: Bool,
                                    simulatorActive: Bool) -> Bool {
        hilVirtualFramesEnabled && simulatorActive
    }
}

enum SurveyGimbalSettlePolicy {
    static let toleranceDegrees = 3.0
    static let minimumSettleAfterAcceptanceMillis: Int64 = 1_200
    static let retryIntervalMillis: Int64 = 2_000
    static let timeoutMillis: Int64 = 20_000

    static func errorDegrees(targetPitchDegrees: Double, actualPitchDegrees: Double) -> Double {
        abs(targetPitchDegrees - actualPitchDegrees)
    }
    static func isSettled(targetPitchDegrees: Double, actualPitchDegrees: Double) -> Bool {
        errorDegrees(targetPitchDegrees: targetPitchDegrees, actualPitchDegrees: actualPitchDegrees) <= toleranceDegrees
    }

    static func isVerifiedForCapture(targetPitchDegrees: Double, actualPitchDegrees: Double,
                                     commandAcceptedElapsedMillis: Int64,
                                     nowElapsedMillis: Int64) -> Bool {
        commandAcceptedElapsedMillis > 0 && nowElapsedMillis >= commandAcceptedElapsedMillis
            && nowElapsedMillis - commandAcceptedElapsedMillis >= minimumSettleAfterAcceptanceMillis
            && isSettled(targetPitchDegrees: targetPitchDegrees,
                         actualPitchDegrees: actualPitchDegrees)
    }
    static func updateUnsettledSince(nowElapsedMillis: Int64, unsettledSinceElapsedMillis: Int64,
                                     settled: Bool) -> Int64 {
        if settled { return 0 }
        return unsettledSinceElapsedMillis > 0 ? unsettledSinceElapsedMillis : nowElapsedMillis
    }
    static func shouldRetry(nowElapsedMillis: Int64, lastCommandElapsedMillis: Int64) -> Bool {
        lastCommandElapsedMillis <= 0 || nowElapsedMillis - lastCommandElapsedMillis >= retryIntervalMillis
    }
    static func hasTimedOut(nowElapsedMillis: Int64, settlingStartedElapsedMillis: Int64) -> Bool {
        settlingStartedElapsedMillis > 0 && nowElapsedMillis - settlingStartedElapsedMillis >= timeoutMillis
    }
}

enum SurveyETAPolicy {
    static let captureOnReachSeconds = 2.0

    static func captureDelaySeconds(for action: SurveyCaptureAction) -> Double {
        action == .captureOnReach ? captureOnReachSeconds : 0
    }
}
