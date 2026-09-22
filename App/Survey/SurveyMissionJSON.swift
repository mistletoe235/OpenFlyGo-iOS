import Foundation

enum SurveyMissionJSON {
    static let schemaVersion = 14

    static func encode(_ mission: SurveyMission) throws -> String {
        try mission.validate()
        var root: [String: Any] = [
            "schema_version": mission.recaptureFlightMode == .stopAndCapture ? 13 : schemaVersion,
            "id": mission.id,
            "name": mission.name,
            "created_at_epoch_ms": mission.createdAtEpochMillis,
            "coordinate_frame": mission.coordinateFrame,
            "camera_profile": encodeCamera(mission.cameraProfile),
            "constraints": encodeConstraints(mission.constraints),
            "roi": mission.roi.map(encodePoint),
            "waypoints": mission.waypoints.map(encodeWaypoint),
            "estimated_path_m": mission.estimatedPathMeters,
            "estimated_photo_count": mission.estimatedPhotoCount,
            "estimated_flight_s": mission.estimatedFlightSeconds,
            "terrain_plan": mission.terrainPlan.map(encodeTerrainPlan) ?? NSNull(),
            "active_mapping": mission.activeMapping.map(encodeActiveMapping) ?? NSNull(),
        ]
        if mission.recaptureFlightMode != .stopAndCapture {
            root["recapture_flight_mode"] = mission.recaptureFlightMode.rawValue
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) throws -> SurveyMission {
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SurveyValidationError.invalid("invalid mission JSON")
        }
        let schema = try integer(root, "schema_version")
        guard (1...schemaVersion).contains(schema) else {
            throw SurveyValidationError.invalid("unsupported mission schema")
        }
        let recaptureMode: SurveyRecaptureFlightMode
        if schema >= 14 {
            guard let mode = SurveyRecaptureFlightMode(rawValue: try string(root, "recapture_flight_mode")) else {
                throw SurveyValidationError.invalid("unsupported recapture flight mode")
            }
            recaptureMode = mode
        } else {
            guard root["recapture_flight_mode"] == nil else {
                throw SurveyValidationError.invalid("recapture flight mode requires schema 14")
            }
            recaptureMode = .stopAndCapture
        }
        let coordinateFrame = try string(root, "coordinate_frame")
        guard coordinateFrame == "WGS84" else {
            throw SurveyValidationError.invalid("only WGS84 missions are supported")
        }
        let camera = try decodeCamera(dictionary(root, "camera_profile"))
        let constraints = try decodeConstraints(dictionary(root, "constraints"), schema: schema)
        let roi = try array(root, "roi").map { try decodePoint(asDictionary($0, "ROI point")) }
        let waypoints = try array(root, "waypoints").map {
            try decodeWaypoint(asDictionary($0, "waypoint"), schema: schema)
        }
        let mission = SurveyMission(
            id: try string(root, "id"), name: try string(root, "name"),
            createdAtEpochMillis: try int64(root, "created_at_epoch_ms"),
            coordinateFrame: coordinateFrame, cameraProfile: camera,
            constraints: constraints, roi: roi, waypoints: waypoints,
            estimatedPathMeters: try double(root, "estimated_path_m"),
            estimatedPhotoCount: try integer(root, "estimated_photo_count"),
            estimatedFlightSeconds: try double(root, "estimated_flight_s"),
            terrainPlan: schema >= 7 ? try optionalTerrainPlan(root["terrain_plan"]) : nil,
            activeMapping: schema >= 11 ? try optionalActiveMapping(root["active_mapping"]) : nil,
            recaptureFlightMode: recaptureMode
        )
        try mission.validate()
        return mission
    }

    private static func encodeCamera(_ value: SurveyCameraProfile) -> [String: Any] {[
        "id": value.id,
        "image_width_px": value.imageWidthPixels,
        "image_height_px": value.imageHeightPixels,
        "horizontal_fov_deg": value.horizontalFieldOfViewDegrees,
        "vertical_fov_deg": value.verticalFieldOfViewDegrees,
        "minimum_capture_interval_s": value.minimumCaptureIntervalSeconds,
    ]}

