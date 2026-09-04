import Foundation

struct SurveyExecutionCheckpoint: Equatable {
    var missionID: String
    var waypointIndex: Int
    var state: SurveyExecutionState
    var updatedAtEpochMillis: Int64
    var executionLegIndex: Int
    var phase: SurveyExecutionPhase
    var recoveryPoint: SurveyGeoPoint?
    /// Schema 4 records the capture controller state explicitly. Older
    /// checkpoints are ambiguous while crossing a photo strip and must be
    /// recovered conservatively from that strip's start.
    var captureStateRecorded: Bool
    var activeCaptureIntervalMeters: Double?
    var pendingCaptureStartWaypointIndex: Int?

    init(missionID: String, waypointIndex: Int, state: SurveyExecutionState,
         updatedAtEpochMillis: Int64, executionLegIndex: Int? = nil,
         phase: SurveyExecutionPhase = .survey, recoveryPoint: SurveyGeoPoint? = nil,
         captureStateRecorded: Bool = true,
         activeCaptureIntervalMeters: Double? = nil,
         pendingCaptureStartWaypointIndex: Int? = nil) throws {
        guard !missionID.isEmpty, waypointIndex >= 0, (executionLegIndex ?? waypointIndex) >= 0 else {
            throw SurveyValidationError.invalid("invalid survey checkpoint")
        }
        if let interval = activeCaptureIntervalMeters {
            guard interval.isFinite, interval > 0 else {
                throw SurveyValidationError.invalid("invalid active capture interval")
            }
        }
        if let pending = pendingCaptureStartWaypointIndex, pending < 0 {
            throw SurveyValidationError.invalid("invalid pending capture waypoint")
        }
        guard activeCaptureIntervalMeters == nil || pendingCaptureStartWaypointIndex == nil else {
            throw SurveyValidationError.invalid("capture cannot be active and pending simultaneously")
        }
        guard captureStateRecorded || (activeCaptureIntervalMeters == nil && pendingCaptureStartWaypointIndex == nil) else {
            throw SurveyValidationError.invalid("legacy checkpoint cannot carry capture state")
        }
        self.missionID = missionID
        self.waypointIndex = waypointIndex
        self.state = state
        self.updatedAtEpochMillis = updatedAtEpochMillis
        self.executionLegIndex = executionLegIndex ?? waypointIndex
        self.phase = phase
        self.recoveryPoint = recoveryPoint
        self.captureStateRecorded = captureStateRecorded
        self.activeCaptureIntervalMeters = activeCaptureIntervalMeters
        self.pendingCaptureStartWaypointIndex = pendingCaptureStartWaypointIndex
    }
}

enum SurveyExecutionCheckpointJSON {
    static let schemaVersion = 4

    static func encode(_ value: SurveyExecutionCheckpoint) throws -> String {
        var object: [String: Any] = [
            "schema_version": schemaVersion,
            "mission_id": value.missionID,
            "waypoint_index": value.waypointIndex,
            "state": value.state.rawValue,
            "updated_at_epoch_ms": value.updatedAtEpochMillis,
            "execution_leg_index": value.executionLegIndex,
            "phase": value.phase.rawValue,
            "capture_state_recorded": value.captureStateRecorded,
        ]
        if let point = value.recoveryPoint {
            object["recovery_latitude"] = point.latitude
            object["recovery_longitude"] = point.longitude
            object["recovery_altitude_m"] = point.altitudeMeters
        }
        if let interval = value.activeCaptureIntervalMeters {
            object["active_capture_interval_m"] = interval
        }
        if let index = value.pendingCaptureStartWaypointIndex {
            object["pending_capture_start_waypoint_index"] = index
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func decode(_ raw: String) throws -> SurveyExecutionCheckpoint {
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = root["schema_version"] as? NSNumber, (1...schemaVersion).contains(schema.intValue),
              let missionID = root["mission_id"] as? String,
              let waypoint = root["waypoint_index"] as? NSNumber,
              let stateRaw = root["state"] as? String, let state = SurveyExecutionState(rawValue: stateRaw),
              let updated = root["updated_at_epoch_ms"] as? NSNumber else {
            throw SurveyValidationError.invalid("unsupported or invalid checkpoint schema")
        }
        let leg: Int
        let phase: SurveyExecutionPhase
        if schema.intValue >= 2 {
            guard let legNumber = root["execution_leg_index"] as? NSNumber,
                  let phaseRaw = root["phase"] as? String,
                  let decodedPhase = SurveyExecutionPhase(rawValue: phaseRaw) else {
                throw SurveyValidationError.invalid("invalid schema 2 checkpoint")
            }
            leg = legNumber.intValue; phase = decodedPhase
        } else {
            leg = .max; phase = .survey
        }
        let recovery: SurveyGeoPoint?
        if schema.intValue >= 3, let latitude = root["recovery_latitude"] as? NSNumber,
           let longitude = root["recovery_longitude"] as? NSNumber,
           let altitude = root["recovery_altitude_m"] as? NSNumber {
            recovery = .init(latitude: latitude.doubleValue, longitude: longitude.doubleValue,
                             altitudeMeters: altitude.doubleValue)
        } else { recovery = nil }
        let captureStateRecorded: Bool
        let activeCaptureIntervalMeters: Double?
        let pendingCaptureStartWaypointIndex: Int?
        if schema.intValue >= 4 {
            guard let recorded = root["capture_state_recorded"] as? Bool else {
                throw SurveyValidationError.invalid("invalid schema 4 checkpoint")
            }
            captureStateRecorded = recorded
            activeCaptureIntervalMeters = (root["active_capture_interval_m"] as? NSNumber)?.doubleValue
            pendingCaptureStartWaypointIndex = (root["pending_capture_start_waypoint_index"] as? NSNumber)?.intValue
        } else {
            captureStateRecorded = false
            activeCaptureIntervalMeters = nil
            pendingCaptureStartWaypointIndex = nil
        }
        return try .init(missionID: missionID, waypointIndex: waypoint.intValue, state: state,
                         updatedAtEpochMillis: updated.int64Value, executionLegIndex: leg,
                         phase: phase, recoveryPoint: recovery,
                         captureStateRecorded: captureStateRecorded,
                         activeCaptureIntervalMeters: activeCaptureIntervalMeters,
                         pendingCaptureStartWaypointIndex: pendingCaptureStartWaypointIndex)
    }
}

struct SurveyRecoveryPosition: Equatable { var waypointIndex: Int; var executionLegIndex: Int }

enum SurveyCheckpointRecoveryPolicy {
    static func position(waypointIndex: Int, executionLegIndex: Int,
                         state: SurveyExecutionState, phase: SurveyExecutionPhase,
                         targetCaptureAction: SurveyCaptureAction,
                         hasRecoveryPoint: Bool = false) -> SurveyRecoveryPosition {
        let interruptedStripEnd = state == .paused && phase == .survey
            && targetCaptureAction == .stopDistanceInterval
            && !hasRecoveryPoint
            && waypointIndex > 0 && executionLegIndex > 0
        return interruptedStripEnd
            ? .init(waypointIndex: waypointIndex - 1, executionLegIndex: executionLegIndex - 1)
            : .init(waypointIndex: waypointIndex, executionLegIndex: executionLegIndex)
    }
}
