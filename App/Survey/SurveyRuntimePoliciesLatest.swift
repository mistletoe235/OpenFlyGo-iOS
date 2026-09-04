import Foundation

enum SurveyNadirGimbalPolicy {
    static func isMechanicalLimit(targetPitchDegrees: Double, settled: Bool, pitchAtStop: Bool) -> Bool {
        !settled && targetPitchDegrees <= -89 && pitchAtStop
    }
    static func shouldDeferCaptureStart(action: SurveyCaptureAction, mechanicalLimit: Bool) -> Bool {
        action == .startDistanceInterval && mechanicalLimit
    }
    static func canCapture(settled: Bool) -> Bool { settled }
    static func shouldSkipEndFrame(action: SurveyCaptureAction, settled: Bool) -> Bool {
        action == .stopDistanceInterval && !settled
    }
    static func canStartDeferredCapture(phase: SurveyExecutionPhase, settled: Bool,
                                        cameraReady: Bool) -> Bool {
        phase == .survey && settled && cameraReady
    }
}

enum SurveyRuntimeFaultPolicy {
    static func isTimeout(_ message: String?) -> Bool {
        let value = message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.contains("timeout") || value.contains("timed out") || value.contains("超时")
    }
    static func shouldPauseCameraAction(label: String?, ok: Bool, message: String?) -> Bool {
        !ok && label == "航测相机" && isTimeout(message)
    }
}

/// Stops a waypoint leg when closed-loop tracking is clearly moving away from
/// its target. This is intentionally independent of the much longer per-leg
/// timeout so a coordinate-frame regression cannot drive for tens or hundreds
/// of metres before control is released.
enum SurveyWaypointDivergencePolicy {
    static let minimumGrowthMeters = 12.0
    static let minimumDurationMillis: Int64 = 2_500

    static func shouldPause(bestErrorMeters: Double, currentErrorMeters: Double,
                            lastProgressElapsedMillis: Int64, nowElapsedMillis: Int64) -> Bool {
        bestErrorMeters.isFinite && currentErrorMeters.isFinite
            && currentErrorMeters >= bestErrorMeters + minimumGrowthMeters
            && nowElapsedMillis - lastProgressElapsedMillis >= minimumDurationMillis
    }
}

/// Only in-flight states represent a resumable interruption. Terminal states
/// must never be revived as a paused mission after process restart.
enum SurveyRuntimeCheckpointPolicy {
    static func canRestore(_ state: SurveyExecutionState) -> Bool {
        state == .arming || state == .running || state == .paused
    }
}

enum SurveyCaptureRecoveryPolicy {
    static func activeInterval(mission: SurveyMission, waypointIndex: Int,
                               phase: SurveyExecutionPhase?) -> Double? {
        guard phase == .survey else { return nil }
        var activeInterval: Double?
        for waypoint in mission.waypoints.prefix(max(0, min(waypointIndex, mission.waypoints.count))) {
            switch waypoint.captureAction {
            case .startDistanceInterval:
                activeInterval = waypoint.captureIntervalMeters
            case .stopDistanceInterval:
                activeInterval = nil
            case .captureOnReach:
                break
            case .none:
                break
            }
        }
        return activeInterval
    }

    /// Schema 1...3 did not persist whether a nadir strip had actually begun
    /// capturing. If that state is ambiguous, replay the strip from its START
    /// rather than silently resuming midway with missing imagery.
    static func legacySafeWaypointIndex(mission: SurveyMission, waypointIndex: Int,
                                        phase: SurveyExecutionPhase?) -> Int? {
        guard activeInterval(mission: mission, waypointIndex: waypointIndex, phase: phase) != nil else {
            return nil
        }
        let upperBound = max(0, min(waypointIndex, mission.waypoints.count))
        return mission.waypoints[..<upperBound].lastIndex {
            $0.captureAction == .startDistanceInterval
        }
    }
}

struct SurveyCaptureCheckpointRecoveryDecision: Equatable {
    var waypointIndex: Int
    var executionLegIndex: Int?
    var recoveryPoint: SurveyGeoPoint?
    var activeCaptureIntervalMeters: Double?
    var pendingCaptureStartWaypointIndex: Int?
    var rewoundToStripStart: Bool
}

/// Reconciles execution-position recovery with capture-controller recovery.
/// A restart without a precise pause point cannot prove continuous coverage,
/// so an open strip is replayed from START with capture inactive.
enum SurveyCaptureCheckpointRecoveryPolicy {
    static func decide(
        mission: SurveyMission,
        checkpoint: SurveyExecutionCheckpoint,
        basePosition: SurveyRecoveryPosition,
        baseTargetPassIndex: Int,
        baseMissionWaypointIndex: Int?
    ) throws -> SurveyCaptureCheckpointRecoveryDecision {
        let candidateStart = SurveyCaptureRecoveryPolicy.legacySafeWaypointIndex(
            mission: mission, waypointIndex: checkpoint.waypointIndex, phase: checkpoint.phase
        )
        let openStart: Int? = candidateStart.flatMap { index -> Int? in
            guard baseMissionWaypointIndex != nil else { return nil }
            return mission.waypoints.indices.contains(index)
                && mission.waypoints[index].passIndex == baseTargetPassIndex ? index : nil
        }
        let recordedActive = checkpoint.activeCaptureIntervalMeters
        let recordedPending = checkpoint.pendingCaptureStartWaypointIndex
        let recordedStateValid: Bool
        if let openStart {
            let expectedInterval = mission.waypoints[openStart].captureIntervalMeters
            let activeMatches = recordedActive.flatMap { active in
                expectedInterval.map { abs($0 - active) <= 1e-6 }
            } == true && recordedPending == nil
            let pendingMatches = recordedPending == openStart && recordedActive == nil
            recordedStateValid = activeMatches || pendingMatches
        } else {
            recordedStateValid = recordedActive == nil && recordedPending == nil
        }

        if checkpoint.captureStateRecorded, !recordedStateValid {
            guard let openStart else {
                throw SurveyValidationError.invalid("checkpoint capture state does not match the current strip")
            }
            return rewind(to: openStart)
        }
        if let openStart,
           (!checkpoint.captureStateRecorded
                || checkpoint.recoveryPoint == nil
                || basePosition.waypointIndex != checkpoint.waypointIndex) {
            return rewind(to: openStart)
        }
        return .init(
            waypointIndex: basePosition.waypointIndex,
            executionLegIndex: basePosition.executionLegIndex,
            recoveryPoint: checkpoint.recoveryPoint,
            activeCaptureIntervalMeters: checkpoint.captureStateRecorded ? recordedActive : nil,
            pendingCaptureStartWaypointIndex: checkpoint.captureStateRecorded ? recordedPending : nil,
            rewoundToStripStart: false
        )
    }

    private static func rewind(to waypointIndex: Int) -> SurveyCaptureCheckpointRecoveryDecision {
        .init(waypointIndex: waypointIndex, executionLegIndex: nil, recoveryPoint: nil,
              activeCaptureIntervalMeters: nil, pendingCaptureStartWaypointIndex: nil,
              rewoundToStripStart: true)
    }
}