    private static func decodeCamera(_ value: [String: Any]) throws -> SurveyCameraProfile {
        let result = SurveyCameraProfile(
            id: try string(value, "id"),
            imageWidthPixels: try integer(value, "image_width_px"),
            imageHeightPixels: try integer(value, "image_height_px"),
            horizontalFieldOfViewDegrees: try double(value, "horizontal_fov_deg"),
            verticalFieldOfViewDegrees: try double(value, "vertical_fov_deg"),
            minimumCaptureIntervalSeconds: optionalDouble(value, "minimum_capture_interval_s") ?? 1
        )
        try result.validate()
        return result
    }

    private static func encodeConstraints(_ value: SurveyConstraints) -> [String: Any] {[
        "altitude_agl_m": value.altitudeMetersAgl,
        "forward_overlap": value.forwardOverlap,
        "side_overlap": value.sideOverlap,
        "speed_mps": value.speedMetersPerSecond,
        "oblique_speed_mps": value.obliqueSpeedMetersPerSecond,
        "gimbal_pitch_deg": value.gimbalPitchDegrees,
        "route_heading_deg": value.routeHeadingDegrees,
        "crosshatch": value.crosshatch,
        "collection_mode": value.collectionMode.rawValue,
        "oblique_gimbal_pitch_deg": value.obliqueGimbalPitchDegrees,
        "boundary_margin_m": value.boundaryMarginMeters,
        "altitude_mode": value.altitudeMode.rawValue,
        "target_surface_to_takeoff_m": value.targetSurfaceToTakeoffMeters,
        "safe_takeoff_altitude_m": value.safeTakeoffAltitudeMeters,
        "takeoff_speed_mps": value.takeoffSpeedMetersPerSecond,
        "descent_speed_mps": value.descentSpeedMetersPerSecond,
        "takeoff_mode": value.takeoffMode.rawValue,
        "start_point_mode": value.startPointMode.rawValue,
        "completion_action": value.completionAction.rawValue,
        "capture_trigger_mode": value.captureTriggerMode.rawValue,
        "timed_capture_interval_s": value.timedCaptureIntervalSeconds,
        "oblique_forward_overlap": value.obliqueForwardOverlap,
        "oblique_side_overlap": value.obliqueSideOverlap,
        "oblique_heading_mode": value.obliqueHeadingMode.rawValue,
        "enabled_capture_views": value.enabledCaptureViews.map(\.rawValue).sorted(),
    ]}

    private static func decodeConstraints(_ value: [String: Any], schema: Int) throws -> SurveyConstraints {
        let legacyCrosshatch = optionalBool(value, "crosshatch") ?? false
        var result = SurveyConstraints()
        result.altitudeMetersAgl = try double(value, "altitude_agl_m")
        result.forwardOverlap = try double(value, "forward_overlap")
        result.sideOverlap = try double(value, "side_overlap")
        result.speedMetersPerSecond = try double(value, "speed_mps")
        result.obliqueSpeedMetersPerSecond = schema >= 12
            ? try double(value, "oblique_speed_mps") : result.speedMetersPerSecond
        result.gimbalPitchDegrees = try double(value, "gimbal_pitch_deg")
        result.routeHeadingDegrees = try double(value, "route_heading_deg")
        result.crosshatch = legacyCrosshatch
        if schema >= 3 {
            result.collectionMode = try enumValue(value, "collection_mode", SurveyCollectionMode.self)
            result.obliqueGimbalPitchDegrees = try double(value, "oblique_gimbal_pitch_deg")
        } else {
            result.collectionMode = legacyCrosshatch ? .crosshatchNadir : .ortho
            result.obliqueGimbalPitchDegrees = -45
        }
        result.boundaryMarginMeters = schema >= 2 ? try double(value, "boundary_margin_m") : 0
        if schema >= 4 {
            result.altitudeMode = try enumValue(value, "altitude_mode", SurveyAltitudeMode.self)
            result.targetSurfaceToTakeoffMeters = try double(value, "target_surface_to_takeoff_m")
            result.safeTakeoffAltitudeMeters = try double(value, "safe_takeoff_altitude_m")
            result.takeoffSpeedMetersPerSecond = try double(value, "takeoff_speed_mps")
            result.descentSpeedMetersPerSecond = schema >= 13
                ? try double(value, "descent_speed_mps") : 2
            result.startPointMode = try enumValue(value, "start_point_mode", SurveyStartPointMode.self)
            result.completionAction = try enumValue(value, "completion_action", SurveyCompletionAction.self)
            result.captureTriggerMode = try enumValue(value, "capture_trigger_mode", SurveyCaptureTriggerMode.self)
            result.timedCaptureIntervalSeconds = try double(value, "timed_capture_interval_s")
            result.obliqueForwardOverlap = try double(value, "oblique_forward_overlap")
            result.obliqueSideOverlap = try double(value, "oblique_side_overlap")
        } else {
            result.altitudeMode = .aboveTargetSurface
            result.targetSurfaceToTakeoffMeters = 0
            result.safeTakeoffAltitudeMeters = 30
            result.takeoffSpeedMetersPerSecond = 3
            result.descentSpeedMetersPerSecond = 2
            result.startPointMode = .autoNearest
            result.completionAction = .returnToHome
            result.captureTriggerMode = .distance
            result.timedCaptureIntervalSeconds = 1
            result.obliqueForwardOverlap = result.forwardOverlap
            result.obliqueSideOverlap = result.sideOverlap
        }
        result.takeoffMode = schema >= 6
            ? try enumValue(value, "takeoff_mode", SurveyTakeoffMode.self) : .manual
        result.obliqueHeadingMode = schema >= 10
            ? try enumValue(value, "oblique_heading_mode", SurveyObliqueHeadingMode.self) : .trackRoute
        if schema >= 8 {
            let rawViews = try array(value, "enabled_capture_views")
            let views = try rawViews.map { item -> SurveyCaptureView in
                guard let raw = item as? String, let view = SurveyCaptureView(rawValue: raw) else {
                    throw SurveyValidationError.invalid("invalid enabled_capture_views")
                }
                return view
            }
            result.enabledCaptureViews = Set(views)
        } else {
            result.enabledCaptureViews = SurveyCaptureView.standardSurveyViews
        }
        try result.validate()
        return result
    }

