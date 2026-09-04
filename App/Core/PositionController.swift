import Foundation

struct VelocityModelStateEstimator {
    private var startHeadingDegrees: Double?
    private var currentHeadingDegrees = 0.0
    private var northMeters = 0.0
    private var eastMeters = 0.0
    private var upMeters = 0.0
    private var lastTimestamp: Date?
    private var lastVelocity: (north: Double, east: Double, up: Double)?

    mutating func update(_ telemetry: FlightTelemetry) {
        let timestamp = telemetry.flightStateTimestamp
        let velocity = (telemetry.velocityNorth, telemetry.velocityEast, telemetry.verticalSpeed)
        guard [velocity.0, velocity.1, velocity.2, telemetry.heading].allSatisfy(\.isFinite) else { return }
        if startHeadingDegrees == nil { startHeadingDegrees = telemetry.heading }
        currentHeadingDegrees = telemetry.heading
        defer {
            lastTimestamp = timestamp
            lastVelocity = velocity
        }
        guard let previousTimestamp = lastTimestamp, let previousVelocity = lastVelocity else { return }
        let dt = timestamp.timeIntervalSince(previousTimestamp)
        guard dt > 0, dt <= 1.0 else { return }
        northMeters += (previousVelocity.north + velocity.0) * 0.5 * dt
        eastMeters += (previousVelocity.east + velocity.1) * 0.5 * dt
        upMeters += (previousVelocity.up + velocity.2) * 0.5 * dt
    }

    mutating func reset() {
        self = VelocityModelStateEstimator()
    }

    var modelState: [Double] {
        guard let startHeadingDegrees else { return [0, 0, 0, 0] }
        let yaw = startHeadingDegrees * .pi / 180
        let forward = northMeters * cos(yaw) + eastMeters * sin(yaw)
        let right = -northMeters * sin(yaw) + eastMeters * cos(yaw)
        let delta = OrinTrajectorySemantics.wrappedDegrees(currentHeadingDegrees - startHeadingDegrees) * .pi / 180
        return [forward, right, upMeters, delta]
    }
}

enum OrinTrajectorySemantics {
    static func yawDeltaDegrees(forward: Double, right: Double) -> Double {
        guard forward.isFinite, right.isFinite,
              hypot(forward, right) >= 0.05, abs(forward) > 1e-6 else { return 0 }
        return atan2(right, forward) * 180 / .pi
    }

    static func targetHeading(start: Double, forward: Double, right: Double) -> Double {
        normalizedHeading(start + yawDeltaDegrees(forward: forward, right: right))
    }

    static func flyThroughRadius(segmentDistance: Double) -> Double {
        min(max(max(0, segmentDistance) * 0.25, 0.12), 0.8)
    }

    static func flyThroughTimeout(segmentDistance: Double) -> TimeInterval {
        8 + max(0, segmentDistance) * 4
    }

    static func wrappedDegrees(_ value: Double) -> Double {
        ((value + 540).truncatingRemainder(dividingBy: 360)) - 180
    }

    static func normalizedHeading(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 360)
        return result < 0 ? result + 360 : result
    }
}

struct VelocityCommandSlewLimiter {
    var maximumHorizontalAcceleration = 0.8
    var maximumVerticalAcceleration = 0.5
    var maximumYawAcceleration = 45.0

    private(set) var current = VelocityCommand.zero
    private var lastTimestamp: Date?

    init(
        maximumHorizontalAcceleration: Double = 0.8,
        maximumVerticalAcceleration: Double = 0.5,
        maximumYawAcceleration: Double = 30.0
    ) {
        self.maximumHorizontalAcceleration = maximumHorizontalAcceleration
        self.maximumVerticalAcceleration = maximumVerticalAcceleration
        self.maximumYawAcceleration = maximumYawAcceleration
    }

    mutating func reset(at timestamp: Date = Date()) {
        current = .zero
        lastTimestamp = timestamp
    }

