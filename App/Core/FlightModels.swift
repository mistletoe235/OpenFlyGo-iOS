import Foundation
import UIKit

struct GeoPoint: Codable, Equatable, Identifiable {
    var id: String { "\(latitude),\(longitude)" }
    var latitude: Double
    var longitude: Double
}

/// Public, non-personal fallback used by previews and fresh simulator installs.
/// Coordinates point to People's Square in central Shanghai, not to a user,
/// device, saved mission, or last-known aircraft location.
enum OpenFlyDemoLocation {
    static let shanghaiCityCenterLatitude = 31.2304
    static let shanghaiCityCenterLongitude = 121.4737
    static let shanghaiCityCenter = GeoPoint(
        latitude: shanghaiCityCenterLatitude,
        longitude: shanghaiCityCenterLongitude
    )
}

enum AircraftFlightMode: String, Codable {
    case disconnected, manual, gps, opti, vln, returningHome, landing, emergency

    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .manual: return "人工"
        case .gps: return "GPS"
        case .opti: return "OPTI"
        case .vln: return "VLN"
        case .returningHome: return "返航"
        case .landing: return "降落"
        case .emergency: return "保护"
        }
    }
}

enum RCFlightProfile: String, Codable, CaseIterable {
    case cine, normal, sport, unknown

    var shortLabel: String {
        switch self {
        case .cine: return "C"
        case .normal: return "N"
        case .sport: return "S"
        case .unknown: return "?"
        }
    }

    var label: String {
        switch self {
        case .cine: return "平稳"
        case .normal: return "普通"
        case .sport: return "运动"
        case .unknown: return "未知"
        }
    }
}

enum PositionClosureMode: String, Codable, CaseIterable, Identifiable {
    case gps = "gps"
    case velocityEstimate = "velocity-estimate"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gps: return "GPS 位置闭环"
        case .velocityEstimate: return "速度积分估算"
        }
    }

    var shortLabel: String {
        switch self {
        case .gps: return "GPS闭环"
        case .velocityEstimate: return "速度估算"
        }
    }

    var detail: String {
        switch self {
        case .gps: return "使用飞机经纬度反馈；无有效 GPS 时拒绝执行"
        case .velocityEstimate: return "按飞控速度模长与指令方向积分；适合室内 OPTI/仿真短距离测试"
        }
    }
}

struct FlightSimulatorStatus: Equatable, Sendable {
    var available = false
    var active = false
    var stateReceived = false
    var motorsOn = false
    var flying = false
    /// WGS-84 origin passed to DJI Simulator.start for this exact session.
    /// Pose offsets are meaningful only together with this fixed origin.
    var originLatitudeDegrees: Double = OpenFlyDemoLocation.shanghaiCityCenterLatitude
    var originLongitudeDegrees: Double = OpenFlyDemoLocation.shanghaiCityCenterLongitude
    var positionX: Double = 0
    var positionY: Double = 0
    var positionZ: Double = 0
    var rollDegrees: Double = 0
    var pitchDegrees: Double = 0
    /// Raw yaw from the same DJI SimulatorState sample as position/attitude.
    /// Do not substitute the lower-rate flight-controller heading on the HIL wire.
    var yawDegrees: Double = 0
    /// Monotonic timestamp captured at the DJI SimulatorState delegate boundary.
    /// A zero value means that no raw simulator sample has been received yet.
    var sampleMonotonicNanoseconds: UInt64 = 0
    var measuredUpdateHz: Double = 0
    var message = "DJI 仿真器不可用"
}

/// DJI MSDK4 on iOS may publish one authoritative grounded SimulatorState and
/// then remain quiet until the motors change state. Android V4 continuously
/// retransmits its latest raw pose to UE, while applying freshness only to
/// commands. Keep those two concerns separate here.
enum SimulatorRawStatePolicy {
    static let movingMaximumAgeNanoseconds: UInt64 = 500_000_000

    static func hasAuthoritativeSample(
        _ state: FlightSimulatorStatus,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        state.active && state.stateReceived && state.sampleMonotonicNanoseconds > 0
            && now >= state.sampleMonotonicNanoseconds
    }

    static func isReadyForControl(
        _ state: FlightSimulatorStatus,
        now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        guard hasAuthoritativeSample(state, now: now) else { return false }
        // A confirmed stationary ground pose remains valid until DJI reports a
        // state transition. Once motors or flight are active, fail closed on a
        // stale raw stream exactly at the existing 500 ms control boundary.
        guard state.motorsOn || state.flying else { return true }
        return now - state.sampleMonotonicNanoseconds <= movingMaximumAgeNanoseconds
    }
}