    private static func encodeActiveMapping(_ value: ActiveMappingMetadata) -> [String: Any] {[
        "schema_version": value.schemaVersion,
        "selection_method": value.selectionMethod,
        "ground_truth_used": value.groundTruthUsed,
        "gs_used_for_selection": value.gsUsedForSelection,
        "ordinary_gps_used": value.ordinaryGPSUsed,
        "source_capture_count": value.sourceCaptureCount,
        "survey_capture_count": value.surveyCaptureCount,
        "bridge_capture_count": value.bridgeCaptureCount,
        "source_estimated_route_distance_m": value.sourceEstimatedRouteDistanceMeters,
        "regions": value.regions.map(encodeActiveRegion),
        "passes": value.passes.map(encodeActivePass),
    ]}

    private static func optionalActiveMapping(_ value: Any?) throws -> ActiveMappingMetadata? {
        guard let object = value as? [String: Any] else {
            if value == nil || value is NSNull { return nil }
            throw SurveyValidationError.invalid("invalid active_mapping")
        }
        let result = ActiveMappingMetadata(
            schemaVersion: optionalInteger(object, "schema_version") ?? 1,
            selectionMethod: try string(object, "selection_method"),
            groundTruthUsed: optionalBool(object, "ground_truth_used") ?? false,
            gsUsedForSelection: optionalBool(object, "gs_used_for_selection") ?? false,
            ordinaryGPSUsed: optionalBool(object, "ordinary_gps_used") ?? false,
            sourceCaptureCount: try integer(object, "source_capture_count"),
            surveyCaptureCount: try integer(object, "survey_capture_count"),
            bridgeCaptureCount: try integer(object, "bridge_capture_count"),
            sourceEstimatedRouteDistanceMeters: try double(object, "source_estimated_route_distance_m"),
            regions: try optionalArray(object, "regions").map { try decodeActiveRegion(asDictionary($0, "active region")) },
            passes: try optionalArray(object, "passes").map { try decodeActivePass(asDictionary($0, "active pass")) }
        )
        try result.validate()
        return result
    }

    private static func encodeActiveRegion(_ value: ActiveMappingRegionMetadata) -> [String: Any] {[
        "region_id": value.regionID,
        "priority": value.priority,
        "kind": value.kind,
        "risk_score": value.riskScore,
        // Keep the legacy singular key for older Android V4 readers while
        // publishing the V5-compatible plural spelling as well.
        "reasons": value.reasons,
        "reason": value.reasons,
        "target_wgs84": value.targetWGS84.map(encodeActiveTarget) ?? NSNull(),
        "pass_indices": value.passIndices,
        "suggested_survey_photos": value.suggestedSurveyPhotos,
    ]}