    mutating func limit(_ target: VelocityCommand, at timestamp: Date) -> VelocityCommand {
        let rawDelta = lastTimestamp.map { timestamp.timeIntervalSince($0) } ?? 0.05
        let delta = min(max(rawDelta, 0.05), 0.25)

        var forwardDelta = target.forward - current.forward
        var rightDelta = target.right - current.right
        let horizontalDelta = hypot(forwardDelta, rightDelta)
        let maximumHorizontalDelta = maximumHorizontalAcceleration * delta
        if horizontalDelta > maximumHorizontalDelta {
            let scale = maximumHorizontalDelta / horizontalDelta
            forwardDelta *= scale
            rightDelta *= scale
        }

        current = VelocityCommand(
            forward: current.forward + forwardDelta,
            right: current.right + rightDelta,
            up: approached(current.up, target.up, maximumDelta: maximumVerticalAcceleration * delta),
            yawRate: approached(current.yawRate, target.yawRate, maximumDelta: maximumYawAcceleration * delta)
        )
        lastTimestamp = timestamp
        return current
    }

    private func approached(_ current: Double, _ target: Double, maximumDelta: Double) -> Double {
        current + min(max(target - current, -maximumDelta), maximumDelta)
    }
}

struct PositionController {
    var horizontalGain = 0.8
    var verticalGain = 0.7
    var yawGain = 0.9
    var maxHorizontal = 4.0
    var maxVertical = 1.0
    var maxYawRate = 45.0

    func command(for action: RelativeAction) -> VelocityCommand {
        VelocityCommand(
            forward: clamp(action.forwardMeters * horizontalGain, maxHorizontal),
            right: clamp(action.rightMeters * horizontalGain, maxHorizontal),
            up: clamp(action.upMeters * verticalGain, maxVertical),
            yawRate: clamp(action.yawDegrees * yawGain, maxYawRate)
        )
    }

    private func clamp(_ value: Double, _ magnitude: Double) -> Double {
        min(max(value, -magnitude), magnitude)
    }
}

/// Executes one model-relative position target with either geographic feedback or
/// short-term dead reckoning from DJI's NED velocity telemetry.
final class RelativePositionClosedLoop {
    struct Step: Equatable {
        var command: VelocityCommand
        var terminal: Bool
        var successful: Bool
        var reason: String
        var horizontalErrorMeters: Double
        var verticalErrorMeters: Double
        var residualNorthMeters: Double = 0
        var residualEastMeters: Double = 0
        var residualUpMeters: Double = 0
    }

