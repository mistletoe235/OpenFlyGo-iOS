import Foundation

enum SurveyCoveragePlanner {
    struct Coverage: Equatable {
        var footprintWidthMeters: Double
        var footprintLengthMeters: Double
        var lineSpacingMeters: Double
        var captureIntervalMeters: Double
        var groundSampleDistanceCentimeters: Double
    }

    struct CaptureFeasibility: Equatable {
        var feasible: Bool
        var requestedIntervalSeconds: Double
        var minimumIntervalSeconds: Double
        var maximumFeasibleSpeedMetersPerSecond: Double
    }

    struct SpeedLimit: Equatable {
        var hardMaximumMetersPerSecond: Double
        var cameraMaximumMetersPerSecond: Double
        var effectiveMaximumMetersPerSecond: Double
        var cameraLimited: Bool
        var exceeded: Bool
    }

    static func coverage(camera: SurveyCameraProfile, constraints: SurveyConstraints) -> Coverage {
        let altitude = constraints.altitudeMetersAgl
        let width = 2 * altitude * tan(camera.horizontalFieldOfViewDegrees / 2 * .pi / 180)
        let length = 2 * altitude * tan(camera.verticalFieldOfViewDegrees / 2 * .pi / 180)
        return .init(
            footprintWidthMeters: width,
            footprintLengthMeters: length,
            lineSpacingMeters: max(0.5, width * (1 - constraints.sideOverlap)),
            captureIntervalMeters: max(0.5, length * (1 - constraints.forwardOverlap)),
            groundSampleDistanceCentimeters: width / Double(camera.imageWidthPixels) * 100
        )
    }

    static func altitudeForGroundSampleDistance(camera: SurveyCameraProfile,
                                                groundSampleDistanceCentimeters: Double) throws -> Double {
        guard groundSampleDistanceCentimeters.isFinite, groundSampleDistanceCentimeters > 0 else {
            throw SurveyValidationError.invalid("GSD must be positive")
        }
        let footprintWidth = groundSampleDistanceCentimeters / 100 * Double(camera.imageWidthPixels)
        return footprintWidth / (2 * tan(camera.horizontalFieldOfViewDegrees / 2 * .pi / 180))
    }

    static func obliqueCoverage(camera: SurveyCameraProfile,
                                constraints: SurveyConstraints) throws -> Coverage {
        let offNadir = abs(90 + constraints.obliqueGimbalPitchDegrees)
        let halfVertical = camera.verticalFieldOfViewDegrees / 2
        guard offNadir + halfVertical < 89 else {
            throw SurveyValidationError.invalid("oblique camera field of view reaches the horizon")
        }
        let altitude = constraints.altitudeMetersAgl
        let near = altitude * tan(max(0, offNadir - halfVertical) * .pi / 180)
        let far = altitude * tan((offNadir + halfVertical) * .pi / 180)
        let slant = altitude / cos(offNadir * .pi / 180)
        let width = 2 * slant * tan(camera.horizontalFieldOfViewDegrees / 2 * .pi / 180)
        let length = far - near
        return .init(
            footprintWidthMeters: width, footprintLengthMeters: length,
            lineSpacingMeters: max(0.5, width * (1 - constraints.obliqueSideOverlap)),
            captureIntervalMeters: max(0.5, length * (1 - constraints.obliqueForwardOverlap)),
            groundSampleDistanceCentimeters: width / Double(camera.imageWidthPixels) * 100
        )
    }

    static func captureFeasibility(camera: SurveyCameraProfile, constraints: SurveyConstraints,
                                   oblique: Bool = false) throws -> CaptureFeasibility {
        let planned = try oblique ? obliqueCoverage(camera: camera, constraints: constraints)
            : coverage(camera: camera, constraints: constraints)
        let requested = constraints.captureTriggerMode == .distance
            ? planned.captureIntervalMeters / (oblique
                ? constraints.obliqueSpeedMetersPerSecond : constraints.speedMetersPerSecond)
            : constraints.timedCaptureIntervalSeconds
        let minimumInterval = calibratedMinimumCaptureIntervalSeconds(camera)
        return .init(
            feasible: requested + 1e-9 >= minimumInterval,
            requestedIntervalSeconds: requested,
            minimumIntervalSeconds: minimumInterval,
            maximumFeasibleSpeedMetersPerSecond: planned.captureIntervalMeters / minimumInterval
        )
    }

    /// Imported missions retain their serialized camera profile for geometry, but a stale
    /// profile must not advertise a faster shutter cadence than the verified catalog entry
    /// with the same stable ID.
    private static func calibratedMinimumCaptureIntervalSeconds(_ camera: SurveyCameraProfile) -> Double {
        let catalogMinimum = SurveyCameraProfileCatalog.allVerified
            .first(where: { $0.profile.id == camera.id })?
            .profile.minimumCaptureIntervalSeconds ?? 0
        return max(camera.minimumCaptureIntervalSeconds, catalogMinimum)
    }

    static func speedLimit(camera: SurveyCameraProfile, constraints: SurveyConstraints) throws -> SpeedLimit {
        let hardMaximum = 10.0
        let cameraMaximum: Double
        let exceeded: Bool
        if constraints.captureTriggerMode == .time {
            cameraMaximum = .infinity
            exceeded = constraints.maximumSurveySpeedMetersPerSecond > hardMaximum + 1e-9
        } else {
            let nadir = try captureFeasibility(camera: camera, constraints: constraints).maximumFeasibleSpeedMetersPerSecond
            if constraints.collectionMode == .obliqueFiveDirection {
                let oblique = try captureFeasibility(camera: camera, constraints: constraints, oblique: true)
                    .maximumFeasibleSpeedMetersPerSecond
                cameraMaximum = min(nadir, oblique)
                exceeded = constraints.speedMetersPerSecond > min(hardMaximum, nadir) + 1e-9
                    || constraints.obliqueSpeedMetersPerSecond > min(hardMaximum, oblique) + 1e-9
            } else {
                cameraMaximum = nadir
                exceeded = constraints.speedMetersPerSecond > min(hardMaximum, nadir) + 1e-9
            }
        }
        let effective = min(hardMaximum, cameraMaximum)
        return .init(hardMaximumMetersPerSecond: hardMaximum,
                     cameraMaximumMetersPerSecond: cameraMaximum,
                     effectiveMaximumMetersPerSecond: effective,
                     cameraLimited: cameraMaximum < hardMaximum,
                     exceeded: exceeded)
    }
}