    private static func decodeActiveRegion(_ value: [String: Any]) throws -> ActiveMappingRegionMetadata {
        let reasonValues: [Any]
        if value["reasons"] != nil {
            reasonValues = try optionalArray(value, "reasons")
        } else {
            reasonValues = try optionalArray(value, "reason")
        }
        return .init(
            regionID: try string(value, "region_id"),
            priority: try integer(value, "priority"),
            kind: try string(value, "kind"),
            riskScore: try double(value, "risk_score"),
            reasons: try reasonValues.map { item in
                guard let result = item as? String else { throw SurveyValidationError.invalid("invalid active region reason") }
                return result
            },
            targetWGS84: try optionalActiveTarget(value["target_wgs84"]),
            passIndices: try optionalArray(value, "pass_indices").map { item in
                guard let result = item as? NSNumber else { throw SurveyValidationError.invalid("invalid active region pass index") }
                return result.intValue
            },
            suggestedSurveyPhotos: optionalInteger(value, "suggested_survey_photos") ?? 0
        )
    }

    private static func encodeActiveTarget(_ value: ActiveMappingTarget) -> [String: Any] {[
        "latitude": value.latitude,
        "longitude": value.longitude,
        "absolute_altitude_m": value.absoluteAltitudeMeters,
    ]}

    private static func optionalActiveTarget(_ value: Any?) throws -> ActiveMappingTarget? {
        guard let object = value as? [String: Any] else {
            if value == nil || value is NSNull { return nil }
            throw SurveyValidationError.invalid("invalid active target")
        }
        return .init(latitude: try double(object, "latitude"),
                     longitude: try double(object, "longitude"),
                     absoluteAltitudeMeters: try double(object, "absolute_altitude_m"))
    }

    private static func encodeActivePass(_ value: ActiveMappingPassMetadata) -> [String: Any] {[
        "pass_index": value.passIndex,
        "region_id": value.regionID,
        "role": value.role,
        "capture_role": value.captureRole,
        "source": value.source,
        "required_for_reconstruction_bridge": value.requiredForReconstructionBridge,
    ]}

    private static func decodeActivePass(_ value: [String: Any]) throws -> ActiveMappingPassMetadata {
        .init(passIndex: try integer(value, "pass_index"),
              regionID: try string(value, "region_id"),
              role: try string(value, "role"),
              captureRole: try string(value, "capture_role"),
              source: try string(value, "source"),
              requiredForReconstructionBridge: optionalBool(value, "required_for_reconstruction_bridge") ?? false)
    }

    private static func encodeTerrainPlan(_ value: SurveyTerrainPlan) -> [String: Any] {[
        "source_name": value.sourceName,
        "source_sha256": value.sourceSHA256,
        "source_kind": value.sourceKind.rawValue,
        "bare_earth_base_sha256": value.bareEarthBaseSHA256 ?? NSNull(),
        "epsg": value.epsg,
        "target_agl_m": value.targetAGLMeters,
        "takeoff_terrain_elevation_m": value.takeoffTerrainElevationMeters,
        "sample_spacing_m": value.sampleSpacingMeters,
        "minimum_terrain_elevation_m": value.minimumTerrainElevationMeters,
        "maximum_terrain_elevation_m": value.maximumTerrainElevationMeters,
        "minimum_waypoint_altitude_m": value.minimumWaypointAltitudeMeters,
        "maximum_waypoint_altitude_m": value.maximumWaypointAltitudeMeters,
        "real_flight_verified": value.realFlightVerified,
        "takeoff_reference": value.takeoffReference.map { reference in
            [
                "point": encodePoint(reference.point),
                "source": reference.source.rawValue,
                "captured_at_epoch_ms": reference.capturedAtEpochMillis,
            ] as [String: Any]
        } ?? NSNull(),
    ]}