    enum StartError: LocalizedError {
        case invalidTarget(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case let .invalidTarget(message), let .unavailable(message): return message
            }
        }
    }

    private struct Target {
        var mode: PositionClosureMode
        var startLocation: GeoPoint
        var targetNorthMeters: Double
        var targetEastMeters: Double
        var targetUpMeters: Double
        var targetHeadingDegrees: Double?
        var maximumHorizontalSpeed: Double
        var requiresSimulator: Bool
        var deadline: Date
        var hasFollowingStep: Bool
        var flyThroughRadiusMeters: Double?
    }

    private var target: Target?
    private var estimatedNorthMeters = 0.0
    private var estimatedEastMeters = 0.0
    private var estimatedUpMeters = 0.0
    private var verticalCompleted = true
    private var lastVelocityTimestamp: Date?
    private var lastVelocityCommand = VelocityCommand.zero

    var isActive: Bool { target != nil }

    func start(
        action: RelativeAction,
        telemetry: FlightTelemetry,
        mode: PositionClosureMode,
        maximumHorizontalSpeed: Double = 1.0,
        referenceHeadingDegrees: Double? = nil,
        carryNorthMeters: Double = 0,
        carryEastMeters: Double = 0,
        carryUpMeters: Double = 0,
        hasFollowingStep: Bool = false,
        flyThroughEnabled: Bool = false,
        now: Date = Date()
    ) throws -> Step {
        let values = [action.forwardMeters, action.rightMeters, action.upMeters, action.yawDegrees]
        guard values.allSatisfy(\.isFinite) else { throw StartError.invalidTarget("模型位置目标包含无效数值") }
        let planar = hypot(action.forwardMeters, action.rightMeters)
        guard planar <= 10, abs(action.upMeters) <= 0.5, abs(action.yawDegrees) <= 180 else {
            throw StartError.invalidTarget("模型位置目标超出单步安全范围")
        }
        if action.upMeters < -0.05 {
            let currentHeight = telemetry.downwardHeightValid ? telemetry.downwardHeight : telemetry.altitude
            guard currentHeight.isFinite, currentHeight + action.upMeters >= 0.8 else {
                throw StartError.unavailable("垂直下降目标低于 0.8m 安全高度")
            }
        }
        try validateTelemetry(telemetry, mode: mode, now: now)

        let referenceHeading = referenceHeadingDegrees ?? telemetry.heading
        let heading = referenceHeading * .pi / 180
        let targetNorth = action.forwardMeters * cos(heading) - action.rightMeters * sin(heading) + carryNorthMeters
        let targetEast = action.forwardMeters * sin(heading) + action.rightMeters * cos(heading) + carryEastMeters
        let targetUp = action.upMeters + carryUpMeters
        let targetHeading = abs(action.yawDegrees) >= 0.5
            ? OrinTrajectorySemantics.normalizedHeading(referenceHeading + action.yawDegrees) : nil
        // The user-selected 0.2–4.0 m/s value is the only horizontal speed
        // ceiling. GPS changes the feedback/tolerance, not the chosen limit.
        let requestedMaximum = min(max(maximumHorizontalSpeed, 0.2), 4.0)
        let effectiveMaximum = requestedMaximum
        let horizontalTravel = planar / max(effectiveMaximum * 0.7, 0.15)
        let verticalTravel = abs(action.upMeters) / 0.14
        let expectedTravel = flyThroughEnabled && hasFollowingStep
            ? OrinTrajectorySemantics.flyThroughTimeout(segmentDistance: planar)
            : min(20.0, max(3.0, 2.0 + max(horizontalTravel, verticalTravel)))
        target = Target(
            mode: mode,
            startLocation: telemetry.aircraft,
            targetNorthMeters: targetNorth,
            targetEastMeters: targetEast,
            targetUpMeters: targetUp,
            targetHeadingDegrees: targetHeading,
            maximumHorizontalSpeed: requestedMaximum,
            requiresSimulator: telemetry.simulatorActive,
            deadline: now.addingTimeInterval(expectedTravel),
            hasFollowingStep: hasFollowingStep,
            flyThroughRadiusMeters: flyThroughEnabled && hasFollowingStep
                ? OrinTrajectorySemantics.flyThroughRadius(segmentDistance: planar) : nil
        )
        estimatedNorthMeters = 0
        estimatedEastMeters = 0
        estimatedUpMeters = 0
        verticalCompleted = abs(targetUp) <= 0.05
        lastVelocityTimestamp = telemetry.timestamp
        lastVelocityCommand = .zero
        return step(telemetry: telemetry, now: now)
    }

    func step(telemetry: FlightTelemetry, now: Date = Date()) -> Step {
        guard let target else { return terminal("没有活动的位置目标", successful: false) }
        do {
            try validateTelemetry(telemetry, mode: target.mode, now: now)
        } catch {
            cancel()
            return terminal(error.localizedDescription, successful: false)
        }
        if target.requiresSimulator && !telemetry.simulatorActive {
            cancel()
            return terminal("DJI 仿真位置源已退出", successful: false)
        }
        integrateVelocity(
            telemetry,
            includeHorizontal: target.mode == .velocityEstimate,
            includeVertical: !verticalCompleted
        )
        let displacement: (north: Double, east: Double)
        switch target.mode {
        case .gps:
            displacement = geographicDisplacement(from: target.startLocation, to: telemetry.aircraft)
        case .velocityEstimate:
            displacement = (estimatedNorthMeters, estimatedEastMeters)
        }

        let northError = target.targetNorthMeters - displacement.north
        let eastError = target.targetEastMeters - displacement.east
        let horizontalError = hypot(northError, eastError)
        let verticalError = target.targetUpMeters - estimatedUpMeters
        let heading = telemetry.heading * .pi / 180
        let forwardError = northError * cos(heading) + eastError * sin(heading)
        let rightError = -northError * sin(heading) + eastError * cos(heading)
        let yawError = target.targetHeadingDegrees.map { shortestAngle($0 - telemetry.heading) } ?? 0

        guard now < target.deadline else {
            cancel()
            return terminal("位置动作超时", successful: false, horizontalError: horizontalError, verticalError: verticalError)
        }

        let highPrecisionGPS = target.mode == .gps && telemetry.simulatorActive
        let baseTolerance = target.mode == .velocityEstimate ? 0.25 : (highPrecisionGPS ? 0.15 : 0.8)
        let tolerance = target.flyThroughRadiusMeters.map {
            target.mode == .gps ? max(baseTolerance, $0) : $0
        } ?? baseTolerance
        if !verticalCompleted,
           abs(verticalError) <= 0.10,
           abs(telemetry.verticalSpeed) <= 0.12 {
            verticalCompleted = true
        }
        if horizontalError <= tolerance && verticalCompleted && abs(yawError) <= 4 {
            cancel()
            return terminal(
                "位置目标已到达",
                successful: true,
                horizontalError: horizontalError,
                verticalError: verticalError,
                residualNorth: northError,
                residualEast: eastError,
                residualUp: verticalError
            )
        }

        let kp: Double
        let maximumHorizontalSpeed: Double
        switch target.mode {
        case .gps:
            kp = highPrecisionGPS ? 1.0 : 0.6
            maximumHorizontalSpeed = target.maximumHorizontalSpeed
        case .velocityEstimate:
            kp = 0.8
            maximumHorizontalSpeed = target.maximumHorizontalSpeed
        }
        var forward = clamped(forwardError * kp, magnitude: maximumHorizontalSpeed)
        var right = clamped(rightError * kp, magnitude: maximumHorizontalSpeed)
        let horizontalCommand = hypot(forward, right)
        if horizontalCommand > maximumHorizontalSpeed {
            let scale = maximumHorizontalSpeed / horizontalCommand
            forward *= scale
            right *= scale
        }
        if target.hasFollowingStep, horizontalCommand > 1e-6 {
            let throughSpeed = min(maximumHorizontalSpeed, max(0.2, telemetry.horizontalSpeed))
            if hypot(forward, right) < throughSpeed {
                let scale = throughSpeed / hypot(forward, right)
                forward *= scale
                right *= scale
            }
        }
        let verticalCommand: Double
        if verticalCompleted || abs(verticalError) <= 0.10 {
            verticalCommand = 0
        } else {
            let proportional = clamped(verticalError * 0.7, magnitude: 0.2)
            // DJI's reported vertical velocity can quantize to zero below roughly
            // 0.1 m/s. Stay above that deadband, then command zero to brake.
            verticalCommand = verticalError.sign == .minus
                ? -max(abs(proportional), 0.12)
                : max(abs(proportional), 0.12)
        }
        let command = VelocityCommand(
            forward: forward,
            right: right,
            // Model z is a relative displacement. Integrate DJI's measured vertical
            // velocity while moving, then return to zero for onboard altitude hold.
            up: verticalCommand,
            yawRate: clamped(yawError, magnitude: 20)
        )
        lastVelocityCommand = command
        return Step(
            command: command,
            terminal: false,
            successful: false,
            reason: "\(target.mode.shortLabel) 平面\(String(format: "%.2f", horizontalError))m 垂直\(String(format: "%.2f", verticalError))m",
            horizontalErrorMeters: horizontalError,
            verticalErrorMeters: verticalError
        )
    }

    func cancel() {
        target = nil
        lastVelocityTimestamp = nil
        estimatedNorthMeters = 0
        estimatedEastMeters = 0
        estimatedUpMeters = 0
        verticalCompleted = true
        lastVelocityCommand = .zero
    }

    private func validateTelemetry(_ telemetry: FlightTelemetry, mode: PositionClosureMode, now: Date) throws {
        guard telemetry.connected else { throw StartError.unavailable("飞行器连接丢失") }
        guard now.timeIntervalSince(telemetry.timestamp) >= 0,
              now.timeIntervalSince(telemetry.timestamp) <= 0.75 else {
            throw StartError.unavailable("位置遥测已过期")
        }
        guard telemetry.altitude.isFinite, telemetry.heading.isFinite,
              telemetry.verticalSpeed.isFinite else {
            throw StartError.unavailable("高度或航向遥测无效")
        }
        switch mode {
        case .gps:
            guard telemetry.aircraftLocationValid,
                  telemetry.aircraft.latitude.isFinite,
                  telemetry.aircraft.longitude.isFinite,
                  abs(telemetry.aircraft.latitude) > 0.000001 || abs(telemetry.aircraft.longitude) > 0.000001 else {
                throw StartError.unavailable("没有有效 GPS 位置，请切换速度积分估算")
            }
        case .velocityEstimate:
            guard telemetry.horizontalSpeed.isFinite, telemetry.horizontalSpeed >= 0 else {
                throw StartError.unavailable("飞控水平速度遥测无效")
            }
        }
    }

    private func integrateVelocity(
        _ telemetry: FlightTelemetry,
        includeHorizontal: Bool,
        includeVertical: Bool
    ) {
        guard let lastVelocityTimestamp else {
            self.lastVelocityTimestamp = telemetry.timestamp
            return
        }
        let rawDelta = telemetry.timestamp.timeIntervalSince(lastVelocityTimestamp)
        guard rawDelta > 0 else { return }
        let delta = min(rawDelta, 0.25)
        if includeVertical {
            let measuredUpSpeed = abs(telemetry.verticalSpeed) < 0.03
                ? 0
                : clamped(telemetry.verticalSpeed, magnitude: 2.0)
            estimatedUpMeters += measuredUpSpeed * delta
        }

        let bodyMagnitude = hypot(lastVelocityCommand.forward, lastVelocityCommand.right)
        if includeHorizontal, bodyMagnitude > 0.01, telemetry.horizontalSpeed > 0.01 {
            let bodyForward = lastVelocityCommand.forward / bodyMagnitude
            let bodyRight = lastVelocityCommand.right / bodyMagnitude
            let heading = telemetry.heading * .pi / 180
            let northDirection = bodyForward * cos(heading) - bodyRight * sin(heading)
            let eastDirection = bodyForward * sin(heading) + bodyRight * cos(heading)
            estimatedNorthMeters += telemetry.horizontalSpeed * northDirection * delta
            estimatedEastMeters += telemetry.horizontalSpeed * eastDirection * delta
        }
        self.lastVelocityTimestamp = telemetry.timestamp
    }

    private func geographicDisplacement(from start: GeoPoint, to current: GeoPoint) -> (north: Double, east: Double) {
        let earthRadius = 6_378_137.0
        let north = (current.latitude - start.latitude) * .pi / 180 * earthRadius
        let meanLatitude = (current.latitude + start.latitude) * 0.5 * .pi / 180
        let east = (current.longitude - start.longitude) * .pi / 180 * earthRadius * cos(meanLatitude)
        return (north, east)
    }

    private func terminal(
        _ reason: String,
        successful: Bool,
        horizontalError: Double = 0,
        verticalError: Double = 0,
        residualNorth: Double = 0,
        residualEast: Double = 0,
        residualUp: Double = 0
    ) -> Step {
        Step(
            command: .zero,
            terminal: true,
            successful: successful,
            reason: reason,
            horizontalErrorMeters: horizontalError,
            verticalErrorMeters: verticalError,
            residualNorthMeters: residualNorth,
            residualEastMeters: residualEast,
            residualUpMeters: residualUp
        )
    }

    private func clamped(_ value: Double, magnitude: Double) -> Double {
        min(max(value, -magnitude), magnitude)
    }

    private func normalizedHeading(_ value: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: 360)
        return result < 0 ? result + 360 : result
    }

    private func shortestAngle(_ value: Double) -> Double {
        ((value + 540).truncatingRemainder(dividingBy: 360)) - 180
    }
}