/// Navigation gate used before submitting DJI Simulator takeoff.
///
/// Android V4 evaluates DJI's raw flight-mode string, which can report P-GPS
/// while the aircraft is still grounded. The iOS presentation model instead
/// deliberately labels every grounded state as `.manual`; requiring `.gps`
/// unconditionally therefore creates an impossible pre-takeoff gate. Keep the
/// real GPS/Home/location evidence mandatory, but only require the derived GPS
/// mode after the motors or aircraft have entered an active transition.
enum SimulatorNavigationReadiness {
    static func isReady(
        simulator: FlightSimulatorStatus,
        telemetry: FlightTelemetry
    ) -> Bool {
        guard simulator.active, simulator.stateReceived,
              telemetry.satellites >= 6,
              telemetry.aircraftLocationValid,
              telemetry.homeLocationSet,
              (2...5).contains(telemetry.gpsSignalLevel) else {
            return false
        }
        guard simulator.motorsOn || simulator.flying else { return true }
        return telemetry.mode == .gps
    }
}

/// Latest-only handoff from the DJI SimulatorState callback to the HIL UDP
/// scheduler. This deliberately contains no UI/MainActor work, matching the
/// Android V4 raw-callback -> AtomicReference -> UDP executor path.
final class RawSimulatorStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FlightSimulatorStatus?

    func submit(_ state: FlightSimulatorStatus) {
        lock.lock(); value = state; lock.unlock()
    }

    func latest() -> FlightSimulatorStatus? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func clear() {
        lock.lock(); value = nil; lock.unlock()
    }
}

enum FlightWarningSeverity: Int, Codable, Comparable {
    case notice = 0
    case caution = 1
    case warning = 2
    case critical = 3