    private static func optionalTerrainPlan(_ value: Any?) throws -> SurveyTerrainPlan? {
        guard let dictionary = value as? [String: Any] else {
            if value == nil || value is NSNull { return nil }
            throw SurveyValidationError.invalid("invalid terrain_plan")
        }
        return SurveyTerrainPlan(
            sourceName: try string(dictionary, "source_name"),
            sourceSHA256: try string(dictionary, "source_sha256"),
            epsg: try integer(dictionary, "epsg"),
            targetAGLMeters: try double(dictionary, "target_agl_m"),
            takeoffTerrainElevationMeters: try double(dictionary, "takeoff_terrain_elevation_m"),
            sampleSpacingMeters: try double(dictionary, "sample_spacing_m"),
            minimumTerrainElevationMeters: try double(dictionary, "minimum_terrain_elevation_m"),
            maximumTerrainElevationMeters: try double(dictionary, "maximum_terrain_elevation_m"),
            minimumWaypointAltitudeMeters: try double(dictionary, "minimum_waypoint_altitude_m"),
            maximumWaypointAltitudeMeters: try double(dictionary, "maximum_waypoint_altitude_m"),
            realFlightVerified: optionalBool(dictionary, "real_flight_verified") ?? false,
            takeoffReference: try optionalTerrainTakeoffReference(dictionary["takeoff_reference"]),
            sourceKind: SurveyTerrainSourceKind(
                rawValue: optionalString(dictionary, "source_kind") ?? SurveyTerrainSourceKind.surfaceDSM.rawValue
            ) ?? .surfaceDSM,
            bareEarthBaseSHA256: optionalString(dictionary, "bare_earth_base_sha256")
        )
    }

    private static func optionalTerrainTakeoffReference(_ value: Any?) throws -> SurveyTerrainTakeoffReference? {
        guard let object = value as? [String: Any] else {
            if value == nil || value is NSNull { return nil }
            throw SurveyValidationError.invalid("invalid terrain takeoff reference")
        }
        guard let source = SurveyTerrainTakeoffReferenceSource(rawValue: try string(object, "source")) else {
            throw SurveyValidationError.invalid("invalid terrain takeoff reference source")
        }
        let capturedAt = try int64(object, "captured_at_epoch_ms")
        guard capturedAt > 0 else {
            throw SurveyValidationError.invalid("invalid terrain takeoff reference timestamp")
        }
        return .init(
            point: try decodePoint(dictionary(object, "point")),
            source: source,
            capturedAtEpochMillis: capturedAt
        )
    }

    private static func encodePoint(_ value: SurveyGeoPoint) -> [String: Any] {[
        "latitude": value.latitude, "longitude": value.longitude, "altitude_m": value.altitudeMeters,
    ]}

    private static func decodePoint(_ value: [String: Any]) throws -> SurveyGeoPoint {
        let result = SurveyGeoPoint(latitude: try double(value, "latitude"),
                                    longitude: try double(value, "longitude"),
                                    altitudeMeters: try double(value, "altitude_m"))
        try result.validate()
        return result
    }

    private static func encodeWaypoint(_ value: SurveyWaypoint) -> [String: Any] {[
        "point": encodePoint(value.point),
        "heading_deg": value.headingDegrees,
        "gimbal_pitch_deg": value.gimbalPitchDegrees,
        "kind": value.kind.rawValue,
        "capture_action": value.captureAction.rawValue,
        "capture_interval_m": value.captureIntervalMeters ?? NSNull(),
        "pass_index": value.passIndex,
        "capture_view": value.captureView.rawValue,
    ]}

    private static func decodeWaypoint(_ value: [String: Any], schema: Int) throws -> SurveyWaypoint {
        let result = SurveyWaypoint(
            point: try decodePoint(dictionary(value, "point")),
            headingDegrees: try double(value, "heading_deg"),
            gimbalPitchDegrees: try double(value, "gimbal_pitch_deg"),
            kind: try enumValue(value, "kind", SurveyWaypointKind.self),
            captureAction: try enumValue(value, "capture_action", SurveyCaptureAction.self),
            captureIntervalMeters: optionalDouble(value, "capture_interval_m"),
            passIndex: try integer(value, "pass_index"),
            captureView: schema >= 3
                ? try enumValue(value, "capture_view", SurveyCaptureView.self) : .nadir
        )
        try result.validate()
        return result
    }

