import Foundation

/// A provider-level dead-man switch for body-velocity control. The flight
/// controller intentionally repeats the most recent desired command at 25 Hz,
/// so a UI/runtime bookkeeping bug must not be able to keep an old non-zero
/// velocity alive indefinitely. Active controllers refresh their command every
/// control cycle; an expired command is always replaced by zero.
enum VirtualStickCommandLeasePolicy {
    /// Survey and simulator-fallback loops refresh at 25 Hz. Position control
    /// is also refreshed by telemetry plus a 500 ms supervisor tick and rejects
    /// telemetry older than 750 ms. One second therefore leaves scheduling
    /// margin without allowing an old velocity to repeat indefinitely.
    static let maximumAgeSeconds = 1.0

    static func appliedCommand(
        desired: VelocityCommand,
        refreshedAt: Date,
        now: Date = Date()
    ) -> VelocityCommand {
        guard !desired.isZero,
              now.timeIntervalSince(refreshedAt) > maximumAgeSeconds else {
            return desired
        }
        return .zero
    }
}
import UIKit

enum DJIAccountState: String, Equatable, Sendable {
    case loggedIn
    case notLoggedIn
    case tokenOutOfDate
    case unknown
}

struct DJIAccountSnapshot: Equatable, Sendable {
    var state: DJIAccountState = .unknown
    var maskedAccount: String?
    var lastError: String?

    var loggedIn: Bool { state == .loggedIn }
    var shouldOfferStartupLogin: Bool {
        state == .notLoggedIn || state == .tokenOutOfDate
    }
}

@MainActor
protocol DJIFlightProvider: AnyObject {
    var telemetry: FlightTelemetry { get }
    var camera: CameraStatus { get }
    var latestFrame: CameraFrame? { get }
    /// Latest raw live-view packet time. Model JPEG decoding remains on-demand
    /// through `captureModelFrame()`.
    var liveVideoTimestamp: Date? { get }
    var simulatorStatus: FlightSimulatorStatus { get }
    var djiAccount: DJIAccountSnapshot { get }
    var djiAccountLoginIsSimulated: Bool { get }
    var onTelemetry: ((FlightTelemetry) -> Void)? { get set }
    var onCamera: ((CameraStatus) -> Void)? { get set }
    var onFrame: ((CameraFrame) -> Void)? { get set }
    var onSimulator: ((FlightSimulatorStatus) -> Void)? { get set }
    var onManualTakeover: (() -> Void)? { get set }
    var onDiagnostic: ((String, String) -> Void)? { get set }
    var onVirtualStickSendFailure: ((String) -> Void)? { get set }
    var onDJIAccount: ((DJIAccountSnapshot) -> Void)? { get set }
    var providerName: String { get }

    func start()
    func stop()
    func resumeConnection()
    func pauseConnection()
    func refreshDJIAccount()
    func logIntoDJIAccount(completion: @escaping (Error?) -> Void)
    func logOutOfDJIAccount(completion: @escaping (Error?) -> Void)
    func takeOff() throws
    /// Reports the actual SDK takeoff callback, not only synchronous request dispatch.
    func takeOff(completion: @escaping (Error?) -> Void)
    /// Simulator-only fallback used by the Android-parity HIL takeoff flow.
    /// Callers must verify a fresh, active raw SimulatorState before invoking it.
    func turnOnMotors(completion: @escaping (Error?) -> Void)
    func land() throws
    func cancelLanding() throws
    func confirmLanding() throws
    func returnHome() throws
    /// Reports the actual SDK go-home callback so safety automation cannot
    /// mistake request dispatch for an accepted RTH command.
    func returnHome(completion: @escaping (Error?) -> Void)
    func cancelReturnHome() throws
    /// Changes whether a supported DJI remote controller powers the attached phone.
    /// Availability is published through `FlightTelemetry.rcPhoneChargingAvailable`.
    func setPhoneChargingEnabled(_ enabled: Bool)
    func setVirtualStick(enabled: Bool)
    func send(_ command: VelocityCommand)
    func sendSurvey(_ command: VelocityCommand)
    func setGimbalPitch(degrees: Double) throws
    /// Survey-only gimbal command with the actual SDK completion result.
    func setSurveyGimbalPitch(degrees: Double, completion: @escaping (Error?) -> Void)
    func setGoHomeHeight(meters: Int) async throws
    func takePhoto() throws
    /// Survey capture completes only after the camera SDK returns the actual
    /// shoot-photo result. The regular shutter action remains fire-and-forget.
    func takeSurveyPhoto(completion: @escaping (Error?) -> Void)
    func toggleRecording() throws
    /// Enters camera playback/media-download mode, publishes the file list,
    /// then republishes as thumbnails arrive.
    func refreshMediaList(update: @escaping ([AircraftMediaItem], String?) -> Void)
    func fetchMediaThumbnail(id: String, completion: @escaping (UIImage?) -> Void)
    func exitMediaMode()
    func captureModelFrame() async throws -> CameraFrame
    func captureSurveyFrame() async throws -> CameraFrame
    func setSimulator(enabled: Bool) async throws
    /// Persists the WGS84 origin used by the next DJI Simulator start.
    /// Implementations must reject changes while the simulated aircraft is airborne.
    func setSimulatorOrigin(_ point: GeoPoint) throws
    func setSimulatorUpdateFrequency(_ hz: Int)
    /// Rebinds the raw SimulatorState callback without restarting an already
    /// active simulator session. Returns false when unsupported/inactive.
    func refreshSimulatorStateCallback() -> Bool
    /// Installs a latest-only raw SimulatorState sink used by HIL. Providers
    /// publish here directly from the SDK callback before any UI/MainActor work.
    func setRawSimulatorStateStore(_ store: RawSimulatorStateStore?)
    func simulateDisconnect()
    func simulateStaleTelemetry()
    func simulateManualTakeover()
    func simulateCameraError()
}

