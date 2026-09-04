import Foundation

enum SurveyReplayState: String, Codable { case idle = "IDLE", running = "RUNNING", paused = "PAUSED", completed = "COMPLETED" }

struct SurveyReplaySnapshot: Equatable {
    var state: SurveyReplayState
    var point: SurveyGeoPoint
    var headingDegrees: Double
    var passIndex: Int
    var sampleIndex: Int
    var totalSamples: Int
    var progress: Double
    var captureActive: Bool
}

/// Deterministic preview only. It never emits aircraft, gimbal, or camera commands.
final class SurveyMissionReplay {
    private struct Sample {
        var point: SurveyGeoPoint
        var headingDegrees: Double
        var passIndex: Int
        var captureActive: Bool
    }

    let mission: SurveyMission
    private let samples: [Sample]
    private var cursor = 0
    private(set) var state: SurveyReplayState = .idle

    init(mission: SurveyMission, sampleSpacingMeters: Double = 2) throws {
        guard (0.2...100).contains(sampleSpacingMeters) else {
            throw SurveyValidationError.invalid("replay spacing must be in [0.2, 100] meters")
        }
        self.mission = mission
        samples = Self.buildSamples(mission: mission, spacingMeters: sampleSpacingMeters)
        guard !samples.isEmpty else { throw SurveyValidationError.invalid("mission has no replayable waypoints") }
    }

    @discardableResult func start() -> SurveyReplaySnapshot {
        if state == .completed { cursor = 0 }
        state = .running
        return snapshot()
    }

    @discardableResult func pause() -> SurveyReplaySnapshot { if state == .running { state = .paused }; return snapshot() }
    @discardableResult func resume() -> SurveyReplaySnapshot { if state == .paused { state = .running }; return snapshot() }
    @discardableResult func stop() -> SurveyReplaySnapshot { cursor = 0; state = .idle; return snapshot() }

    @discardableResult func advance() -> SurveyReplaySnapshot {
        guard state == .running else { return snapshot() }
        if cursor < samples.count - 1 { cursor += 1 } else { state = .completed }
        return snapshot()
    }

    func snapshot() -> SurveyReplaySnapshot {
        let sample = samples[cursor]
        return .init(
            state: state, point: sample.point, headingDegrees: sample.headingDegrees,
            passIndex: sample.passIndex, sampleIndex: cursor, totalSamples: samples.count,
            progress: samples.count <= 1 ? 1 : Double(cursor) / Double(samples.count - 1),
            captureActive: sample.captureActive
        )
    }

    private static func buildSamples(mission: SurveyMission, spacingMeters: Double) -> [Sample] {
        guard let first = mission.waypoints.first else { return [] }
        var active = first.captureAction == .startDistanceInterval
        var result = [Sample(point: first.point, headingDegrees: first.headingDegrees,
                             passIndex: first.passIndex, captureActive: active)]
        for index in 1..<mission.waypoints.count {
            let previous = mission.waypoints[index - 1]
            let waypoint = mission.waypoints[index]
            let steps = max(1, Int(ceil(distanceMeters(previous.point, waypoint.point) / spacingMeters)))
            for step in 1...steps {
                let ratio = Double(step) / Double(steps)
                result.append(.init(
                    point: interpolate(previous.point, waypoint.point, ratio),
                    headingDegrees: segmentHeading(previous.point, waypoint.point),
                    passIndex: waypoint.passIndex,
                    captureActive: active
                ))
            }
            switch waypoint.captureAction {
            case .startDistanceInterval: active = true
            case .stopDistanceInterval: active = false
            case .captureOnReach: break
            case .none: break
            }
        }
        return result
    }

    private static func interpolate(_ a: SurveyGeoPoint, _ b: SurveyGeoPoint, _ ratio: Double) -> SurveyGeoPoint {
        .init(latitude: a.latitude + (b.latitude - a.latitude) * ratio,
              longitude: a.longitude + (b.longitude - a.longitude) * ratio,
              altitudeMeters: a.altitudeMeters + (b.altitudeMeters - a.altitudeMeters) * ratio)
    }

    private static func distanceMeters(_ a: SurveyGeoPoint, _ b: SurveyGeoPoint) -> Double {
        let north = (b.latitude - a.latitude) * 111_132
        let east = (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        return hypot(north, east)
    }

    private static func segmentHeading(_ a: SurveyGeoPoint, _ b: SurveyGeoPoint) -> Double {
        let north = (b.latitude - a.latitude) * 111_132
        let east = (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let value = atan2(east, north) * 180 / .pi
        return value < 0 ? value + 360 : value
    }
}
