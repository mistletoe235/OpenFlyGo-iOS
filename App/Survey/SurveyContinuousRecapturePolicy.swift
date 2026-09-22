import Foundation

enum SurveyContinuousRecapturePolicy {
    static func eligible(_ mission: SurveyMission, index: Int) -> Bool {
        guard mission.recaptureFlightMode == .continuousExperimental,
              let mapping = mission.activeMapping, index > 0, index < mission.waypoints.count - 1 else { return false }
        let previous = mission.waypoints[index - 1]
        let target = mission.waypoints[index]
        let next = mission.waypoints[index + 1]
        let points = [previous, target, next]
        guard points.allSatisfy({
            $0.kind == .capturePoint && $0.captureAction == .captureOnReach && $0.captureView == target.captureView
        }) else { return false }
        if !mapping.passes.isEmpty {
            guard let group = mapping.passes.first(where: { $0.passIndex == target.passIndex }),
                  points.allSatisfy({ waypoint in
                      guard let entry = mapping.passes.first(where: { $0.passIndex == waypoint.passIndex }) else { return false }
                      return entry.regionID == group.regionID && entry.captureRole == "SURVEY"
                          && !entry.requiredForReconstructionBridge
                  }) else { return false }
        }
        return distance(previous.point, target.point) + 1e-6 >= 3
            && distance(target.point, next.point) + 1e-6 >= 3
            && angleDifference(bearing(previous.point, target.point), bearing(target.point, next.point)) <= 30
            && [previous, next].allSatisfy {
                angleDifference($0.headingDegrees, target.headingDegrees) <= 5
                    && abs($0.gimbalPitchDegrees - target.gimbalPitchDegrees) <= 3
                    && abs($0.point.altitudeMeters - target.point.altitudeMeters) <= 0.5
            }
    }

    static func poseReady(telemetry: FlightTelemetry, pose: SurveyFollowerPose,
                          target: SurveyWaypoint, now: Date = Date()) -> Bool {
        guard telemetry.connected, telemetry.aircraftLocationValid,
              let gimbalTime = telemetry.gimbalStateTimestamp else { return false }
        return (0...1).contains(now.timeIntervalSince(telemetry.flightStateTimestamp))
            && (0...1).contains(now.timeIntervalSince(gimbalTime))
            && angleDifference(pose.headingDegrees, target.headingDegrees) <= SurveyStoppedCapturePosePolicy.maxHeadingErrorDegrees
            && abs(pose.altitudeMeters - target.point.altitudeMeters) <= SurveyWaypointFollower.verticalToleranceMeters
            && SurveyGimbalSettlePolicy.isSettled(targetPitchDegrees: target.gimbalPitchDegrees,
                                                 actualPitchDegrees: telemetry.gimbalPitch)
    }

    static func missedWindow(_ mission: SurveyMission, index: Int, pose: SurveyFollowerPose) -> Bool {
        let previous = mission.waypoints[index - 1].point
        let target = mission.waypoints[index].point
        let incoming = offset(previous, target)
        let current = offset(previous, .init(latitude: pose.latitude, longitude: pose.longitude,
                                             altitudeMeters: pose.altitudeMeters))
        let length = hypot(incoming.north, incoming.east)
        return (current.north * incoming.north + current.east * incoming.east) / length
            > length + SurveyWaypointFollower.horizontalToleranceMeters
    }

    static func command(_ mission: SurveyMission, index: Int, pose: SurveyFollowerPose,
                        maximumSpeed: Double, maximumVerticalSpeed: Double) throws -> SurveyFollowerCommand {
        guard eligible(mission, index: index) else {
            throw SurveyValidationError.invalid("waypoint is not eligible for continuous recapture")
        }
        let previous = mission.waypoints[index - 1].point
        let target = mission.waypoints[index]
        let next = mission.waypoints[index + 1].point
        let incoming = offset(previous, target.point)
        let outgoing = offset(target.point, next)
        let incomingLength = hypot(incoming.north, incoming.east)
        let outgoingLength = hypot(outgoing.north, outgoing.east)
        let position = SurveyGeoPoint(latitude: pose.latitude, longitude: pose.longitude, altitudeMeters: pose.altitudeMeters)
        let before = offset(previous, position)
        let after = offset(target.point, position)
        let incomingProgress = (before.north * incoming.north + before.east * incoming.east) / incomingLength
        let progress = incomingProgress <= incomingLength ? incomingProgress : incomingLength
            + (after.north * outgoing.north + after.east * outgoing.east) / outgoingLength
        let speed = max(0.1, min(maximumSpeed, min(incomingLength, outgoingLength)
            / mission.cameraProfile.minimumCaptureIntervalSeconds * 0.7))
        let lookahead = max(2.5, speed / 0.55)
        let goalProgress = min(max(0, progress + lookahead), incomingLength + outgoingLength * 0.5)
        let fraction = goalProgress <= incomingLength ? goalProgress / incomingLength
            : (goalProgress - incomingLength) / outgoingLength
        let start = goalProgress <= incomingLength ? previous : target.point
        let end = goalProgress <= incomingLength ? target.point : next
        var goal = target
        goal.point = .init(latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                           longitude: start.longitude + (end.longitude - start.longitude) * fraction,
                           altitudeMeters: target.point.altitudeMeters)
        let capture = try SurveyWaypointFollower.command(pose: pose, target: target,
            maximumHorizontalSpeedMetersPerSecond: speed, maximumVerticalSpeedMetersPerSecond: maximumVerticalSpeed)
        var moving = try SurveyWaypointFollower.command(pose: pose, target: goal,
            maximumHorizontalSpeedMetersPerSecond: speed, maximumVerticalSpeedMetersPerSecond: maximumVerticalSpeed)
        moving.reached = capture.reached
        moving.horizontalErrorMeters = capture.horizontalErrorMeters
        moving.verticalErrorMeters = capture.verticalErrorMeters
        return moving
    }

    private static func offset(_ first: SurveyGeoPoint, _ second: SurveyGeoPoint) -> (north: Double, east: Double) {
        ((second.latitude - first.latitude) * 111_132,
         (second.longitude - first.longitude) * 111_320 * cos(first.latitude * .pi / 180))
    }

    private static func distance(_ first: SurveyGeoPoint, _ second: SurveyGeoPoint) -> Double {
        let delta = offset(first, second)
        return hypot(delta.north, delta.east)
    }

    private static func bearing(_ first: SurveyGeoPoint, _ second: SurveyGeoPoint) -> Double {
        let delta = offset(first, second)
        return atan2(delta.east, delta.north) * 180 / .pi
    }

    private static func angleDifference(_ first: Double, _ second: Double) -> Double {
        abs(((second - first).truncatingRemainder(dividingBy: 360) + 540)
            .truncatingRemainder(dividingBy: 360) - 180)
    }
}
