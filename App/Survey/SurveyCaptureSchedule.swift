import Foundation

struct SurveyCaptureEvent: Codable, Equatable {
    var captureIndex: Int
    var point: SurveyGeoPoint
    var headingDegrees: Double
    var gimbalPitchDegrees: Double
    var passIndex: Int
    var captureView: SurveyCaptureView
    var distanceAlongPassMeters: Double
    var passLengthMeters: Double
    var estimatedMissionDistanceMeters: Double
}

enum SurveyCaptureSchedule {
    static func build(_ mission: SurveyMission) throws -> [SurveyCaptureEvent] {
        var result: [SurveyCaptureEvent] = []
        var missionDistance = 0.0
        var previousEnd: SurveyGeoPoint?
        for pass in try mission.surveyPasses() {
            if let previousEnd { missionDistance += distance(previousEnd, pass.start.point) }
            if pass.isTransitOnly {
                missionDistance += zip(pass.waypoints, pass.waypoints.dropFirst()).reduce(0) {
                    $0 + distance($1.0.point, $1.1.point)
                }
                previousEnd = pass.end.point
                continue
            }
            if pass.isPointCapture {
                let start = pass.start
                result.append(.init(captureIndex: result.count, point: start.point,
                    headingDegrees: start.headingDegrees, gimbalPitchDegrees: start.gimbalPitchDegrees,
                    passIndex: start.passIndex, captureView: start.captureView,
                    distanceAlongPassMeters: 0, passLengthMeters: 0,
                    estimatedMissionDistanceMeters: missionDistance))
                previousEnd = start.point
                continue
            }
            let lengths = zip(pass.waypoints, pass.waypoints.dropFirst()).map { distance($0.point, $1.point) }
            let passLength = lengths.reduce(0, +)
            guard let interval = pass.start.captureIntervalMeters else { continue }
            let count = max(2, Int(ceil(passLength / interval)) + 1)
            for sample in 0..<count {
                let along = Double(sample) / Double(count - 1) * passLength
                result.append(.init(captureIndex: result.count,
                    point: pointAlong(pass.waypoints, lengths: lengths, distance: along),
                    headingDegrees: headingAlong(pass.waypoints, lengths: lengths, distance: along),
                    gimbalPitchDegrees: pitchAlong(pass.waypoints, lengths: lengths, distance: along),
                    passIndex: pass.start.passIndex, captureView: pass.start.captureView,
                    distanceAlongPassMeters: along, passLengthMeters: passLength,
                    estimatedMissionDistanceMeters: missionDistance + along))
            }
            missionDistance += passLength
            previousEnd = pass.end.point
        }
        guard result.count == mission.estimatedPhotoCount else {
            throw SurveyValidationError.invalid("capture schedule \(result.count) does not match planner estimate \(mission.estimatedPhotoCount)")
        }
        return result
    }

    private static func segmentAndRatio(_ lengths: [Double], distance target: Double) -> (Int, Double)? {
        var remaining = target
        for index in lengths.indices {
            let length = lengths[index]
            if remaining <= length || index == lengths.indices.last {
                return (index, length <= 1e-9 ? 0 : min(1, max(0, remaining / length)))
            }
            remaining -= length
        }
        return nil
    }

    private static func headingAlong(_ points: [SurveyWaypoint], lengths: [Double], distance: Double) -> Double {
        guard let (index, ratio) = segmentAndRatio(lengths, distance: distance) else { return points.last!.headingDegrees }
        let start = points[index].headingDegrees
        let delta = (points[index + 1].headingDegrees - start + 540).truncatingRemainder(dividingBy: 360) - 180
        return (start + delta * ratio + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func pitchAlong(_ points: [SurveyWaypoint], lengths: [Double], distance: Double) -> Double {
        guard let (index, ratio) = segmentAndRatio(lengths, distance: distance) else { return points.last!.gimbalPitchDegrees }
        return points[index].gimbalPitchDegrees
            + (points[index + 1].gimbalPitchDegrees - points[index].gimbalPitchDegrees) * ratio
    }

    private static func pointAlong(_ points: [SurveyWaypoint], lengths: [Double], distance target: Double) -> SurveyGeoPoint {
        var remaining = target
        for index in lengths.indices {
            let length = lengths[index]
            if remaining <= length || index == lengths.indices.last {
                let ratio = length <= 1e-9 ? 0 : min(1, max(0, remaining / length))
                let a = points[index].point, b = points[index + 1].point
                return .init(latitude: a.latitude + (b.latitude - a.latitude) * ratio,
                             longitude: a.longitude + (b.longitude - a.longitude) * ratio,
                             altitudeMeters: a.altitudeMeters + (b.altitudeMeters - a.altitudeMeters) * ratio)
            }
            remaining -= length
        }
        return points.last!.point
    }

    static func distance(_ a: SurveyGeoPoint, _ b: SurveyGeoPoint) -> Double {
        let meanLatitude = (a.latitude + b.latitude) * .pi / 360
        return hypot((b.latitude - a.latitude) * 111_132,
                     (b.longitude - a.longitude) * 111_320 * cos(meanLatitude))
    }
}

enum SurveyCaptureScheduleJSON {
    static func encode(mission: SurveyMission, events: [SurveyCaptureEvent]) throws -> String {
        let missionData = try JSONSerialization.jsonObject(with: Data(SurveyMissionJSON.encode(mission).utf8))
        let captures: [[String: Any]] = events.map { event in
            ["capture_index": event.captureIndex, "latitude": event.point.latitude,
             "longitude": event.point.longitude, "altitude_m": event.point.altitudeMeters,
             "heading_deg": event.headingDegrees, "gimbal_pitch_deg": event.gimbalPitchDegrees,
             "pass_index": event.passIndex, "capture_view": event.captureView.rawValue,
             "distance_along_pass_m": event.distanceAlongPassMeters,
             "pass_length_m": event.passLengthMeters,
             "estimated_mission_distance_m": event.estimatedMissionDistanceMeters]
        }
        let root: [String: Any] = ["schema_version": 1, "mission": missionData, "capture_events": captures]
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
                      as: UTF8.self)
    }
}