    private static func string(_ value: [String: Any], _ key: String) throws -> String {
        guard let result = value[key] as? String else { throw missing(key) }
        return result
    }
    private static func optionalString(_ value: [String: Any], _ key: String) -> String? {
        guard !(value[key] is NSNull) else { return nil }
        return value[key] as? String
    }
    private static func double(_ value: [String: Any], _ key: String) throws -> Double {
        guard let result = value[key] as? NSNumber, result.doubleValue.isFinite else { throw missing(key) }
        return result.doubleValue
    }
    private static func optionalDouble(_ value: [String: Any], _ key: String) -> Double? {
        guard !(value[key] is NSNull), let result = value[key] as? NSNumber,
              result.doubleValue.isFinite else { return nil }
        return result.doubleValue
    }
    private static func integer(_ value: [String: Any], _ key: String) throws -> Int {
        guard let result = value[key] as? NSNumber else { throw missing(key) }
        return result.intValue
    }
    private static func optionalInteger(_ value: [String: Any], _ key: String) -> Int? {
        (value[key] as? NSNumber)?.intValue
    }
    private static func int64(_ value: [String: Any], _ key: String) throws -> Int64 {
        guard let result = value[key] as? NSNumber else { throw missing(key) }
        return result.int64Value
    }
    private static func optionalBool(_ value: [String: Any], _ key: String) -> Bool? {
        (value[key] as? NSNumber)?.boolValue
    }
    private static func dictionary(_ value: [String: Any], _ key: String) throws -> [String: Any] {
        try asDictionary(value[key], key)
    }
    private static func asDictionary(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let result = value as? [String: Any] else { throw missing(label) }
        return result
    }
    private static func array(_ value: [String: Any], _ key: String) throws -> [Any] {
        guard let result = value[key] as? [Any] else { throw missing(key) }
        return result
    }
    private static func optionalArray(_ value: [String: Any], _ key: String) throws -> [Any] {
        guard let item = value[key] else { return [] }
        guard !(item is NSNull), let result = item as? [Any] else {
            if item is NSNull { return [] }
            throw SurveyValidationError.invalid("invalid \(key)")
        }
        return result
    }
    private static func enumValue<T: RawRepresentable>(
        _ value: [String: Any], _ key: String, _ type: T.Type
    ) throws -> T where T.RawValue == String {
        guard let result = T(rawValue: try string(value, key)) else {
            throw SurveyValidationError.invalid("invalid \(key)")
        }
        return result
    }
    private static func missing(_ key: String) -> SurveyValidationError {
        .invalid("missing or invalid \(key)")
    }
}

struct SurveyMissionVersion: Equatable {
    var versionID = UUID().uuidString
    var missionName: String
    var revision: Int
    var savedAtEpochMillis: Int64
    var missionJSON: String

    func mission() throws -> SurveyMission { try SurveyMissionJSON.decode(missionJSON) }
}

enum SurveyMissionLibrary {
    static let maxVersions = 50
    private static let schemaVersion = 1

    static func addVersion(existing: [SurveyMissionVersion], mission: SurveyMission,
                           savedAtEpochMillis: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) throws -> [SurveyMissionVersion] {
        let revision = (existing.filter { $0.missionName == mission.name }.map(\.revision).max() ?? 0) + 1
        let added = SurveyMissionVersion(missionName: mission.name, revision: revision,
                                         savedAtEpochMillis: savedAtEpochMillis,
                                         missionJSON: try SurveyMissionJSON.encode(mission))
        return Array((existing + [added]).sorted { $0.savedAtEpochMillis > $1.savedAtEpochMillis }.prefix(maxVersions))
    }

    static func encode(_ versions: [SurveyMissionVersion]) throws -> String {
        let root: [String: Any] = [
            "schema_version": schemaVersion,
            "versions": versions.map { [
                "version_id": $0.versionID, "mission_name": $0.missionName,
                "revision": $0.revision, "saved_at_epoch_ms": $0.savedAtEpochMillis,
                "mission_json": $0.missionJSON,
            ] as [String: Any] },
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }

    static func decode(_ raw: String?) throws -> [SurveyMissionVersion] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["schema_version"] as? NSNumber)?.intValue == schemaVersion,
              let values = root["versions"] as? [[String: Any]] else {
            throw SurveyValidationError.invalid("unsupported mission library schema")
        }
        return try values.map { value in
            guard let versionID = value["version_id"] as? String, !versionID.isEmpty,
                  let name = value["mission_name"] as? String, !name.isEmpty,
                  let revision = value["revision"] as? NSNumber, revision.intValue > 0,
                  let saved = value["saved_at_epoch_ms"] as? NSNumber,
                  let missionJSON = value["mission_json"] as? String else {
                throw SurveyValidationError.invalid("invalid mission library entry")
            }
            return .init(versionID: versionID, missionName: name, revision: revision.intValue,
                         savedAtEpochMillis: saved.int64Value, missionJSON: missionJSON)
        }
    }
}