    static func < (lhs: FlightWarningSeverity, rhs: FlightWarningSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct FlightWarning: Codable, Equatable, Identifiable {
    var id: String
    var severity: FlightWarningSeverity
    var title: String
    var detail: String?
    var code: Int?
}

struct FlightTelemetry: Codable, Equatable {
    var connected = true
    var remoteControllerConnected = true
    var sdkRegistered = true
    var productModel = "Simulator"
    var cameraModel = "Simulator Camera"
    var connectionMessage = "Mock 已连接"
    var flying = false
    var mode: AircraftFlightMode = .gps
    var rcFlightProfile: RCFlightProfile = .normal
    var aircraft = OpenFlyDemoLocation.shanghaiCityCenter
    var aircraftLocationValid = true
    var positionSource = "Mock GPS"
    var remoteController = OpenFlyDemoLocation.shanghaiCityCenter
    var remoteControllerLocationSource = "Mock"
    var remoteControllerHeading: Double?
    var remoteControllerHeadingSource: String?
    var home = OpenFlyDemoLocation.shanghaiCityCenter
    var altitude: Double = 0
    var asl: Double = 4.2
    var downwardHeight: Double = 0
    var downwardHeightValid = false
    var horizontalSpeed: Double = 0
    var verticalSpeed: Double = 0
    var velocityNorth: Double = 0
    var velocityEast: Double = 0
    var velocityDown: Double = 0
    var simulatorActive = false
    var virtualStickActive = false
    /// DJI can require a second user confirmation near the ground before an
    /// automatic landing continues. Optional preserves old snapshot decoding.
    var landingConfirmationNeeded: Bool? = false
    /// Current physical RC-stick state. Optional keeps older persisted
    /// telemetry snapshots decodable; nil is treated as unknown/inactive.
    var sticksActive: Bool? = false
    var heading: Double = 357
    var aircraftRoll: Double?
    var aircraftPitch: Double?
    var aircraftYaw: Double?
    var gimbalPitch: Double = -18
    var gimbalRoll: Double?
    var gimbalYaw: Double?
    var gimbalYawRelativeToAircraftHeading: Double?
    var gimbalStateTimestamp: Date?
    /// Raw DJI gimbal mechanical-limit signal for nadir capture policy.
    var gimbalPitchAtStop = false
    var satellites = 15
    var gpsSignalLevel = 5
    var homeLocationSet = true
    var warnings: [FlightWarning] = []
    var aircraftBattery = 86
    var remainingFlightTimeSeconds = 0
    var timeNeededToGoHomeSeconds = 0
    var timeNeededToLandSeconds = 0
    var batteryNeededToGoHomePercent = 0
    var batteryNeededToLandPercent = 0
    /// DJI Smart RTH lifecycle normalized from MSDK4's go-home assessment.
    var smartReturnToHomeState: String?
    var smartReturnToHomeCountdownSeconds: Int?
    var maxSafeFlightRadiusMeters: Double = 0
    var goHomeHeightMeters = 0
    var maxFlightHeightMeters = 0
    var maxFlightRadiusMeters = 0
    var maxFlightRadiusEnabled = false
    var rcBattery = 74
    var rcExternalBattery = 98
    var rcExternalBatteryPresent = false
    /// `true` only after DJI accepts a ChargeMobileMode read for this RC/firmware.
    var rcPhoneChargingAvailable = false
    /// DJI-compatible values: ALWAYS, NEVER, INTELLIGENT, UNKNOWN, UNSUPPORTED.
    var rcPhoneChargingMode = "UNKNOWN"
    var signal = 92
    var obstacleDistance: Double = 8.4
    var timestamp = Date()
    /// Updated only by DJIFlightControllerState, unlike `timestamp`, which is
    /// also refreshed by camera/battery/UI callbacks.
    var flightStateTimestamp = Date()
    var frameTimestamp = Date()

    static var disconnectedShanghai: FlightTelemetry {
        var value = FlightTelemetry()
        value.connected = false
        value.remoteControllerConnected = false
        value.sdkRegistered = false
        value.productModel = "未识别"
        value.cameraModel = "未识别相机"
        value.connectionMessage = "等待 DJI MSDK"
        value.flying = false
        value.mode = .disconnected
        value.rcFlightProfile = .unknown
        value.aircraftLocationValid = false
        value.positionSource = "上海默认位置"
        value.remoteControllerLocationSource = "上海默认位置"
        value.remoteControllerHeading = nil
        value.remoteControllerHeadingSource = nil
        value.altitude = 0
        value.asl = 0
        value.downwardHeight = 0
        value.downwardHeightValid = false
        value.horizontalSpeed = 0
        value.verticalSpeed = 0
        value.velocityNorth = 0
        value.velocityEast = 0
        value.velocityDown = 0
        value.simulatorActive = false
        value.virtualStickActive = false
        value.heading = 0
        value.gimbalPitch = 0
        value.gimbalPitchAtStop = false
        value.satellites = 0
        value.gpsSignalLevel = 6
        value.homeLocationSet = false
        value.warnings = []
        value.aircraftBattery = 0
        value.remainingFlightTimeSeconds = 0
        value.timeNeededToGoHomeSeconds = 0
        value.timeNeededToLandSeconds = 0
        value.batteryNeededToGoHomePercent = 0
        value.batteryNeededToLandPercent = 0
        value.maxSafeFlightRadiusMeters = 0
        value.goHomeHeightMeters = 0
        value.maxFlightHeightMeters = 0
        value.maxFlightRadiusMeters = 0
        value.maxFlightRadiusEnabled = false
        value.rcBattery = 0
        value.rcExternalBattery = 0
        value.rcExternalBatteryPresent = false
        value.rcPhoneChargingAvailable = false
        value.rcPhoneChargingMode = "UNKNOWN"
        value.signal = 0
        value.obstacleDistance = 0
        return value
    }

    var highestPriorityWarning: FlightWarning? {
        warnings.sorted {
            let leftPriority = warningDisplayPriority($0)
            let rightPriority = warningDisplayPriority($1)
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            return $0.id < $1.id
        }.first
    }

    private func warningDisplayPriority(_ warning: FlightWarning) -> Int {
        if warning.severity == .critical { return 400 }
        if warning.id == "gps-signal" { return 350 }
        return warning.severity.rawValue * 100
    }

    var gpsSignalLabel: String {
        switch gpsSignalLevel {
        case 0: return "极差"
        case 1: return "很弱"
        case 2: return "较弱"
        case 3: return "良好"
        case 4: return "很好"
        case 5: return "很强"
        case 6: return "无信号"
        default: return "未知"
        }
    }
}

struct CameraStatus: Equatable {
    var connected = true
    var recording = false
    var recordingSeconds = 0
    var sdInserted = true
    var photosRemaining = 121
    var message = "相机就绪"
    /// Generic selected-storage state. nil preserves compatibility with older
    /// providers that only reported `sdInserted`.
    var storageReady: Bool? = nil
    var storageName = "SD"

    var surveyGeometryRequired = false
    var surveyCameraProfile: SurveyCameraProfile?
    var surveyCameraUpdatedAt = Date.distantPast

    var captureStorageReady: Bool { storageReady ?? sdInserted }
    var canCapturePhotos: Bool {
        connected && !recording && captureStorageReady && photosRemaining > 0
    }
}

struct AircraftMediaItem: Identifiable {
    var id: String
    var fileName: String
    var timeCreated: String
    var fileSizeBytes: Int64
    var isVideo: Bool
    var durationSeconds: Double
    var storageName: String
    var thumbnail: UIImage?
}

struct CameraFrame: Equatable, Sendable {
    var sequence: Int
    var capturedAt: Date
    var jpeg: Data
    var width: Int
    var height: Int
    var sourceFormat: String = "jpeg"
    var sourceFrameID: UInt64? = nil
    var sourcePoseSequence: UInt64? = nil
    var sourceCapturePeerMonotonicNanoseconds: UInt64? = nil

    static func simulator(sequence: Int, date: Date = Date()) -> CameraFrame {
        let size = CGSize(width: 640, height: 360)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let colors = [UIColor(red: 0.25, green: 0.48, blue: 0.66, alpha: 1).cgColor,
                          UIColor(red: 0.72, green: 0.82, blue: 0.84, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 230), options: [])
            }
            UIColor(red: 0.20, green: 0.34, blue: 0.23, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: 230, width: 640, height: 130))
            for index in 0..<6 {
                let x = CGFloat(35 + index * 100)
                let height = CGFloat(75 + (index % 3) * 20)
                UIColor(white: 0.68, alpha: 1).setFill()
                cg.fill(CGRect(x: x, y: 230 - height, width: 72, height: height))
                UIColor.cyan.withAlphaComponent(0.45).setFill()
                cg.fill(CGRect(x: x + 9, y: 245 - height, width: 54, height: 8))
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .medium), .foregroundColor: UIColor.white]
            "OPENFLY MOCK CAMERA · FRAME \(sequence)".draw(at: CGPoint(x: 16, y: 16), withAttributes: attributes)
        }
        return CameraFrame(sequence: sequence, capturedAt: date, jpeg: image.jpegData(compressionQuality: 0.88) ?? Data(), width: 640, height: 360)
    }
}

