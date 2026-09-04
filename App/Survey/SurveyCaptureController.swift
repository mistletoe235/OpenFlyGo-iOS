import Foundation

struct SurveyDistanceCaptureController {
    private(set) var active = false
    var activeIntervalMeters: Double? { active && intervalMeters.isFinite ? intervalMeters : nil }
    private(set) var estimatedCaptureLatencyMillis: Int64
    private var intervalMeters = Double.nan
    private var lastCapturePoint: SurveyGeoPoint?
    private var lastCaptureElapsedMillis = Int64.min
    private var lastCaptureRequestElapsedMillis = Int64.min
    private var pendingCaptureElapsedMillis = Int64.min
    private var stopAfterPendingCapture = false
    private var triggerMode: SurveyCaptureTriggerMode = .distance
    private var timedIntervalMillis: Int64 = 1_000
    private let minimumCapturePeriodMillis: Int64

    init(minimumCapturePeriodMillis: Int64 = 1_200, initialCaptureLatencyMillis: Int64 = 280) {
        self.minimumCapturePeriodMillis = minimumCapturePeriodMillis
        estimatedCaptureLatencyMillis = min(1_000, max(50, initialCaptureLatencyMillis))
    }

    mutating func configure(mode: SurveyCaptureTriggerMode, timedCaptureIntervalSeconds: Double) throws {
        guard timedCaptureIntervalSeconds.isFinite, timedCaptureIntervalSeconds > 0 else {
            throw SurveyValidationError.invalid("timed capture interval must be positive")
        }
        reset(); triggerMode = mode; timedIntervalMillis = Int64(timedCaptureIntervalSeconds * 1_000)
    }

    mutating func onWaypointReached(_ waypoint: SurveyWaypoint, position: SurveyGeoPoint,
                                    nowElapsedMillis: Int64, cameraReady: Bool) throws -> Bool {
        switch waypoint.captureAction {
        case .startDistanceInterval:
            guard let interval = waypoint.captureIntervalMeters, interval.isFinite, interval > 0 else {
                throw SurveyValidationError.invalid("capture interval is required at pass start")
            }
            active = true; intervalMeters = interval
            return captureIfReady(position, nowElapsedMillis, cameraReady, horizontalSpeed: 0,
                                  force: true, stopAfterCapture: false)
        case .stopDistanceInterval:
            let shouldCapture: Bool
            switch triggerMode {
            case .distance:
                shouldCapture = active && lastCapturePoint.map { Self.distanceMeters($0, position) >= 0.5 } == true
            case .time:
                shouldCapture = active && lastCaptureElapsedMillis != .min
                    && nowElapsedMillis - lastCaptureElapsedMillis + estimatedCaptureLatencyMillis >= timedIntervalMillis / 2
            }
            guard shouldCapture else { active = false; return false }
            return captureIfReady(position, nowElapsedMillis, cameraReady, horizontalSpeed: 0,
                                  force: true, stopAfterCapture: true)
        case .captureOnReach:
            return captureIfReady(position, nowElapsedMillis, cameraReady, horizontalSpeed: 0,
                                  force: true, stopAfterCapture: false)
        case .none: return false
        }
    }

    mutating func onPosition(_ position: SurveyGeoPoint, nowElapsedMillis: Int64,
                             cameraReady: Bool, horizontalSpeedMetersPerSecond: Double = 0) -> Bool {
        guard active, cameraReady else { return false }
        return captureIfReady(position, nowElapsedMillis, true,
                              horizontalSpeed: horizontalSpeedMetersPerSecond,
                              force: lastCapturePoint == nil, stopAfterCapture: false)
    }

    mutating func onCaptureResult(position: SurveyGeoPoint, nowElapsedMillis: Int64, success: Bool) {
        guard pendingCaptureElapsedMillis != .min else { return }
        if success {
            let observed = min(1_000, max(50, nowElapsedMillis - pendingCaptureElapsedMillis))
            estimatedCaptureLatencyMillis = Int64(Double(estimatedCaptureLatencyMillis) * 0.75 + Double(observed) * 0.25)
            lastCapturePoint = position; lastCaptureElapsedMillis = nowElapsedMillis
        }
        pendingCaptureElapsedMillis = .min
        if stopAfterPendingCapture { active = false }
        stopAfterPendingCapture = false
    }

    mutating func cancelPendingCapture() { pendingCaptureElapsedMillis = .min; stopAfterPendingCapture = false }

    func compensationLeadMeters(horizontalSpeedMetersPerSecond speed: Double) -> Double {
        guard speed.isFinite, speed > 0, intervalMeters.isFinite else { return 0 }
        return min(intervalMeters * 0.4, speed * Double(estimatedCaptureLatencyMillis) / 1_000)
    }

    mutating func reset() {
        active = false; intervalMeters = .nan; lastCapturePoint = nil
        lastCaptureElapsedMillis = .min; lastCaptureRequestElapsedMillis = .min; cancelPendingCapture()
    }

    mutating func restoreActive(captureIntervalMeters: Double, mode: SurveyCaptureTriggerMode = .distance,
                                timedCaptureIntervalSeconds: Double = 1) throws {
        guard captureIntervalMeters.isFinite, captureIntervalMeters > 0 else {
            throw SurveyValidationError.invalid("capture interval must be positive")
        }
        try configure(mode: mode, timedCaptureIntervalSeconds: timedCaptureIntervalSeconds)
        active = true; intervalMeters = captureIntervalMeters
    }

    private mutating func captureIfReady(_ position: SurveyGeoPoint, _ now: Int64, _ cameraReady: Bool,
                                         horizontalSpeed: Double, force: Bool, stopAfterCapture: Bool) -> Bool {
        guard cameraReady, pendingCaptureElapsedMillis == .min else { return false }
        let enoughTime = lastCaptureRequestElapsedMillis == .min
            || now - lastCaptureRequestElapsedMillis >= minimumCapturePeriodMillis
        let enoughTrigger: Bool
        if force { enoughTrigger = true }
        else if triggerMode == .distance {
            enoughTrigger = lastCapturePoint.map {
                Self.distanceMeters($0, position) + compensationLeadMeters(horizontalSpeedMetersPerSecond: horizontalSpeed) >= intervalMeters
            } ?? true
        } else {
            enoughTrigger = lastCaptureElapsedMillis == .min
                || now - lastCaptureElapsedMillis + estimatedCaptureLatencyMillis >= timedIntervalMillis
        }
        guard enoughTime, enoughTrigger else { return false }
        pendingCaptureElapsedMillis = now; lastCaptureRequestElapsedMillis = now
        stopAfterPendingCapture = stopAfterCapture
        return true
    }

    private static func distanceMeters(_ a: SurveyGeoPoint, _ b: SurveyGeoPoint) -> Double {
        hypot((b.latitude - a.latitude) * 111_132,
              (b.longitude - a.longitude) * 111_320 * cos((a.latitude + b.latitude) * .pi / 360))
    }
}