protocol EmbeddedInferenceEngine: Sendable {
    var engineName: String { get }
    var replansEveryAction: Bool { get }
    func load() async throws
    func configureExecution(executedPrefix: Int, stopThreshold: Double) async
    func hasQueuedAction() async -> Bool
    func infer(
        frame: CameraFrame,
        prompt: String,
        telemetry: FlightTelemetry,
        modelState: [Double]?
    ) async throws -> InferenceResult
    func stop() async
    func reset() async
    func diagnostics() async -> [String: String]
}

extension EmbeddedInferenceEngine {
    var replansEveryAction: Bool { false }
    func diagnostics() async -> [String: String] { [:] }
    func configureExecution(executedPrefix: Int, stopThreshold: Double) async {}
    func hasQueuedAction() async -> Bool { false }
    func infer(frame: CameraFrame, prompt: String, telemetry: FlightTelemetry) async throws -> InferenceResult {
        try await infer(frame: frame, prompt: prompt, telemetry: telemetry, modelState: nil)
    }
}

extension DJIFlightProvider {
    func captureSurveyFrame() async throws -> CameraFrame { try await captureModelFrame() }
    var onVirtualStickSendFailure: ((String) -> Void)? {
        get { nil }
        set {}
    }
    var liveVideoTimestamp: Date? { latestFrame?.capturedAt }
    var djiAccount: DJIAccountSnapshot { DJIAccountSnapshot() }
    var djiAccountLoginIsSimulated: Bool { false }
    var onDJIAccount: ((DJIAccountSnapshot) -> Void)? {
        get { nil }
        set {}
    }
    func resumeConnection() {}
    func pauseConnection() {}
    func refreshDJIAccount() { onDJIAccount?(djiAccount) }
    func logIntoDJIAccount(completion: @escaping (Error?) -> Void) {
        completion(FlightActionError.unavailable("当前飞行提供器不支持 DJI 账号登录"))
    }
    func logOutOfDJIAccount(completion: @escaping (Error?) -> Void) {
        completion(FlightActionError.unavailable("当前飞行提供器不支持退出 DJI 账号"))
    }
    func takeOff(completion: @escaping (Error?) -> Void) {
        do { try takeOff(); completion(nil) }
        catch { completion(error) }
    }
    func turnOnMotors(completion: @escaping (Error?) -> Void) {
        completion(FlightActionError.unavailable("当前飞行提供器不支持单独启动电机"))
    }
    func returnHome(completion: @escaping (Error?) -> Void) {
        do { try returnHome(); completion(nil) }
        catch { completion(error) }
    }
    func confirmLanding() throws {
        throw FlightActionError.unavailable("当前飞行提供器不支持近地确认")
    }
    func setPhoneChargingEnabled(_ enabled: Bool) {
        onDiagnostic?("错误", "当前飞行提供器不支持遥控器手机充电控制")
    }
    func setGimbalPitch(degrees: Double) throws {
        throw FlightActionError.unavailable("当前飞行提供器不支持云台角度控制")
    }
    func setSurveyGimbalPitch(degrees: Double, completion: @escaping (Error?) -> Void) {
        do { try setGimbalPitch(degrees: degrees); completion(nil) }
        catch { completion(error) }
    }
    func setGoHomeHeight(meters: Int) async throws {
        throw FlightActionError.unavailable("当前飞行提供器不支持写入返航高度")
    }
    func sendSurvey(_ command: VelocityCommand) { send(command) }
    func takeSurveyPhoto(completion: @escaping (Error?) -> Void) {
        do { try takePhoto(); completion(nil) }
        catch { completion(error) }
    }
    func setSimulatorUpdateFrequency(_ hz: Int) {}
    func setSimulatorOrigin(_ point: GeoPoint) throws {
        throw FlightActionError.unavailable("当前飞行提供器不支持设置仿真起点")
    }
    func refreshSimulatorStateCallback() -> Bool { false }
    func setRawSimulatorStateStore(_ store: RawSimulatorStateStore?) {}
    func refreshMediaList(update: @escaping ([AircraftMediaItem], String?) -> Void) {
        update([], "当前飞行提供器不支持飞机相册")
    }
    func fetchMediaThumbnail(id: String, completion: @escaping (UIImage?) -> Void) { completion(nil) }
    func exitMediaMode() {}
}