struct RelativeAction: Codable, Equatable {
    var forwardMeters: Double
    var rightMeters: Double
    var upMeters: Double
    var yawDegrees: Double
    var confidence: Double
    var stopScore: Double
    var reason: String

    static let zero = RelativeAction(
        forwardMeters: 0, rightMeters: 0, upMeters: 0, yawDegrees: 0,
        confidence: 1, stopScore: 0, reason: "hold"
    )
}

struct VelocityCommand: Codable, Equatable {
    var forward: Double
    var right: Double
    var up: Double
    var yawRate: Double

    static let zero = VelocityCommand(forward: 0, right: 0, up: 0, yawRate: 0)
    var isZero: Bool { abs(forward) < 0.001 && abs(right) < 0.001 && abs(up) < 0.001 && abs(yawRate) < 0.001 }
}

/// DJI MSDK names body-X velocity `roll` and body-Y velocity `pitch`.
/// OpenFly uses body FRU: X/forward, Y/right, Z/up.
struct DJIBodyVelocityAxes: Equatable {
    var pitch: Double
    var roll: Double
    var verticalThrottle: Double
    var yaw: Double
}

enum BodyVelocityToDJIAxes {
    static func map(_ command: VelocityCommand) -> DJIBodyVelocityAxes {
        DJIBodyVelocityAxes(
            pitch: command.right,
            roll: command.forward,
            verticalThrottle: command.up,
            yaw: command.yawRate
        )
    }
}

struct InferenceResult: Equatable {
    var action: RelativeAction
    var latencyMilliseconds: Double
    var stages: [String: Double]
    var source: String
    var replanned: Bool
    var chunkRemaining: Int
    var yawIsExplicit = false
    var predictedActions: [RelativeAction] = []
}

enum FlightActionError: LocalizedError {
    case disconnected, notFlying, unavailable(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "飞行器未连接"
        case .notFlying: return "飞行器未起飞"
        case let .unavailable(reason): return reason
        }
    }
}
