import Foundation

/// Receipt metadata captured at the DJI delegate boundary, before the state is
/// queued onto MainActor.  The wall clock is the telemetry freshness timestamp;
/// the monotonic value rejects callbacks queued before a newer state or session.
struct DJIFlightStateReceipt: Equatable, Sendable {
    let wallClock: Date
    let monotonicNanoseconds: UInt64

    nonisolated static func capture() -> DJIFlightStateReceipt {
        DJIFlightStateReceipt(
            wallClock: Date(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    nonisolated func isNewer(than previousMonotonicNanoseconds: UInt64) -> Bool {
        monotonicNanoseconds > previousMonotonicNanoseconds
    }
}

/// Creates a fail-closed telemetry snapshot at an aircraft/session boundary.
///
/// A replacement `DJIAircraft` can be published before its first flight-state,
/// battery, RC, AirLink, or Home callback.  Preserve only registration and an
/// iPhone-derived controller map position; every value that could authorize
/// flight control must be repopulated by callbacks from the new components.
enum DJIFlightSessionTelemetryReset {
    static func make(
        from previous: FlightTelemetry,
        connected: Bool,
        remoteControllerConnected: Bool,
        connectionMessage: String
    ) -> FlightTelemetry {
        var value = FlightTelemetry.disconnectedShanghai
        value.sdkRegistered = previous.sdkRegistered
        value.connected = connected
        value.remoteControllerConnected = remoteControllerConnected
        value.connectionMessage = connectionMessage
        value.productModel = previous.productModel
        value.cameraModel = previous.cameraModel
        if previous.remoteControllerLocationSource == "iPhone 定位" {
            value.remoteController = previous.remoteController
            value.remoteControllerLocationSource = previous.remoteControllerLocationSource
        }
        value.timestamp = Date()
        value.flightStateTimestamp = .distantPast
        value.frameTimestamp = .distantPast
        return value
    }
}

final class DJIRawSimulatorStatePublisher: @unchecked Sendable {
    /// Keep the raw DJI SimulatorState stream at the configured 100 Hz for the
    /// HIL sender, but do not invalidate the complete SwiftUI hierarchy at the
    /// same rate. Ten UI snapshots per second are smooth enough for numbers and
    /// map markers and leave the main thread available for video rendering.
    private static let uiPublishIntervalNanoseconds: UInt64 = 100_000_000

    struct Result {
        var state: FlightSimulatorStatus
        var shouldPublishUI: Bool
        var stateChanged: Bool
        var streamStarted: Bool
        var rateBecameAvailable: Bool
    }

    private let lock = NSLock()
    private var store: RawSimulatorStateStore?
    private var windowStarted: UInt64 = 0
    private var windowSamples: UInt64 = 0
    private var measuredHz = 0.0
    private var lastAcceptedSampleNanoseconds: UInt64 = 0
    /// A delegate session token is stable even when DJI bridges the same
    /// Objective-C simulator through different Swift wrapper identities.
    /// It also rejects callbacks already queued by a previous aircraft/session.
    private var sessionGeneration: UInt64 = 0
    private var acceptsSamples = false
    private var lastUIPublish: UInt64 = 0
    private var lastMotorsOn: Bool?
    private var lastFlying: Bool?
    private var originLatitudeDegrees = OpenFlyDemoLocation.shanghaiCityCenterLatitude
    private var originLongitudeDegrees = OpenFlyDemoLocation.shanghaiCityCenterLongitude
#if DEBUG
    private var beforeDestinationCommitForTesting: (() -> Void)?
#endif

    func install(_ store: RawSimulatorStateStore?) {
        lock.lock(); self.store = store; lock.unlock()
    }

    @discardableResult
    func beginSession(active: Bool) -> UInt64 {
        lock.lock()
        sessionGeneration &+= 1
        acceptsSamples = active
        windowStarted = 0; windowSamples = 0; measuredHz = 0
        lastAcceptedSampleNanoseconds = 0
        lastUIPublish = 0; lastMotorsOn = nil; lastFlying = nil
        let destination = store
        let generation = sessionGeneration
        destination?.clear()
        lock.unlock()
        return generation
    }

    func setOrigin(latitude: Double, longitude: Double) {
        lock.lock()
        originLatitudeDegrees = latitude
        originLongitudeDegrees = longitude
        lock.unlock()
    }

    func publish(sessionGeneration: UInt64, _ state: FlightSimulatorStatus,
                 receivedAt: UInt64) -> Result? {
        lock.lock()
        guard acceptsSamples, sessionGeneration == self.sessionGeneration else {
            lock.unlock()
            return nil
        }
        guard receivedAt >= lastAcceptedSampleNanoseconds else {
            lock.unlock()
            return nil
        }
        lastAcceptedSampleNanoseconds = receivedAt
        let streamStarted = windowStarted == 0
        if streamStarted { windowStarted = receivedAt }
        windowSamples &+= 1
        let elapsed = receivedAt >= windowStarted ? receivedAt - windowStarted : 0
        let previousMeasuredHz = measuredHz
        if elapsed >= 1_000_000_000 {
            measuredHz = Double(windowSamples) * 1_000_000_000 / Double(elapsed)
            windowStarted = receivedAt
            windowSamples = 0
        }
        let destination = store
        var published = state
        published.originLatitudeDegrees = originLatitudeDegrees
        published.originLongitudeDegrees = originLongitudeDegrees
        published.measuredUpdateHz = measuredHz
        let stateChanged = lastMotorsOn != published.motorsOn || lastFlying != published.flying
        let shouldPublishUI = stateChanged || lastUIPublish == 0
            || receivedAt - lastUIPublish >= Self.uiPublishIntervalNanoseconds
        if shouldPublishUI { lastUIPublish = receivedAt }
        lastMotorsOn = published.motorsOn
        lastFlying = published.flying
#if DEBUG
        beforeDestinationCommitForTesting?()
#endif
        destination?.submit(published)
        lock.unlock()
        return Result(
            state: published,
            shouldPublishUI: shouldPublishUI,
            stateChanged: stateChanged,
            streamStarted: streamStarted,
            rateBecameAvailable: previousMeasuredHz == 0 && measuredHz > 0
        )
    }

    func clear() {
        lock.lock()
        windowStarted = 0; windowSamples = 0; measuredHz = 0
        lastAcceptedSampleNanoseconds = 0
        lastUIPublish = 0; lastMotorsOn = nil; lastFlying = nil
        let destination = store
        destination?.clear()
        lock.unlock()
    }

#if DEBUG
    func setBeforeDestinationCommitForTesting(_ hook: (() -> Void)?) {
        lock.lock(); beforeDestinationCommitForTesting = hook; lock.unlock()
    }
#endif
}

private final class DJIAsyncCompletionOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        body()
    }
}

#if os(iOS) && !targetEnvironment(simulator) && !canImport(DJISDK)
#error("DJI device builds must link DJI-SDK-iOS. Run `pod install` and build DJIVLNiOS.xcworkspace, not the bare project.")
#endif

enum DJIPhoneChargingReadPolicy {
    static let retryDelaysSeconds: [UInt64] = [1, 2, 4]

    static func retryDelaySeconds(afterAttempt attempt: Int) -> UInt64? {
        retryDelaysSeconds.indices.contains(attempt) ? retryDelaysSeconds[attempt] : nil
    }

    static func isExplicitlyUnsupported(errorCode: Int) -> Bool {
        [-1_000, -1_013, -1_015].contains(errorCode)
    }
}

#if canImport(DJISDK)
import CoreLocation
import ExternalAccessory
@preconcurrency import DJISDK
import UIKit
import VideoToolbox

/// DJI does not promise that the Swift wrapper identity passed to
/// `simulator(_:didUpdate:)` is stable. A retained per-session delegate proxy
/// carries our own generation instead of filtering callbacks with `===`.
private final class DJISimulatorDelegateSessionProxy: NSObject, DJISimulatorDelegate {
    private let generation: UInt64
    private let handler: (DJISimulator, DJISimulatorState, UInt64) -> Void

    init(generation: UInt64,
         handler: @escaping (DJISimulator, DJISimulatorState, UInt64) -> Void) {
        self.generation = generation
        self.handler = handler
    }

    func simulator(_ simulator: DJISimulator, didUpdate state: DJISimulatorState) {
        handler(simulator, state, generation)
    }
}

@MainActor
final class DJIFlightProviderV4: NSObject, DJIFlightProvider {
    private(set) var telemetry = FlightTelemetry.disconnectedShanghai
    private(set) var camera = CameraStatus(connected: false, sdInserted: false, photosRemaining: 0,
                                           message: "等待 DJI 相机", storageReady: false,
                                           storageName: "存储", surveyGeometryRequired: true)
    private var surveyReadbackValues: [String: (value: DJIKeyedValue, receivedAt: Date)] = [:]
    private var surveyReadbackRequests: [String: Date] = [:]
    private var surveyReadbackGeneration = 0
    private(set) var latestFrame: CameraFrame?
    /// Timestamp captured at the raw DJIVideoFeed callback boundary. This is
    /// deliberately independent from the on-demand model JPEG conversion so a
    /// cold-start live view can prove that video is present before first inference.
    private(set) var liveVideoTimestamp: Date?
    private(set) var simulatorStatus = FlightSimulatorStatus()
    private(set) var djiAccount = DJIAccountSnapshot()
    var onTelemetry: ((FlightTelemetry) -> Void)?
    var onCamera: ((CameraStatus) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onSimulator: ((FlightSimulatorStatus) -> Void)?
    var onManualTakeover: (() -> Void)?
    var onDiagnostic: ((String, String) -> Void)?
    var onVirtualStickSendFailure: ((String) -> Void)?
    var onDJIAccount: ((DJIAccountSnapshot) -> Void)?
    let providerName = "DJI iOS MSDK V4.16.2"

    private weak var aircraft: DJIAircraft?
    private weak var flightController: DJIFlightController?
    // Retain the wrapper used to configure the current SDK session. Callback
    // acceptance deliberately does not rely on its Swift object identity; the
    // per-session delegate proxy below supplies the stable generation token.
    private var djiSimulator: DJISimulator?
    private var simulatorDelegateProxy: DJISimulatorDelegateSessionProxy?
    private weak var djiCamera: DJICamera?
    private weak var djiGimbal: DJIGimbal?
    nonisolated(unsafe) private weak var videoFeed: DJIVideoFeed?
    private var frameSequence = 0
    private let videoFeedQueue = DispatchQueue(label: "com.openfly.go.video-feed", qos: .userInteractive)
    private let modelFrameQueue = DispatchQueue(label: "com.openfly.go.model-frame", qos: .userInitiated)
    private let liveVideoPublicationLock = NSLock()
    nonisolated(unsafe) private var pendingLiveVideoPublication: (DJIVideoFeed, Date)?
    nonisolated(unsafe) private var liveVideoPublicationScheduled = false
    nonisolated(unsafe) private var lastLiveVideoPublicationScheduledAt: UInt64 = 0
    private let decodedFrameClaimLock = NSLock()
    nonisolated(unsafe) private var decodedFrameClaimed = false
    nonisolated(unsafe) private var decodedFrameGeneration = 0
    nonisolated(unsafe) private var surveyFrameRequested = false
    private var latestSurveyFrame: CameraFrame?
    private var modelFrameCaptureInFlight = false
    private var commandTimer: Timer?
    private var desiredCommand = VelocityCommand.zero
    private var desiredCommandRefreshedAt = Date.distantPast
    private var commandLeaseExpired = false
    private var virtualStickEnabled = false
    private var virtualStickRequestedEnabled = false
    private var virtualStickTransitionGeneration = 0
    private var virtualStickRetryTask: Task<Void, Never>?
    private var lastVirtualStickSendError: String?
    private var lastCommandWasZero = true
    private var simulatorLandingConfirmationPending = false
    private var takeoverLatched = false
    private var reconnectTimer: Timer?
    private var phoneChargingReadGeneration = 0
    private var phoneChargingReadTask: Task<Void, Never>?
    private var sdkConnectionStarted = false
    private var foreground = true
    private var awaitingReconnectFrame = false
    private var rcModeMapping: [RCFlightProfile] = [.unknown, .unknown, .unknown]
    private var lastFlightModeSwitchRaw: Int?
    private var needsFullAttach = true
    private let phoneLocationManager = CLLocationManager()
    private var lastRCGPSAt = Date.distantPast
    private var locationErrorReported = false
    private var productDiagnostics: [FlightWarning] = []
    private var lastWarningSignature = ""
    private var lastReportedWarning = ""
    private var simulatorUpdateFrequencyHz = 100
    private var simulatorOrigin = OpenFlyDemoLocation.shanghaiCityCenter
    private var simulatorOriginExplicitlySet = false
    private var simulatorSessionRecoveryAllowed = false
    private let rawSimulatorStatePublisher = DJIRawSimulatorStatePublisher()
    private var lastFlightStateReceiptMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var cameraHealthObserved = false
    private struct CameraStorageSnapshot {
        var inserted: Bool
        var ready: Bool
        /// MediaManager can still read a full or read-only volume even though
        /// that volume is not currently eligible for new captures.
        var readable: Bool
        var photosRemaining: Int
        var name: String
        var failure: String?
    }
    private var cameraStorageStates: [UInt: CameraStorageSnapshot] = [:]
    private var selectedCameraStorageRawValue: UInt?
    private var mediaFilesByID: [String: DJIMediaFile] = [:]
    private var mediaRefreshGeneration = 0
    private lazy var diagnosticsLocalizationBundles: [Bundle] = {
        let sdkBundle = Bundle(for: DJISDKManager.self)
        let frameworkURL = Bundle.main.bundleURL
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("DJISDK.framework", isDirectory: true)
        let roots = [sdkBundle.bundleURL, frameworkURL]
        return roots.compactMap { root in
            Bundle(url: root
                .appendingPathComponent("SDKSharedLib.bundle", isDirectory: true)
                .appendingPathComponent("DJIDiagnostics.bundle", isDirectory: true))
        }
    }()

    func start() {
        configurePhoneLocation()
        let key = Bundle.main.object(forInfoDictionaryKey: SDK_APP_KEY_INFO_PLIST_KEY) as? String
        guard let key, !key.isEmpty, key != "$(DJI_SDK_APP_KEY)" else {
            publishDisconnected("缺少 DJISDKAppKey")
            return
        }
        // DJI's documented default releases the accessory session in background and
        // resumes it in foreground. Keeping it open lets DJI Fly steal a stale session.
        DJISDKManager.closeConnection(whenEnteringBackground: true)
        DJISDKManager.registerApp(with: self)
    }

    func stop() {
        invalidatePhoneChargingRead()
        setVirtualStick(enabled: false)
        cancelModelFrameCapture()
        videoFeed?.remove(self)
        DJISDKManager.videoFeeder()?.remove(self)
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        sdkConnectionStarted = false
        DJISDKManager.stopConnectionToProduct()
        publishDisconnected("SDK 已停止")
    }

    func pauseConnection() {
        invalidatePhoneChargingRead()
        foreground = false
        needsFullAttach = true
        cancelModelFrameCapture()
        latestFrame = nil
        liveVideoTimestamp = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        sdkConnectionStarted = false
        setVirtualStick(enabled: false)
        // The SDK disable request may finish after the accessory session is
        // already gone. Locally invalidate it now so neither its callback nor
        // the 25 Hz timer can revive a command after foreground reconnect.
        virtualStickTransitionGeneration += 1
        virtualStickRetryTask?.cancel()
        virtualStickRetryTask = nil
        stopCommandTimer()
        desiredCommand = .zero
        desiredCommandRefreshedAt = Date()
        commandLeaseExpired = false
        virtualStickEnabled = false
        virtualStickRequestedEnabled = false
        telemetry.virtualStickActive = false
        DJIVideoPreviewer.instance()?.pause()
        phoneLocationManager.stopUpdatingLocation()
        phoneLocationManager.stopUpdatingHeading()
        onDiagnostic?("DJI", "App 已进入后台，释放 DJI 会话")
    }

    func resumeConnection() {
        foreground = true
        phoneLocationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { phoneLocationManager.startUpdatingHeading() }
        guard DJISDKManager.hasSDKRegistered() else { return }
        refreshDJIAccount()
        awaitingReconnectFrame = true
        DJIVideoPreviewer.instance()?.safeResume()
        reconnectNow()
        startReconnectTimer()
    }

    func refreshDJIAccount() {
        guard DJISDKManager.hasSDKRegistered() else {
            publishDJIAccount(state: .unknown)
            return
        }
        publishDJIAccount(state: DJISDKManager.userAccountManager().userAccountState)
    }

    func logIntoDJIAccount(completion: @escaping (Error?) -> Void) {
        guard DJISDKManager.hasSDKRegistered() else {
            completion(FlightActionError.unavailable("DJI MSDK 尚未注册，暂时无法登录"))
            return
        }
        onDiagnostic?("DJI账号", "已请求打开 DJI 账号登录")
        // Android MSDK V5 passes `authorizeAccount = false`. MSDK4 exposes
        // GEO-zone authorization as a separate account state, so use the same
        // login semantics and treat both Authorized and NotAuthorized as logged in.
        DJISDKManager.userAccountManager().logIntoDJIUserAccount(
            withAuthorizationRequired: false
        ) { [weak self] state, error in
            Task { @MainActor in
                guard let self else { completion(error); return }
                self.publishDJIAccount(state: state, error: error)
                if let error {
                    self.onDiagnostic?("错误", "DJI 账号登录失败：\(error.localizedDescription)")
                } else {
                    self.onDiagnostic?("DJI账号", "DJI 账号登录回调成功")
                }
                completion(error)
            }
        }
    }

    func logOutOfDJIAccount(completion: @escaping (Error?) -> Void) {
        guard DJISDKManager.hasSDKRegistered() else {
            completion(FlightActionError.unavailable("DJI MSDK 尚未注册，暂时无法退出登录"))
            return
        }
        onDiagnostic?("DJI账号", "已请求退出 DJI 账号")
        DJISDKManager.userAccountManager().logOutOfDJIUserAccount { [weak self] error in
            Task { @MainActor in
                guard let self else { completion(error); return }
                self.publishDJIAccount(
                    state: DJISDKManager.userAccountManager().userAccountState,
                    error: error
                )
                if let error {
                    self.onDiagnostic?("错误", "DJI 账号退出失败：\(error.localizedDescription)")
                } else {
                    self.onDiagnostic?("DJI账号", "DJI 账号退出回调成功")
                }
                completion(error)
            }
        }
    }

    private func publishDJIAccount(state: DJIUserAccountState, error: Error? = nil) {
        let mapped: DJIAccountState
        switch state {
        case .authorized, .notAuthorized:
            mapped = .loggedIn
        case .notLoggedIn:
            mapped = .notLoggedIn
        case .tokenOutOfDate:
            mapped = .tokenOutOfDate
        default:
            mapped = .unknown
        }
        let name = mapped == .loggedIn
            ? DJISDKManager.userAccountManager().loggedInDJIUserAccountName
            : nil
        let next = DJIAccountSnapshot(
            state: mapped,
            maskedAccount: name.flatMap(maskDJIAccount),
            lastError: error?.localizedDescription
        )
        guard next != djiAccount else { return }
        djiAccount = next
        onDJIAccount?(next)
    }

    private func maskDJIAccount(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.count <= 3 { return "***" }
        if let at = value.firstIndex(of: "@") {
            return String(value.prefix(2)) + "***" + String(value[at...])
        }
        return String(value.prefix(3)) + "***" + String(value.suffix(2))
    }

    private func reconnectNow() {
        guard foreground else { return }
        if let aircraft = DJISDKManager.product() as? DJIAircraft,
           aircraft.flightController?.isConnected == true || aircraft.remoteController?.isConnected == true {
            sdkConnectionStarted = true
            attach(aircraft)
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            return
        }
        // This app intentionally supports wired DJI remote controllers only.
        // Reissuing startConnectionToProduct every two seconds with no
        // Lightning accessory makes MSDK 4.16.2's private dji.serviceManager
        // spin continuously on recent iOS releases.
        guard !sdkConnectionStarted else { return }
        let wiredAccessoryPresent = !EAAccessoryManager.shared().connectedAccessories.isEmpty
        guard wiredAccessoryPresent else {
            telemetry.connectionMessage = "等待连接 DJI 遥控器"
            onTelemetry?(telemetry)
            return
        }
        telemetry.connectionMessage = "正在重新连接 DJI 产品"
        onTelemetry?(telemetry)
        let started = DJISDKManager.startConnectionToProduct()
        sdkConnectionStarted = started
        onDiagnostic?("DJI", started
            ? "已请求有线 DJI 重连"
            : "重连请求等待 DJI 会话释放")
    }

    private func configurePhoneLocation() {
        phoneLocationManager.delegate = self
        phoneLocationManager.desiredAccuracy = kCLLocationAccuracyBest
        phoneLocationManager.distanceFilter = 1
        phoneLocationManager.headingFilter = 3
        phoneLocationManager.requestWhenInUseAuthorization()
        phoneLocationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { phoneLocationManager.startUpdatingHeading() }
    }

    private func startReconnectTimer() {
        guard foreground, reconnectTimer == nil else { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.foreground else { timer.invalidate(); return }
                self.reconnectNow()
            }
        }
    }

    func takeOff() throws {
        try requireFlightController().startTakeoff { [weak self] error in self?.publishCommandResult("起飞", error) }
    }

    func takeOff(completion: @escaping (Error?) -> Void) {
        do {
            let controller = try requireFlightController()
            controller.startTakeoff { [weak self] error in
                self?.publishCommandResult("起飞", error)
                Task { @MainActor in completion(error) }
            }
        } catch {
            completion(error)
        }
    }

    func turnOnMotors(completion: @escaping (Error?) -> Void) {
        do {
            let controller = try requireFlightController()
            guard simulatorStatus.active, simulatorStatus.stateReceived,
                  simulatorStatus.sampleMonotonicNanoseconds > 0 else {
                completion(FlightActionError.unavailable("Simulator 未激活或没有原始状态"))
                return
            }
            controller.turnOnMotors { [weak self] error in
                self?.publishCommandResult("仿真启动电机", error)
                Task { @MainActor in
                    guard let self, controller === self.flightController else {
                        completion(FlightActionError.disconnected)
                        return
                    }
                    completion(error)
                }
            }
        } catch {
            completion(error)
        }
    }

    func land() throws {
        try requireFlightController().startLanding { [weak self] error in self?.publishCommandResult("降落", error) }
    }

    func cancelLanding() throws {
        try requireFlightController().cancelLanding { [weak self] error in self?.publishCommandResult("取消降落", error) }
    }

    func confirmLanding() throws {
        try requireFlightController().confirmLanding { [weak self] error in
            self?.publishCommandResult("确认降落", error)
        }
    }

    func returnHome() throws {
        try requireFlightController().startGoHome { [weak self] error in self?.publishCommandResult("返航", error) }
    }

    func returnHome(completion: @escaping (Error?) -> Void) {
        do {
            let controller = try requireFlightController()
            controller.startGoHome { [weak self] error in
                self?.publishCommandResult("返航", error)
                Task { @MainActor in
                    guard let self, controller === self.flightController else {
                        completion(FlightActionError.disconnected)
                        return
                    }
                    completion(error)
                }
            }
        } catch {
            completion(error)
        }
    }

    func cancelReturnHome() throws {
        try requireFlightController().cancelGoHome { [weak self] error in self?.publishCommandResult("取消返航", error) }
    }

    func setPhoneChargingEnabled(_ enabled: Bool) {
        guard let remoteController = aircraft?.remoteController, remoteController.isConnected else {
            onDiagnostic?("错误", "遥控器未连接，无法切换手机充电")
            return
        }
        invalidatePhoneChargingRead()
        let operationGeneration = phoneChargingReadGeneration
        let requestedMode = DJIRCChargeMobileMode(rawValue: enabled ? 1 : 0)!
        telemetry.rcPhoneChargingAvailable = false
        telemetry.rcPhoneChargingMode = enabled ? "SETTING_ALWAYS" : "SETTING_NEVER"
        telemetry.timestamp = Date()
        onTelemetry?(telemetry)
        remoteController.setChargeMobileMode(requestedMode) { [weak self, weak remoteController] error in
            Task { @MainActor in
                guard let self, let remoteController,
                      self.aircraft?.remoteController === remoteController,
                      self.phoneChargingReadGeneration == operationGeneration else { return }
                if let error {
                    let code = (error as NSError).code
                    self.telemetry.rcPhoneChargingAvailable = false
                    self.telemetry.rcPhoneChargingMode = DJIPhoneChargingReadPolicy
                        .isExplicitlyUnsupported(errorCode: code) ? "UNSUPPORTED" : "READ_FAILED"
                    self.telemetry.timestamp = Date()
                    self.onTelemetry?(self.telemetry)
                    self.onDiagnostic?("错误", "遥控器手机充电切换失败：\(error.localizedDescription) (code:\(code))")
                    return
                }
                self.telemetry.rcPhoneChargingAvailable = true
                self.telemetry.rcPhoneChargingMode = self.phoneChargingModeName(requestedMode)
                self.telemetry.timestamp = Date()
                self.onTelemetry?(self.telemetry)
                self.onDiagnostic?("DJI", enabled ? "遥控器将给手机充电" : "已关闭遥控器给手机充电")
                self.schedulePhoneChargingRead(
                    for: remoteController,
                    attempt: 0,
                    generation: operationGeneration,
                    delaySeconds: 1
                )
            }
        }
    }

    func setGoHomeHeight(meters: Int) async throws {
        guard (20...500).contains(meters) else {
            throw FlightActionError.unavailable("返航高度必须在 20–500 m")
        }
        let controller = try requireFlightController()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            controller.setGoHomeHeightInMeters(UInt(meters)) { [weak self, weak controller] error in
                Task { @MainActor in
                    guard let self else { return continuation.resume(throwing: CancellationError()) }
                    if let error {
                        self.onDiagnostic?("航线", "返航高度写入失败：\(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    } else {
                        if self.flightController === controller {
                            self.telemetry.goHomeHeightMeters = meters
                            self.onTelemetry?(self.telemetry)
                        }
                        self.onDiagnostic?("航线", "返航高度已写入 \(meters) m")
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    }

    func setVirtualStick(enabled: Bool) {
        virtualStickRequestedEnabled = enabled
        virtualStickTransitionGeneration += 1
        virtualStickRetryTask?.cancel()
        requestVirtualStick(enabled: enabled, generation: virtualStickTransitionGeneration, attempt: 0)
    }

    /// Invalidates all command state before a flight-controller reference can be
    /// replaced.  The final zero and best-effort SDK disable target the previous
    /// controller; generation invalidation prevents its delayed callback from
    /// reviving the new session.
    private func invalidateVirtualStickSession(requestSDKDisable: Bool) {
        let previousController = flightController
        let shouldDisable = virtualStickEnabled || virtualStickRequestedEnabled
        desiredCommand = .zero
        if virtualStickEnabled { sendCurrentCommand() }
        virtualStickTransitionGeneration += 1
        virtualStickRetryTask?.cancel()
        virtualStickRetryTask = nil
        stopCommandTimer()
        virtualStickEnabled = false
        virtualStickRequestedEnabled = false
        telemetry.virtualStickActive = false
        lastVirtualStickSendError = nil
        lastCommandWasZero = true
        takeoverLatched = false
        if requestSDKDisable, shouldDisable {
            previousController?.setVirtualStickModeEnabled(false) { _ in }
        }
    }

    private func requestVirtualStick(enabled: Bool, generation: Int, attempt: Int) {
        guard generation == virtualStickTransitionGeneration, let controller = flightController else { return }
        if enabled {
            controller.verticalControlMode = .velocity
            controller.rollPitchControlMode = .velocity
            controller.yawControlMode = .angularVelocity
            controller.rollPitchCoordinateSystem = .body
            controller.isVirtualStickAdvancedModeEnabled = true
        } else {
            desiredCommand = .zero
            sendCurrentCommand()
            if virtualStickEnabled { startCommandTimer() }
        }
        controller.setVirtualStickModeEnabled(enabled) { [weak self] error in
            Task { @MainActor in
                guard let self, generation == self.virtualStickTransitionGeneration else { return }
                if let error {
                    self.verifyVirtualStickState(
                        controller: controller,
                        requestedEnabled: enabled,
                        generation: generation,
                        attempt: attempt,
                        originalError: error
                    )
                } else {
                    self.finishVirtualStickTransition(enabled: enabled)
                }
            }
        }
    }

    private func verifyVirtualStickState(
        controller: DJIFlightController,
        requestedEnabled: Bool,
        generation: Int,
        attempt: Int,
        originalError: Error
    ) {
        controller.getVirtualStickModeEnabled { [weak self] actualEnabled, queryError in
            Task { @MainActor in
                guard let self, generation == self.virtualStickTransitionGeneration else { return }
                if queryError == nil {
                    self.virtualStickEnabled = actualEnabled
                    self.telemetry.virtualStickActive = actualEnabled
                    actualEnabled ? self.startCommandTimer() : self.stopCommandTimer()
                    self.onTelemetry?(self.telemetry)
                    if actualEnabled == requestedEnabled {
                        self.lastVirtualStickSendError = nil
                        self.onDiagnostic?("控制", requestedEnabled
                            ? "Virtual Stick 已取得（查询确认）"
                            : "Virtual Stick 已释放（查询确认）")
                        return
                    }
                }

                if !requestedEnabled, attempt < 3 {
                    self.onDiagnostic?("控制", "Virtual Stick 关闭回调异常，正在安全重试 \(attempt + 1)/3：\(originalError.localizedDescription)")
                    self.virtualStickRetryTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        self?.requestVirtualStick(enabled: false, generation: generation, attempt: attempt + 1)
                    }
                    return
                }

                if requestedEnabled, attempt < 6 {
                    self.onDiagnostic?(
                        "控制",
                        "Virtual Stick 暂不可用，保持零速度并重试 \(attempt + 1)/6：\(originalError.localizedDescription)"
                    )
                    self.virtualStickRetryTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 750_000_000)
                        guard !Task.isCancelled else { return }
                        self?.requestVirtualStick(
                            enabled: true,
                            generation: generation,
                            attempt: attempt + 1
                        )
                    }
                    return
                }

                if requestedEnabled {
                    self.virtualStickEnabled = false
                    self.telemetry.virtualStickActive = false
                    self.stopCommandTimer()
                }
                self.publishCameraMessage("Virtual Stick：\(originalError.localizedDescription)")
                self.onDiagnostic?("错误", "Virtual Stick \(requestedEnabled ? "启用" : "关闭")失败：\(originalError.localizedDescription)")
                self.onTelemetry?(self.telemetry)
            }
        }
    }

    private func finishVirtualStickTransition(enabled: Bool) {
        virtualStickEnabled = enabled
        telemetry.virtualStickActive = enabled
        lastVirtualStickSendError = nil
        onDiagnostic?("控制", enabled ? "Virtual Stick 已取得" : "Virtual Stick 已释放")
        enabled ? startCommandTimer() : stopCommandTimer()
        onTelemetry?(telemetry)
    }

    func send(_ command: VelocityCommand) {
        desiredCommand = VelocityCommand(
            forward: command.forward.clamped(to: -4 ... 4),
            right: command.right.clamped(to: -4 ... 4),
            up: command.up.clamped(to: -2 ... 2),
            yawRate: command.yawRate.clamped(to: -30 ... 30)
        )
        desiredCommandRefreshedAt = Date()
        commandLeaseExpired = false
    }

    func sendSurvey(_ command: VelocityCommand) {
        desiredCommand = VelocityCommand(
            forward: command.forward.clamped(to: -10 ... 10),
            right: command.right.clamped(to: -10 ... 10),
            up: command.up.clamped(to: -10 ... 10),
            yawRate: command.yawRate.clamped(to: -30 ... 30)
        )
        desiredCommandRefreshedAt = Date()
        commandLeaseExpired = false
    }

    func setGimbalPitch(degrees: Double) throws {
        try validateGimbalPitch(degrees)
        guard let djiGimbal else { throw unavailable("DJI 云台未连接") }
        rotateGimbal(djiGimbal, degrees: degrees) { [weak self] error in
            self?.publishCommandResult("云台调整", error)
        }
    }

    func setSurveyGimbalPitch(degrees: Double, completion: @escaping (Error?) -> Void) {
        do {
            try validateGimbalPitch(degrees)
            guard let djiGimbal else { throw unavailable("DJI 云台未连接") }
            rotateGimbal(djiGimbal, degrees: degrees) { [weak self] error in
                self?.publishCommandResult("云台调整", error)
                completion(error)
            }
        } catch {
            completion(error)
        }
    }

    private func validateGimbalPitch(_ degrees: Double) throws {
        guard degrees.isFinite, (-90...30).contains(degrees) else {
            throw unavailable("云台俯角必须在 -90° 到 30°")
        }
    }

    private func rotateGimbal(_ gimbal: DJIGimbal, degrees: Double,
                              completion: @escaping (Error?) -> Void) {
        let rotation = DJIGimbalRotation(
            pitchValue: NSNumber(value: degrees),
            rollValue: nil,
            yawValue: nil,
            time: 1,
            mode: .absoluteAngle,
            ignore: true
        )
        gimbal.rotate(with: rotation, completion: completion)
    }

    func takePhoto() throws {
        guard djiCamera != nil else { throw unavailable("DJI 相机未连接") }
        takeSurveyPhoto { [weak self] error in self?.publishCommandResult("拍照", error) }
    }

    func takeSurveyPhoto(completion: @escaping (Error?) -> Void) {
        guard let camera = djiCamera else {
            completion(unavailable("DJI 相机未连接"))
            return
        }
        let shoot = { [weak self, weak camera] (error: Error?) in
            guard error == nil else {
                self?.publishCommandResult("拍照", error)
                completion(error)
                return
            }
            guard let camera else {
                let error = self?.unavailable("DJI 相机连接已失效")
                    ?? FlightActionError.unavailable("DJI 相机连接已失效")
                completion(error)
                return
            }
            camera.startShootPhoto { [weak self] error in
                self?.publishCommandResult("拍照", error)
                completion(error)
            }
        }
        if camera.isFlatCameraModeSupported() {
            camera.setFlatMode(.photoSingle, withCompletion: shoot)
        } else {
            camera.setMode(.shootPhoto, withCompletion: shoot)
        }
    }

    func toggleRecording() throws {
        guard let camera = djiCamera else { throw unavailable("DJI 相机未连接") }
        if self.camera.recording {
            camera.stopRecordVideo { [weak self] error in self?.publishCommandResult("停止录像", error) }
        } else {
            let record = { [weak self, weak camera] (error: Error?) in
                guard let self else { return }
                guard error == nil else {
                    self.publishCommandResult("开始录像", error)
                    return
                }
                camera?.startRecordVideo { [weak self] error in self?.publishCommandResult("开始录像", error) }
            }
            if camera.isFlatCameraModeSupported() {
                camera.setFlatMode(.videoNormal, withCompletion: record)
            } else {
                camera.setMode(.recordVideo, withCompletion: record)
            }
        }
    }

    func refreshMediaList(update: @escaping ([AircraftMediaItem], String?) -> Void) {
        guard !telemetry.flying else {
            update([], "飞行中禁止切换相机媒体模式")
            return
        }
        guard let camera = djiCamera, let manager = camera.mediaManager else {
            update([], "该相机不提供 MediaManager")
            return
        }
        mediaRefreshGeneration += 1
        let generation = mediaRefreshGeneration
        update([], "正在进入飞机相册模式…")
        camera.getStorageLocation { [weak self, weak camera] location, locationError in
            Task { @MainActor in
                guard let self, generation == self.mediaRefreshGeneration, let camera else { return }
                let storage: DJICameraStorageLocation
                if locationError == nil, location != .unknown {
                    storage = location
                } else if self.cameraStorageStates[DJICameraStorageLocation.sdCard.rawValue]?.readable == true {
                    storage = .sdCard
                } else if self.cameraStorageStates[DJICameraStorageLocation.internalStorage.rawValue]?.readable == true {
                    storage = .internalStorage
                } else {
                    update([], locationError.map { "读取拍照存储位置失败：\($0.localizedDescription)" }
                        ?? "没有可读取的飞机存储")
                    return
                }
                let entered: (Error?) -> Void = { [weak self] modeError in
                    Task { @MainActor in
                        guard let self, generation == self.mediaRefreshGeneration else { return }
                        if let modeError {
                            update([], "进入相册模式失败：\(modeError.localizedDescription)")
                            return
                        }
                        update([], "正在读取\(self.mediaStorageName(storage))媒体列表…")
                        manager.refreshFileList(of: storage, withCompletion: { [weak self] refreshError in
                            Task { @MainActor in
                                guard let self, generation == self.mediaRefreshGeneration else { return }
                                if let refreshError {
                                    update([], "刷新媒体列表失败：\(refreshError.localizedDescription)")
                                    return
                                }
                                let files = (storage == .internalStorage
                                    ? manager.internalStoragefileListSnapshot()
                                    : manager.sdCardFileListSnapshot()) ?? []
                                let sorted = files.sorted { $0.timeCreated > $1.timeCreated }
                                self.mediaFilesByID = Dictionary(uniqueKeysWithValues: sorted.map {
                                    (self.mediaID(for: $0), $0)
                                })
                                update(sorted.map { self.mediaItem(for: $0) }, nil)
                                self.onDiagnostic?("相机", "已读取\(self.mediaStorageName(storage))媒体 \(sorted.count) 个")
                            }
                        })
                    }
                }
                if camera.isFlatCameraModeSupported() {
                    camera.enterPlayback(completion: entered)
                } else {
                    camera.setMode(.mediaDownload, withCompletion: entered)
                }
            }
        }
    }

    func fetchMediaThumbnail(id: String, completion: @escaping (UIImage?) -> Void) {
        guard let file = mediaFilesByID[id] else { completion(nil); return }
        if let thumbnail = file.thumbnail { completion(thumbnail); return }
        let generation = mediaRefreshGeneration
        file.fetchThumbnail { [weak self, weak file] error in
            Task { @MainActor in
                guard let self, generation == self.mediaRefreshGeneration, let file else {
                    completion(nil)
                    return
                }
                if let thumbnail = file.thumbnail {
                    completion(thumbnail)
                    return
                }
                if let error {
                    self.onDiagnostic?("相机", "缩略图读取失败，改读预览图 \(file.fileName)：\(error.localizedDescription)")
                }
                file.fetchPreview { [weak self, weak file] previewError in
                    Task { @MainActor in
                        if let previewError, let file {
                            self?.onDiagnostic?("相机", "预览图读取失败 \(file.fileName)：\(previewError.localizedDescription)")
                        }
                        completion(file?.preview)
                    }
                }
            }
        }
    }

    func exitMediaMode() {
        mediaRefreshGeneration += 1
        mediaFilesByID.removeAll()
        guard let camera = djiCamera else { return }
        let finished: (Error?) -> Void = { [weak self] error in
            Task { @MainActor in
                if let error { self?.onDiagnostic?("错误", "退出相册模式失败：\(error.localizedDescription)") }
                else { self?.onDiagnostic?("相机", "已退出相册并恢复拍照模式") }
                DJIVideoPreviewer.instance()?.safeResume()
            }
        }
        if camera.isFlatCameraModeSupported() {
            camera.exitPlayback(completion: finished)
        } else {
            camera.setMode(.shootPhoto, withCompletion: finished)
        }
    }

    private func mediaID(for file: DJIMediaFile) -> String {
        "\(file.storageLocation.rawValue):\(file.index):\(file.fileName)"
    }

    private func mediaStorageName(_ storage: DJICameraStorageLocation) -> String {
        switch storage {
        case .sdCard: return "SD 卡"
        case .internalStorage: return "机载存储"
        default: return "飞机存储"
        }
    }

    private func mediaItem(for file: DJIMediaFile) -> AircraftMediaItem {
        let video = file.mediaType == .MOV || file.mediaType == .MP4
        return AircraftMediaItem(
            id: mediaID(for: file),
            fileName: file.fileName,
            timeCreated: file.timeCreated,
            fileSizeBytes: file.fileSizeInBytes,
            isVideo: video,
            durationSeconds: Double(file.durationInSeconds),
            storageName: mediaStorageName(file.storageLocation),
            thumbnail: file.thumbnail
        )
    }

    func captureModelFrame() async throws -> CameraFrame {
        guard camera.connected else { throw unavailable("DJI 相机未连接") }
        let startingSequence = frameSequence
        for _ in 0..<60 {
            if frameSequence > startingSequence, let latestFrame { return latestFrame }
            startDecodedFrameCaptureIfNeeded()
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                cancelModelFrameCapture()
                throw error
            }
        }
        if frameSequence > startingSequence, let latestFrame { return latestFrame }
        cancelModelFrameCapture()
        throw unavailable("等待 DJI 当前画面超时")
    }

    func captureSurveyFrame() async throws -> CameraFrame {
        guard !surveyFrameRequestActive() else { throw unavailable("航测图传帧正在读取") }
        setSurveyFrameRequest(true)
        let requestedAt = Date()
        defer { setSurveyFrameRequest(false); latestSurveyFrame = nil }
        _ = try await captureModelFrame()
        guard let frame = latestSurveyFrame, frame.capturedAt >= requestedAt else {
            throw unavailable("未取得保持原始比例的航测图传帧")
        }
        return frame
    }

    nonisolated private func surveyFrameRequestActive() -> Bool {
        decodedFrameClaimLock.lock()
        defer { decodedFrameClaimLock.unlock() }
        return surveyFrameRequested
    }

    private func setSurveyFrameRequest(_ enabled: Bool) {
        decodedFrameClaimLock.lock()
        surveyFrameRequested = enabled
        decodedFrameClaimLock.unlock()
    }

    func setSimulator(enabled: Bool) async throws {
        guard let simulator = djiSimulator ?? flightController?.simulator else {
            throw unavailable("当前飞机或固件不支持 DJI 内置仿真器")
        }
        djiSimulator = simulator
        if enabled {
            // Install the delegate session before invoking start so even its
            // first synchronous/early callback reaches the RAW store.
            installSimulatorDelegate(on: simulator)
            rawSimulatorStatePublisher.setOrigin(
                latitude: simulatorOrigin.latitude,
                longitude: simulatorOrigin.longitude
            )
            guard !telemetry.flying || simulatorSessionRecoveryAllowed else {
                throw unavailable("真实飞机已在飞行，不能启动内置仿真器")
            }
            if simulator.isSimulatorActive {
                simulatorStatus.active = true
                simulatorSessionRecoveryAllowed = true
                telemetry.simulatorActive = true
                onSimulator?(simulatorStatus)
                onTelemetry?(telemetry)
                return
            }
            if !simulatorOriginExplicitlySet {
                let candidate = telemetry.aircraftLocationValid ? telemetry.aircraft
                    : (telemetry.homeLocationSet ? telemetry.home : simulatorOrigin)
                if candidate.latitude.isFinite, candidate.longitude.isFinite,
                   abs(candidate.latitude) <= 90, abs(candidate.longitude) <= 180,
                   abs(candidate.latitude) > 1e-9 || abs(candidate.longitude) > 1e-9 {
                    simulatorOrigin = candidate
                }
            }
            simulatorStatus.originLatitudeDegrees = simulatorOrigin.latitude
            simulatorStatus.originLongitudeDegrees = simulatorOrigin.longitude
            rawSimulatorStatePublisher.setOrigin(
                latitude: simulatorOrigin.latitude,
                longitude: simulatorOrigin.longitude
            )
            simulatorStatus.message = String(
                format: "正在当前位置 %.6f, %.6f 启动 DJI 内置仿真…",
                simulatorOrigin.latitude, simulatorOrigin.longitude
            )
            simulatorStatus.stateReceived = false
            rawSimulatorStatePublisher.clear()
            onSimulator?(simulatorStatus)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = DJIAsyncCompletionOnce()
                simulator.start(
                    withLocation: CLLocationCoordinate2D(
                        latitude: simulatorOrigin.latitude,
                        longitude: simulatorOrigin.longitude
                    ),
                    updateFrequency: UInt(simulatorUpdateFrequencyHz),
                    gpsSatellitesNumber: 18
                ) { error in
                    once.run {
                        if let error, !simulator.isSimulatorActive {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    once.run {
                        if simulator.isSimulatorActive {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: FlightActionError.unavailable(
                                "DJI Simulator 启动回调超过 6 秒且未实际激活"
                            ))
                        }
                    }
                }
            }
            simulatorStatus.active = true
            simulatorSessionRecoveryAllowed = true
            simulatorStatus.message = String(
                format: "DJI 内置仿真已启动：%.6f, %.6f · 18 星 · %d Hz",
                simulatorOrigin.latitude, simulatorOrigin.longitude, simulatorUpdateFrequencyHz
            )
            telemetry.simulatorActive = true
            telemetry.positionSource = "DJI 内置仿真"
            onSimulator?(simulatorStatus)
            onTelemetry?(telemetry)
            onDiagnostic?("仿真", simulatorStatus.message)
        } else {
            guard !simulatorStatus.flying, !simulatorStatus.motorsOn else {
                throw unavailable("仿真飞机仍在飞行，请先降落再关闭")
            }
            if !simulator.isSimulatorActive {
                simulatorStatus.active = false
                telemetry.simulatorActive = false
                onSimulator?(simulatorStatus)
                onTelemetry?(telemetry)
                return
            }
            simulatorStatus.message = "正在停止 DJI 内置仿真…"
            onSimulator?(simulatorStatus)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = DJIAsyncCompletionOnce()
                simulator.stop { error in
                    once.run {
                        if let error, simulator.isSimulatorActive {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    once.run {
                        if simulator.isSimulatorActive {
                            continuation.resume(throwing: FlightActionError.unavailable(
                                "DJI Simulator 停止回调超过 6 秒且仍处于激活状态"
                            ))
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
            simulatorStatus = FlightSimulatorStatus(available: true, message: "DJI 内置仿真已停止")
            rawSimulatorStatePublisher.clear()
            telemetry.simulatorActive = false
            telemetry.positionSource = telemetry.aircraftLocationValid ? "DJI GPS" : "位置无效"
            onSimulator?(simulatorStatus)
            onTelemetry?(telemetry)
            onDiagnostic?("仿真", simulatorStatus.message)
        }
    }

    func setSimulatorOrigin(_ point: GeoPoint) throws {
        guard point.latitude.isFinite, (-90...90).contains(point.latitude),
              point.longitude.isFinite, (-180...180).contains(point.longitude),
              abs(point.latitude) > 1e-9 || abs(point.longitude) > 1e-9 else {
            throw unavailable("仿真起点必须是有效 WGS84 经纬度")
        }
        guard !telemetry.flying, !simulatorStatus.flying, !simulatorStatus.motorsOn else {
            throw unavailable("仿真飞机已在空中或电机已启动，不能切换起点")
        }
        guard !simulatorStatus.active else {
            throw unavailable("请先关闭 DJI 内置仿真器，再修改起点")
        }
        simulatorOrigin = point
        simulatorOriginExplicitlySet = true
        simulatorStatus.originLatitudeDegrees = point.latitude
        simulatorStatus.originLongitudeDegrees = point.longitude
        rawSimulatorStatePublisher.setOrigin(latitude: point.latitude, longitude: point.longitude)
        simulatorStatus.message = String(format: "仿真起点已保存：%.6f, %.6f", point.latitude, point.longitude)
        onSimulator?(simulatorStatus)
        onDiagnostic?("仿真", simulatorStatus.message)
    }

    func setSimulatorUpdateFrequency(_ hz: Int) {
        simulatorUpdateFrequencyHz = min(150, max(2, hz))
        onDiagnostic?("仿真", simulatorStatus.active
            ? "仿真源频率已设为 \(simulatorUpdateFrequencyHz) Hz；下次重启 Simulator 生效"
            : "仿真源频率已设为 \(simulatorUpdateFrequencyHz) Hz")
    }

    func refreshSimulatorStateCallback() -> Bool {
        guard let simulator = djiSimulator ?? flightController?.simulator,
              simulator.isSimulatorActive else { return false }
        djiSimulator = simulator
        installSimulatorDelegate(on: simulator)
        rawSimulatorStatePublisher.setOrigin(
            latitude: simulatorOrigin.latitude,
            longitude: simulatorOrigin.longitude
        )
        simulatorStatus.active = true
        simulatorStatus.stateReceived = false
        simulatorStatus.sampleMonotonicNanoseconds = 0
        simulatorStatus.message = "DJI Simulator 已激活，正在刷新 RAW State 回调"
        onSimulator?(simulatorStatus)
        onDiagnostic?("仿真", simulatorStatus.message)
        return true
    }

    private func installSimulatorDelegate(on simulator: DJISimulator) {
        if simulatorDelegateProxy != nil { djiSimulator?.delegate = nil }
        let generation = rawSimulatorStatePublisher.beginSession(active: true)
        let proxy = DJISimulatorDelegateSessionProxy(
            generation: generation,
            handler: { [weak self] simulator, state, generation in
                self?.publishSimulatorState(
                    simulator,
                    state: state,
                    sessionGeneration: generation
                )
            }
        )
        simulatorDelegateProxy = proxy
        simulator.delegate = proxy
    }

    func setRawSimulatorStateStore(_ store: RawSimulatorStateStore?) {
        rawSimulatorStatePublisher.install(store)
    }

    func simulateDisconnect() {}
    func simulateStaleTelemetry() {}
    func simulateManualTakeover() {}
    func simulateCameraError() {}

    private func isCurrentSDKProduct(_ candidate: DJIBaseProduct?) -> Bool {
        let current = DJISDKManager.product()
        switch (candidate, current) {
        case let (lhs?, rhs?): return lhs === rhs
        case (nil, nil): return true
        default: return false
        }
    }

    private func preferredCamera(on aircraft: DJIAircraft) -> DJICamera? {
        let connected = (aircraft.cameras ?? []).filter { $0.isConnected }
        return connected.first(where: { !$0.isThermalCamera() })
            ?? connected.first
            ?? aircraft.camera
    }

    private func preferredGimbal(on aircraft: DJIAircraft, camera: DJICamera?) -> DJIGimbal? {
        guard let camera else { return aircraft.gimbal }
        return (aircraft.gimbals ?? []).first(where: { $0.index == camera.index })
            ?? aircraft.gimbal
    }

    private func attach(_ product: DJIBaseProduct?) {
        guard let aircraft = product as? DJIAircraft else {
            publishDisconnected(product == nil ? "未检测到 DJI 产品" : "连接的产品不是飞机")
            return
        }
        sdkConnectionStarted = true
        let selectedCamera = preferredCamera(on: aircraft)
        let selectedGimbal = preferredGimbal(on: aircraft, camera: selectedCamera)
        let alreadyAttached = !needsFullAttach && self.aircraft === aircraft &&
            self.flightController === aircraft.flightController && self.djiCamera === selectedCamera
        if alreadyAttached {
            telemetry.remoteControllerConnected = aircraft.remoteController?.isConnected ?? false
            telemetry.connected = aircraft.flightController?.isConnected ?? false
            telemetry.connectionMessage = telemetry.connected ? "飞机与遥控器已连接" : "仅遥控器已连接"
            onTelemetry?(telemetry)
            return
        }
        // A direct productChanged callback can replace the Aircraft without an
        // intervening productDisconnected callback.  Stop the old VS session and
        // discard every flight-authorizing field before publishing the new one.
        invalidateVirtualStickSession(requestSDKDisable: true)
        telemetry = DJIFlightSessionTelemetryReset.make(
            from: telemetry,
            connected: aircraft.flightController?.isConnected ?? false,
            remoteControllerConnected: aircraft.remoteController?.isConnected ?? false,
            connectionMessage: aircraft.flightController?.isConnected == true
                ? "飞机与遥控器已连接" : "仅遥控器已连接"
        )
        rcModeMapping = [.unknown, .unknown, .unknown]
        lastFlightModeSwitchRaw = nil
        lastRCGPSAt = .distantPast
        productDiagnostics.removeAll()
        lastWarningSignature = ""
        lastReportedWarning = ""
        rawSimulatorStatePublisher.clear()
        lastFlightStateReceiptMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        simulatorLandingConfirmationPending = false
        needsFullAttach = false
        self.aircraft = aircraft
        aircraft.delegate = self
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        print("[DJI][产品] 已连接：\(aircraft.model ?? "unknown")")
        onDiagnostic?("DJI", "产品已连接：\(aircraft.model ?? "unknown")")
        self.flightController = aircraft.flightController
        djiSimulator?.delegate = nil
        simulatorDelegateProxy = nil
        self.djiSimulator = aircraft.flightController?.simulator
        self.djiCamera = selectedCamera
        self.djiGimbal = selectedGimbal
        cancelModelFrameCapture()
        latestFrame = nil
        liveVideoTimestamp = nil
        frameSequence = 0
        surveyReadbackGeneration += 1
        surveyReadbackValues.removeAll()
        surveyReadbackRequests.removeAll()
        camera.surveyCameraProfile = nil
        camera.surveyCameraUpdatedAt = .distantPast
        cameraHealthObserved = false
        cameraStorageStates.removeAll()
        selectedCameraStorageRawValue = nil
        mediaRefreshGeneration += 1
        mediaFilesByID.removeAll()
        telemetry.productModel = aircraft.model ?? "未知 DJI 产品"
        telemetry.cameraModel = selectedCamera?.displayName ?? "未识别相机"
        if telemetry.remoteControllerLocationSource != "iPhone 定位" {
            telemetry.remoteControllerLocationSource = "等待 RC / iPhone 定位"
        }
        telemetry.remoteControllerConnected = aircraft.remoteController?.isConnected ?? false
        telemetry.connected = aircraft.flightController?.isConnected ?? false
        telemetry.mode = telemetry.connected ? .manual : .disconnected
        telemetry.connectionMessage = telemetry.connected ? "飞机与遥控器已连接" : "仅遥控器已连接"
        aircraft.flightController?.delegate = self
        if let djiSimulator { installSimulatorDelegate(on: djiSimulator) }
        aircraft.battery?.delegate = self
        aircraft.remoteController?.delegate = self
        selectedCamera?.delegate = self
        aircraft.airLink?.delegate = self
        selectedGimbal?.delegate = self
        refreshFlightLimits()
        telemetry.timestamp = Date()
        camera.connected = selectedCamera != nil
        camera.recording = false
        camera.recordingSeconds = 0
        camera.sdInserted = false
        camera.storageReady = false
        camera.storageName = "存储"
        camera.photosRemaining = 0
        camera.message = selectedCamera == nil ? "未检测到相机" : "DJI 相机已连接"
        selectedCamera?.getStorageLocation { [weak self, weak selectedCamera] location, error in
            Task { @MainActor in
                guard let self, selectedCamera === self.djiCamera else { return }
                if let error {
                    self.onDiagnostic?("相机", "读取拍照存储位置失败：\(error.localizedDescription)")
                } else {
                    self.selectedCameraStorageRawValue = location.rawValue
                    self.refreshSelectedCameraStorage()
                }
            }
        }
        simulatorStatus = FlightSimulatorStatus(message: "当前飞机不提供 DJI 内置仿真器")
        if let simulator = aircraft.flightController?.simulator {
            simulatorStatus.available = true
            simulatorStatus.active = simulator.isSimulatorActive
            simulatorStatus.message = simulator.isSimulatorActive ? "DJI 内置仿真运行中" : "DJI 内置仿真器可用"
        }
        simulatorSessionRecoveryAllowed = simulatorStatus.active
        telemetry.simulatorActive = simulatorStatus.active
        onTelemetry?(telemetry)
        onCamera?(camera)
        onSimulator?(simulatorStatus)
        onDiagnostic?("仿真", simulatorStatus.message)
        if let selectedCamera {
            onDiagnostic?("相机", "已选择 \(selectedCamera.displayName) · payload index \(selectedCamera.index)\(selectedCamera.isThermalCamera() ? " · thermal" : "")")
        }
        beginPhoneChargingModeRefresh(for: aircraft.remoteController)
        loadRCFlightModeMapping()
        attachVideoFeed()
    }

    private func beginPhoneChargingModeRefresh(for remoteController: DJIRemoteController?) {
        invalidatePhoneChargingRead()
        guard let remoteController, remoteController.isConnected else {
            telemetry.rcPhoneChargingAvailable = false
            telemetry.rcPhoneChargingMode = "UNKNOWN"
            onTelemetry?(telemetry)
            return
        }
        telemetry.rcPhoneChargingAvailable = false
        telemetry.rcPhoneChargingMode = "READING"
        telemetry.timestamp = Date()
        onTelemetry?(telemetry)
        refreshPhoneChargingMode(
            for: remoteController,
            attempt: 0,
            generation: phoneChargingReadGeneration
        )
    }

    private func refreshPhoneChargingMode(
        for remoteController: DJIRemoteController,
        attempt: Int,
        generation: Int
    ) {
        guard generation == phoneChargingReadGeneration,
              aircraft?.remoteController === remoteController,
              remoteController.isConnected else { return }
        remoteController.getChargeMobileMode { [weak self, weak remoteController] mode, error in
            Task { @MainActor in
                guard let self, let remoteController,
                      self.aircraft?.remoteController === remoteController,
                      self.phoneChargingReadGeneration == generation else { return }
                self.telemetry.timestamp = Date()
                if let error {
                    let code = (error as NSError).code
                    self.telemetry.rcPhoneChargingAvailable = false
                    if DJIPhoneChargingReadPolicy.isExplicitlyUnsupported(errorCode: code) {
                        self.telemetry.rcPhoneChargingMode = "UNSUPPORTED"
                        self.onDiagnostic?("DJI", "当前遥控器或固件明确不支持手机充电控制：\(error.localizedDescription) (code:\(code))")
                    } else if let delay = DJIPhoneChargingReadPolicy.retryDelaySeconds(afterAttempt: attempt) {
                        self.telemetry.rcPhoneChargingMode = "READING"
                        self.onDiagnostic?("DJI", "手机充电模式读取暂未就绪：\(error.localizedDescription) (code:\(code))；\(delay)s 后重试")
                        self.schedulePhoneChargingRead(
                            for: remoteController,
                            attempt: attempt + 1,
                            generation: generation,
                            delaySeconds: delay
                        )
                    } else {
                        self.telemetry.rcPhoneChargingMode = "READ_FAILED"
                        self.onDiagnostic?("DJI", "手机充电模式连续读取失败：\(error.localizedDescription) (code:\(code))；仍可手动尝试开启")
                    }
                } else {
                    self.telemetry.rcPhoneChargingAvailable = true
                    self.telemetry.rcPhoneChargingMode = self.phoneChargingModeName(mode)
                    self.onDiagnostic?("DJI", "遥控器手机充电模式：\(self.telemetry.rcPhoneChargingMode)")
                }
                self.onTelemetry?(self.telemetry)
            }
        }
    }

    private func schedulePhoneChargingRead(
        for remoteController: DJIRemoteController,
        attempt: Int,
        generation: Int,
        delaySeconds: UInt64
    ) {
        phoneChargingReadTask?.cancel()
        phoneChargingReadTask = Task { [weak self, weak remoteController] in
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, let remoteController,
                  self.phoneChargingReadGeneration == generation else { return }
            self.refreshPhoneChargingMode(
                for: remoteController,
                attempt: attempt,
                generation: generation
            )
        }
    }

    private func invalidatePhoneChargingRead() {
        phoneChargingReadGeneration += 1
        phoneChargingReadTask?.cancel()
        phoneChargingReadTask = nil
    }

    private func phoneChargingModeName(_ mode: DJIRCChargeMobileMode) -> String {
        switch mode.rawValue {
        case 0: return "NEVER"
        case 1: return "ALWAYS"
        case 2: return "INTELLIGENT"
        default: return "UNKNOWN"
        }
    }

    private func loadRCFlightModeMapping() {
        flightController?.getRCSwitchFlightModeMapping(completion: { [weak self] mapping, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.onDiagnostic?("DJI", "读取遥控器档位映射失败：\(error.localizedDescription)")
                    return
                }
                guard let mapping, mapping.count >= 3 else {
                    self.onDiagnostic?("DJI", "遥控器未返回三档映射")
                    return
                }
                self.rcModeMapping = mapping.prefix(3).map { self.profile(forRemoteModeRaw: $0.intValue) }
                let labels = self.rcModeMapping.map { "\($0.shortLabel)-\($0.label)" }.joined(separator: "/")
                self.onDiagnostic?("DJI", "遥控器档位映射：\(labels)")
                if let raw = self.lastFlightModeSwitchRaw, self.rcModeMapping.indices.contains(raw) {
                    self.telemetry.rcFlightProfile = self.rcModeMapping[raw]
                    self.onDiagnostic?("DJI", "映射后当前档位：\(self.telemetry.rcFlightProfile.shortLabel)-\(self.telemetry.rcFlightProfile.label)")
                    self.onTelemetry?(self.telemetry)
                }
            }
        })
    }

    private func profile(forRemoteModeRaw raw: Int) -> RCFlightProfile {
        switch raw {
        case 0: return .normal // P
        case 2: return .sport  // S
        case 3, 6: return .cine // G / T
        default: return .unknown
        }
    }

    private func attachVideoFeed() {
        videoFeed?.remove(self)
        DJISDKManager.videoFeeder()?.remove(self)
        let feed = preferredVideoFeed()
        videoFeed = feed
        configurePreviewer()
        DJIVideoPreviewer.instance()?.frameControlHandler = self
        DJISDKManager.videoFeeder()?.add(self)
        feed?.add(self, with: videoFeedQueue)
    }

    private func preferredVideoFeed() -> DJIVideoFeed? {
        guard let feeder = DJISDKManager.videoFeeder() else { return nil }
        let primary = feeder.primaryVideoFeed
        let secondary = feeder.secondaryVideoFeed
        let feeds = [primary, secondary]
        if let selectedCamera = djiCamera,
           (aircraft?.cameras?.count ?? 0) > 1 {
            // M210/M300 payload indices 0/1/2 map to left/right/top physical
            // camera sources 6/7/8. Feed array order itself is not stable.
            let expectedRaw = 6 + Int(selectedCamera.index)
            if let exact = feeds.first(where: { Int($0.physicalSource.rawValue) == expectedRaw }) {
                return exact
            }
        }
        // Never choose the dedicated FPV channel (raw 1) for mapping/VLN when
        // a payload camera feed is available.
        return feeds.first(where: {
            let raw = Int($0.physicalSource.rawValue)
            return raw != 1 && raw != 0xFF
        }) ?? primary
    }

    private func configurePreviewer() {
        let previewer = DJIVideoPreviewer.instance()
        let cameraName = djiCamera?.displayName
        if cameraName == DJICameraDisplayNameDJIMini2Camera {
            previewer?.encoderType = ._DJIMini2
        } else if cameraName == DJICameraDisplayNameMavicMiniCamera {
            previewer?.encoderType = ._MavicMini
        } else {
            previewer?.encoderType = ._unknown
        }
        previewer?.contentClipRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        previewer?.clearVideoData()
        previewer?.reset()
        previewer?.safeResume()
        onDiagnostic?("视频", "解码适配：\(cameraName ?? "等待相机型号")")
    }

    private func publishDisconnected(_ reason: String) {
        invalidatePhoneChargingRead()
        needsFullAttach = true
        print("[DJI][断开] \(reason)")
        onDiagnostic?("错误", reason)
        // Fail closed across product/session boundaries. A command timer and
        // cached non-zero command must never survive long enough to reach a
        // newly attached flight controller.
        invalidateVirtualStickSession(requestSDKDisable: false)
        simulatorLandingConfirmationPending = false
        rcModeMapping = [.unknown, .unknown, .unknown]
        lastFlightModeSwitchRaw = nil
        lastRCGPSAt = .distantPast
        lastFlightStateReceiptMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        productDiagnostics.removeAll()
        lastWarningSignature = ""
        lastReportedWarning = ""
        cancelModelFrameCapture()
        videoFeed?.remove(self)
        DJISDKManager.videoFeeder()?.remove(self)
        videoFeed = nil
        latestFrame = nil
        liveVideoTimestamp = nil
        frameSequence = 0
        awaitingReconnectFrame = false
        aircraft = nil
        flightController = nil
        djiSimulator?.delegate = nil
        djiSimulator = nil
        simulatorDelegateProxy = nil
        rawSimulatorStatePublisher.beginSession(active: false)
        djiCamera = nil
        djiGimbal = nil
        telemetry = DJIFlightSessionTelemetryReset.make(
            from: telemetry, connected: false, remoteControllerConnected: false,
            connectionMessage: reason
        )
        telemetry.productModel = "未识别"
        telemetry.cameraModel = "未识别相机"
        camera.connected = false
        camera.recording = false
        camera.recordingSeconds = 0
        camera.sdInserted = false
        camera.storageReady = false
        camera.photosRemaining = 0
        camera.storageName = "存储"
        camera.message = reason
        cameraStorageStates.removeAll()
        selectedCameraStorageRawValue = nil
        mediaRefreshGeneration += 1
        mediaFilesByID.removeAll()
        surveyReadbackGeneration += 1
        surveyReadbackValues.removeAll()
        surveyReadbackRequests.removeAll()
        camera.surveyCameraProfile = nil
        camera.surveyCameraUpdatedAt = .distantPast
        cameraHealthObserved = false
        simulatorStatus = FlightSimulatorStatus(message: "等待 DJI 飞机连接")
        onTelemetry?(telemetry)
        onCamera?(camera)
        onSimulator?(simulatorStatus)
    }

    private func refreshSelectedCameraStorage() {
        let sdRaw = DJICameraStorageLocation.sdCard.rawValue
        let selected = selectedCameraStorageRawValue.flatMap { cameraStorageStates[$0] }
        let effective = selected
            ?? cameraStorageStates[sdRaw]
            ?? cameraStorageStates.values.first(where: { $0.ready })
            ?? cameraStorageStates.values.first
        if let sd = cameraStorageStates[sdRaw] { camera.sdInserted = sd.inserted }
        guard let effective else {
            camera.storageReady = false
            camera.photosRemaining = 0
            return
        }
        let previousReady = camera.captureStorageReady
        camera.storageReady = effective.ready
        camera.storageName = effective.name
        camera.photosRemaining = effective.photosRemaining
        if let failure = effective.failure {
            camera.message = "\(effective.name)不可用：\(failure)"
        } else if !camera.recording && !camera.message.contains("写入") {
            camera.message = "相机就绪 · \(effective.name)"
        }
        if previousReady != effective.ready {
            onDiagnostic?("相机", effective.ready
                ? "\(effective.name)已就绪 · 剩余约 \(effective.photosRemaining) 张"
                : "\(effective.name)不可用于拍照：\(effective.failure ?? "未知原因")")
        }
        onCamera?(camera)
    }

    private func refreshFlightLimits() {
        guard let controller = flightController else { return }
        controller.getGoHomeHeightInMeters { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.flightController === controller else { return }
                if error == nil { self.telemetry.goHomeHeightMeters = Int(value); self.onTelemetry?(self.telemetry) }
            }
        }
        controller.getMaxFlightHeight { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.flightController === controller else { return }
                if error == nil { self.telemetry.maxFlightHeightMeters = Int(value); self.onTelemetry?(self.telemetry) }
            }
        }
        controller.getMaxFlightRadius { [weak self] value, error in
            Task { @MainActor in
                guard let self, self.flightController === controller else { return }
                if error == nil { self.telemetry.maxFlightRadiusMeters = Int(value); self.onTelemetry?(self.telemetry) }
            }
        }
        controller.getMaxFlightRadiusLimitationEnabled { [weak self] enabled, error in
            Task { @MainActor in
                guard let self, self.flightController === controller else { return }
                if error == nil { self.telemetry.maxFlightRadiusEnabled = enabled; self.onTelemetry?(self.telemetry) }
            }
        }
    }

    private func publishCameraMessage(_ message: String) {
        camera.message = message
        onCamera?(camera)
    }

    nonisolated private func publishCommandResult(_ operation: String, _ error: Error?) {
        Task { @MainActor in
            if let error {
                self.publishCameraMessage("\(operation)失败：\(error.localizedDescription)")
                self.onDiagnostic?("错误", "\(operation)失败：\(error.localizedDescription)")
            } else {
                self.onDiagnostic?("DJI", "\(operation)指令执行成功")
            }
        }
    }

    private func requireFlightController() throws -> DJIFlightController {
        guard telemetry.connected, let flightController else { throw unavailable("DJI 飞控未连接") }
        return flightController
    }

    private func unavailable(_ reason: String) -> FlightActionError { .unavailable(reason) }

    private func startCommandTimer() {
        stopCommandTimer()
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendCurrentCommand() }
        }
        commandTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopCommandTimer() {
        commandTimer?.invalidate()
        commandTimer = nil
    }

    private func sendCurrentCommand() {
        guard virtualStickEnabled, let flightController else { return }
        let command = VirtualStickCommandLeasePolicy.appliedCommand(
            desired: desiredCommand,
            refreshedAt: desiredCommandRefreshedAt
        )
        if command.isZero, !desiredCommand.isZero {
            desiredCommand = .zero
            if !commandLeaseExpired {
                commandLeaseExpired = true
                onDiagnostic?(
                    "安全",
                    "Virtual Stick 非零指令超过 1 秒未刷新，已自动归零"
                )
            }
        }
        let axes = BodyVelocityToDJIAxes.map(command)
        let data = DJIVirtualStickFlightControlData(
            pitch: Float(axes.pitch),
            roll: Float(axes.roll),
            yaw: Float(axes.yaw),
            verticalThrottle: Float(axes.verticalThrottle)
        )
        if lastCommandWasZero && !command.isZero {
            onDiagnostic?("控制", String(
                format: "开始发送 VS：前 %.2f 右 %.2f 上 %.2f → DJI roll %.2f pitch %.2f vertical %.2f",
                command.forward, command.right, command.up,
                axes.roll, axes.pitch, axes.verticalThrottle
            ))
        }
        lastCommandWasZero = command.isZero
        flightController.send(data) { [weak self] error in
            guard let error else {
                Task { @MainActor in self?.lastVirtualStickSendError = nil }
                return
            }
            Task { @MainActor in
                guard let self else { return }
                guard self.virtualStickRequestedEnabled, self.virtualStickEnabled else { return }
                let message = error.localizedDescription
                guard self.lastVirtualStickSendError != message else { return }
                self.lastVirtualStickSendError = message
                self.onDiagnostic?("错误", "Virtual Stick 发送失败：\(message)")
                self.onVirtualStickSendFailure?(message)
            }
        }
    }

    private func validAssessmentSeconds(_ value: UInt) -> Int {
        value > 0 && value < 86_400 ? Int(value) : 0
    }

    private func validAssessmentPercent(_ value: UInt) -> Int {
        value <= 100 ? Int(value) : 0
    }

    private func startDecodedFrameCaptureIfNeeded() {
        guard !modelFrameCaptureInFlight else { return }
        modelFrameCaptureInFlight = true
        advanceDecodedFrameGeneration()
        DJIVideoPreviewer.instance()?.registFrameProcessor(self)
    }

    private func cancelModelFrameCapture() {
        DJIVideoPreviewer.instance()?.unregistFrameProcessor(self)
        modelFrameCaptureInFlight = false
        advanceDecodedFrameGeneration()
    }

    nonisolated private func enqueueLiveVideoPublication(
        feed: DJIVideoFeed,
        receivedAt: Date,
        monotonicNanoseconds: UInt64
    ) -> Bool {
        liveVideoPublicationLock.lock()
        defer { liveVideoPublicationLock.unlock() }
        pendingLiveVideoPublication = (feed, receivedAt)
        guard !liveVideoPublicationScheduled else { return false }
        // The encoded DJI feed can deliver hundreds of packets per second.
        // Freshness only needs a periodic boundary timestamp; posting one
        // MainActor task per packet made SwiftUI/video compete and heated the
        // phone without improving control or preview latency.
        guard lastLiveVideoPublicationScheduledAt == 0
                || monotonicNanoseconds - lastLiveVideoPublicationScheduledAt >= 250_000_000
        else { return false }
        lastLiveVideoPublicationScheduledAt = monotonicNanoseconds
        liveVideoPublicationScheduled = true
        return true
    }

    nonisolated private func takeLiveVideoPublication() -> (DJIVideoFeed, Date)? {
        liveVideoPublicationLock.lock()
        defer { liveVideoPublicationLock.unlock() }
        let value = pendingLiveVideoPublication
        pendingLiveVideoPublication = nil
        liveVideoPublicationScheduled = false
        return value
    }

    private func publishPendingLiveVideoTimestamp() {
        guard let (feed, receivedAt) = takeLiveVideoPublication(),
              feed == videoFeed else { return }
        guard liveVideoTimestamp.map({ receivedAt >= $0 }) ?? true else { return }
        let firstOrRecovered = liveVideoTimestamp.map {
            receivedAt.timeIntervalSince($0) > 2.5
        } ?? true
        liveVideoTimestamp = receivedAt
        if firstOrRecovered {
            onDiagnostic?("视频", "DJI 实时图传数据已就绪")
            // Wake the view model once on first packet/recovery without
            // flooding SwiftUI at video packet rate.
            onCamera?(camera)
        }
    }

    nonisolated private func advanceDecodedFrameGeneration() {
        decodedFrameClaimLock.lock()
        decodedFrameGeneration &+= 1
        decodedFrameClaimed = false
        decodedFrameClaimLock.unlock()
    }

    nonisolated private func claimDecodedFrame() -> Int? {
        decodedFrameClaimLock.lock()
        defer { decodedFrameClaimLock.unlock() }
        guard !decodedFrameClaimed else { return nil }
        decodedFrameClaimed = true
        return decodedFrameGeneration
    }

    nonisolated private func isCurrentDecodedFrameGeneration(_ generation: Int) -> Bool {
        decodedFrameClaimLock.lock()
        defer { decodedFrameClaimLock.unlock() }
        return generation == decodedFrameGeneration
    }

    nonisolated private func releaseDecodedFrameClaim(generation: Int) {
        decodedFrameClaimLock.lock()
        defer { decodedFrameClaimLock.unlock() }
        guard generation == decodedFrameGeneration else { return }
        decodedFrameClaimed = false
    }

    private func updateProductDiagnostics(_ diagnostics: [DJIDiagnostics]) {
        var unique: [String: FlightWarning] = [:]
        for item in diagnostics {
            // Mini 2 reports legacy camera-encryption code 1004 while its camera and
            // live view remain operational. DJI Fly does not expose it to the pilot.
            let suppressMini2EncryptionDiagnostic = item.code == 1004 && camera.connected && telemetry.productModel.contains("Mini 2")
            guard !suppressMini2EncryptionDiagnostic else { continue }
            let reason = localizedDiagnosticText(item.reason) ?? ""
            let solution = localizedDiagnosticText(item.solution)
            let id = "dji-\(item.component.rawValue)-\(item.componentIndex)-\(item.code)"
            let title = reason.isEmpty ? "DJI 设备状态异常" : reason
            let detail: String?
            if solution?.isEmpty == false {
                detail = solution
            } else if title == "DJI 设备状态异常" {
                detail = AppLocalization.string(
                    "DJI 未提供可读故障原因。若仿真无法解锁，请关闭并重启飞机，待遥控器重新连接后再试。"
                )
            } else {
                detail = nil
            }
            unique[id] = FlightWarning(
                id: id,
                severity: diagnosticSeverity(code: item.code, reason: reason),
                title: title,
                detail: detail,
                code: item.code
            )
        }
        productDiagnostics = Array(unique.values)
        refreshWarnings()
    }

    private func localizedDiagnosticText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for bundle in diagnosticsLocalizationBundles {
            let localized = bundle.localizedString(forKey: trimmed, value: trimmed, table: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if localized != trimmed { return localized }
        }
        return diagnosticKeyFallback(trimmed)
    }

    private func diagnosticKeyFallback(_ key: String) -> String {
        switch key {
        case "dji_check_camera_encrypt_error_reason":
            return "相机加密校验失败"
        case "dji_check_camera_encrypt_error_solution":
            return "请重启飞行器；如果问题仍然存在，请联系 DJI 售后服务。"
        default:
            return key.hasPrefix("dji_") ? "DJI 设备状态异常" : key
        }
    }

    private func diagnosticSeverity(code: Int, reason: String) -> FlightWarningSeverity {
        let normalized = reason.lowercased()
        if normalized.contains("critical") || normalized.contains("严重") || normalized.contains("不可起飞") {
            return .critical
        }
        if normalized.contains("error") || normalized.contains("故障") || normalized.contains("异常") {
            return .warning
        }
        if code == 8025 || code == 8043 || code == 8057 || normalized.contains("gps") || normalized.contains("gnss") || normalized.contains("atti") {
            return .caution
        }
        return .warning
    }

    private func refreshWarnings() {
        var warnings = productDiagnostics.filter { warning in
            !(warning.code == 1004 && cameraHealthObserved)
        }
        let hasDJIGPSWarning = warnings.contains { warning in
            warning.code == 8025 || warning.code == 8043 ||
                warning.title.localizedCaseInsensitiveContains("GPS") ||
                warning.title.localizedCaseInsensitiveContains("GNSS")
        }

        if telemetry.connected, !hasDJIGPSWarning {
            switch telemetry.gpsSignalLevel {
            case 6, 0:
                warnings.append(FlightWarning(
                    id: "gps-signal",
                    severity: .caution,
                    title: "GPS 无信号，谨慎起飞",
                    detail: "飞行器无法可靠定位，返航点可能无法记录。请在开阔区域等待 GNSS 信号恢复。",
                    code: nil
                ))
            case 1:
                warnings.append(FlightWarning(
                    id: "gps-signal",
                    severity: .caution,
                    title: "GPS 信号很弱，谨慎起飞",
                    detail: "当前定位可靠性不足，请避免远距离飞行。",
                    code: nil
                ))
            case 2:
                warnings.append(FlightWarning(
                    id: "gps-signal",
                    severity: .notice,
                    title: "GPS 信号较弱",
                    detail: "返航可用，但建议等待信号增强后再起飞。",
                    code: nil
                ))
            default:
                break
            }
        }

        if telemetry.connected, !telemetry.homeLocationSet, telemetry.gpsSignalLevel >= 3, telemetry.gpsSignalLevel <= 5 {
            warnings.append(FlightWarning(
                id: "home-point",
                severity: .notice,
                title: "返航点尚未记录",
                detail: "请等待返航点记录成功后再进行远距离飞行。",
                code: nil
            ))
        }

        telemetry.warnings = warnings.sorted {
            if $0.id == "gps-signal", $1.severity != .critical { return true }
            if $1.id == "gps-signal", $0.severity != .critical { return false }
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.id < $1.id
        }
        let signature = telemetry.warnings.map { "\($0.id):\($0.title)" }.joined(separator: "|")
        if signature != lastWarningSignature {
            lastWarningSignature = signature
            if let warning = telemetry.highestPriorityWarning {
                let message = "\(warning.title)\(warning.code.map { " [\($0)]" } ?? "")"
                if message != lastReportedWarning {
                    lastReportedWarning = message
                    onDiagnostic?("告警", message)
                }
            } else if !lastReportedWarning.isEmpty {
                lastReportedWarning = ""
                onDiagnostic?("DJI", "飞行告警已清除")
            }
        }
        onTelemetry?(telemetry)
    }
}

extension DJIFlightProviderV4: DJISDKManagerDelegate {
    nonisolated func didUpdateDatabaseDownloadProgress(_ progress: Progress) {}

    nonisolated func appRegisteredWithError(_ error: Error?) {
        Task { @MainActor in
            if let error {
                print("[DJI][注册] 失败：\(error.localizedDescription)")
                self.publishDisconnected("MSDK 注册失败：\(error.localizedDescription)")
            } else {
                print("[DJI][注册] 成功，开始连接产品")
                self.telemetry.sdkRegistered = true
                self.telemetry.connectionMessage = "MSDK 已注册，等待产品"
                self.onTelemetry?(self.telemetry)
                self.onDiagnostic?("DJI", "MSDK 注册成功，开始连接产品")
                self.refreshDJIAccount()
                self.resumeConnection()
            }
        }
    }

    nonisolated func productConnected(_ product: DJIBaseProduct?) {
        print("[DJI][回调] productConnected")
        Task { @MainActor in
            guard self.isCurrentSDKProduct(product) else { return }
            self.attach(product)
        }
    }

    nonisolated func productChanged(_ product: DJIBaseProduct?) {
        Task { @MainActor in
            guard self.isCurrentSDKProduct(product) else { return }
            self.attach(product)
        }
    }

    nonisolated func productDisconnected() {
        Task { @MainActor in
            guard DJISDKManager.product() == nil else { return }
            DJISDKManager.stopConnectionToProduct()
            self.sdkConnectionStarted = false
            self.publishDisconnected("DJI 产品已断开，等待自动重连")
            self.startReconnectTimer()
        }
    }
}

extension DJIFlightProviderV4: DJIBaseProductDelegate {
    nonisolated func product(_ product: DJIBaseProduct, didUpdateDiagnosticsInformation info: [Any]) {
        let diagnostics = info.compactMap { $0 as? DJIDiagnostics }
        Task { @MainActor in
            guard product === self.aircraft else { return }
            self.updateProductDiagnostics(diagnostics)
        }
    }
}

extension DJIFlightProviderV4: DJIFlightControllerDelegate {
    nonisolated func flightController(_ fc: DJIFlightController, didUpdate state: DJIFlightControllerState) {
        let receipt = DJIFlightStateReceipt.capture()
        Task { @MainActor in
            guard fc === self.flightController else { return }
            guard receipt.isNewer(than: self.lastFlightStateReceiptMonotonicNanoseconds) else { return }
            self.lastFlightStateReceiptMonotonicNanoseconds = receipt.monotonicNanoseconds
            self.telemetry.aircraftLocationValid = false
            if let location = state.aircraftLocation?.coordinate,
               CLLocationCoordinate2DIsValid(location),
               abs(location.latitude) > 0.000001 || abs(location.longitude) > 0.000001 {
                self.telemetry.aircraft = GeoPoint(latitude: location.latitude, longitude: location.longitude)
                self.telemetry.aircraftLocationValid = true
            }
            let homeCoordinate = state.homeLocation?.coordinate
            let homeCoordinateUsable = homeCoordinate.map {
                CLLocationCoordinate2DIsValid($0)
                    && (abs($0.latitude) > 0.000001 || abs($0.longitude) > 0.000001)
            } == true
            if let location = homeCoordinate, homeCoordinateUsable {
                self.telemetry.home = GeoPoint(latitude: location.latitude, longitude: location.longitude)
            }
            self.telemetry.connected = true
            self.telemetry.connectionMessage = "飞控遥测正常"
            self.telemetry.flying = state.isFlying
            self.telemetry.simulatorActive = self.simulatorStatus.active
            self.telemetry.positionSource = self.simulatorStatus.active ? "DJI 内置仿真" : (self.telemetry.aircraftLocationValid ? "DJI GPS" : "NED 速度 / OPTI")
            if state.isFailsafeEnabled {
                self.telemetry.mode = .emergency
            } else {
                switch state.flightMode {
                case .goHome:
                    self.telemetry.mode = .returningHome
                case .autoLanding, .confirmLanding:
                    self.telemetry.mode = .landing
                default:
                    self.telemetry.mode = state.isFlying
                        ? (self.telemetry.aircraftLocationValid ? .gps : .opti)
                        : .manual
                }
            }
            self.telemetry.altitude = state.altitude
            self.telemetry.asl = Double(state.takeoffLocationAltitude) + state.altitude
            let downwardHeight = state.ultrasonicHeightInMeters
            self.telemetry.downwardHeightValid = state.isUltrasonicBeingUsed &&
                !state.doesUltrasonicHaveError && downwardHeight.isFinite && downwardHeight > 0
            self.telemetry.downwardHeight = self.telemetry.downwardHeightValid ? downwardHeight : 0
            self.telemetry.horizontalSpeed = hypot(Double(state.velocityX), Double(state.velocityY))
            self.telemetry.verticalSpeed = -Double(state.velocityZ)
            self.telemetry.velocityNorth = Double(state.velocityX)
            self.telemetry.velocityEast = Double(state.velocityY)
            self.telemetry.velocityDown = Double(state.velocityZ)
            self.telemetry.heading = Double(state.attitude.yaw)
            self.telemetry.aircraftRoll = Double(state.attitude.roll)
            self.telemetry.aircraftPitch = Double(state.attitude.pitch)
            self.telemetry.aircraftYaw = Double(state.attitude.yaw)
            self.telemetry.satellites = Int(state.satelliteCount)
            self.telemetry.gpsSignalLevel = Int(state.gpsSignalLevel.rawValue)
            // DJI can transiently report `isHomeLocationSet` before exposing a
            // usable coordinate. Never publish a stale/zero Home marker or use
            // it as a survey return target during that transition.
            self.telemetry.homeLocationSet = state.isHomeLocationSet && homeCoordinateUsable
            let assessment = state.goHomeAssessment
            self.telemetry.remainingFlightTimeSeconds = self.validAssessmentSeconds(assessment.remainingFlightTime)
            self.telemetry.timeNeededToGoHomeSeconds = self.validAssessmentSeconds(assessment.timeNeededToGoHome)
            self.telemetry.timeNeededToLandSeconds = self.validAssessmentSeconds(assessment.timeNeededToLandFromCurrentHeight)
            self.telemetry.batteryNeededToGoHomePercent = self.validAssessmentPercent(assessment.batteryPercentageNeededToGoHome)
            self.telemetry.batteryNeededToLandPercent = self.validAssessmentPercent(assessment.batteryPercentageNeededToLandFromCurrentHeight)
            self.telemetry.smartReturnToHomeState = switch assessment.smartRTHState.rawValue {
            case 0: "IDLE"
            case 1: "COUNTING_DOWN"
            case 2: "EXECUTED"
            case 3: "CANCELLED"
            default: "UNKNOWN"
            }
            self.telemetry.smartReturnToHomeCountdownSeconds =
                assessment.smartRTHState.rawValue == 1 ? max(0, assessment.smartRTHCountdown) : 0
            let radius = Double(assessment.maxRadiusAircraftCanFlyAndGoHome)
            self.telemetry.maxSafeFlightRadiusMeters = radius.isFinite && radius > 0 ? radius : 0
            let flightStateTimestamp = receipt.wallClock
            self.telemetry.timestamp = flightStateTimestamp
            self.telemetry.flightStateTimestamp = flightStateTimestamp
            self.telemetry.landingConfirmationNeeded = state.isLandingConfirmationNeeded && !self.simulatorStatus.active
            if self.simulatorStatus.active, state.isLandingConfirmationNeeded, !self.simulatorLandingConfirmationPending {
                self.simulatorLandingConfirmationPending = true
                self.onDiagnostic?("仿真", "检测到近地落地确认，自动确认")
                fc.confirmLanding { [weak self] error in
                    Task { @MainActor in
                        guard let self, fc === self.flightController else { return }
                        self.simulatorLandingConfirmationPending = false
                        if let error { self.onDiagnostic?("错误", "仿真落地确认失败：\(error.localizedDescription)") }
                        else { self.onDiagnostic?("仿真", "近地落地已确认") }
                    }
                }
            }
            self.refreshWarnings()
        }
    }
}

extension DJIFlightProviderV4 {
    nonisolated fileprivate func publishSimulatorState(
        _ simulator: DJISimulator,
        state: DJISimulatorState,
        sessionGeneration: UInt64
    ) {
        let sampleReceivedAt = DispatchTime.now().uptimeNanoseconds
        let message: String
        if state.isFlying {
            message = String(
                format: "仿真飞行中 · X %.1f Y %.1f Z %.1f m",
                state.positionX, state.positionY, state.positionZ
            )
        } else if state.areMotorsOn {
            message = "仿真电机已启动，等待离地"
        } else {
            message = "DJI 内置仿真已就绪，等待内八解锁或自动起飞"
        }
        let raw = FlightSimulatorStatus(
            available: true,
            active: simulator.isSimulatorActive,
            stateReceived: true,
            motorsOn: state.areMotorsOn,
            flying: state.isFlying,
            positionX: Double(state.positionX),
            positionY: Double(state.positionY),
            positionZ: Double(state.positionZ),
            rollDegrees: Double(state.roll),
            pitchDegrees: -Double(state.pitch),
            yawDegrees: Double(state.yaw),
            sampleMonotonicNanoseconds: sampleReceivedAt,
            measuredUpdateHz: 0,
            message: message
        )
        guard let publication = rawSimulatorStatePublisher.publish(
            sessionGeneration: sessionGeneration, raw, receivedAt: sampleReceivedAt
        ), publication.shouldPublishUI else { return }
        Task { @MainActor in
            if publication.state.active { self.simulatorSessionRecoveryAllowed = true }
            guard sampleReceivedAt > self.simulatorStatus.sampleMonotonicNanoseconds else { return }
            self.simulatorStatus = publication.state
            self.telemetry.simulatorActive = self.simulatorStatus.active
            self.telemetry.positionSource = self.simulatorStatus.active ? "DJI 内置仿真" : self.telemetry.positionSource
            self.onSimulator?(self.simulatorStatus)
            self.onTelemetry?(self.telemetry)
            if publication.streamStarted {
                self.onDiagnostic?("仿真", "RAW SimulatorState 首帧已接收")
            }
            if publication.rateBecameAvailable {
                self.onDiagnostic?(
                    "仿真",
                    String(format: "RAW SimulatorState 持续推送 %.1f Hz", publication.state.measuredUpdateHz)
                )
            }
            if publication.stateChanged {
                self.onDiagnostic?("仿真", "状态：motors=\(publication.state.motorsOn) flying=\(publication.state.flying) · \(self.simulatorStatus.message)")
            }
        }
    }
}

extension DJIFlightProviderV4: DJIBatteryDelegate {
    nonisolated func battery(_ battery: DJIBattery, didUpdate state: DJIBatteryState) {
        Task { @MainActor in
            guard battery === self.aircraft?.battery else { return }
            self.telemetry.aircraftBattery = Int(state.chargeRemainingInPercent)
            self.onTelemetry?(self.telemetry)
        }
    }
}

extension DJIFlightProviderV4: DJIRemoteControllerDelegate {
    nonisolated func remoteController(_ rc: DJIRemoteController, didUpdate state: DJIRCHardwareState) {
        let leftHorizontal = state.leftStick.horizontalPosition
        let leftVertical = state.leftStick.verticalPosition
        let rightHorizontal = state.rightStick.horizontalPosition
        let rightVertical = state.rightStick.verticalPosition
        // DJI stick values are [-660, 660]. A 50-count deadband rejects normal
        // centering noise while still making a deliberate stick input preempt VLN.
        let moved = abs(leftHorizontal) > 50 || abs(leftVertical) > 50 ||
            abs(rightHorizontal) > 50 || abs(rightVertical) > 50
        Task { @MainActor in
            guard rc === self.aircraft?.remoteController else { return }
            self.telemetry.remoteControllerConnected = true
            self.telemetry.sticksActive = moved
            let raw = Int(state.flightModeSwitch.rawValue)
            if self.rcModeMapping.indices.contains(raw) {
                self.telemetry.rcFlightProfile = self.rcModeMapping[raw]
            } else {
                self.telemetry.rcFlightProfile = .unknown
            }
            if self.lastFlightModeSwitchRaw != raw {
                self.lastFlightModeSwitchRaw = raw
                self.onDiagnostic?("DJI", "遥控器当前档位：position=\(raw + 1)，\(self.telemetry.rcFlightProfile.shortLabel)-\(self.telemetry.rcFlightProfile.label)")
            }
            if self.virtualStickEnabled, moved, !self.takeoverLatched {
                self.takeoverLatched = true
                self.desiredCommand = .zero
                self.sendCurrentCommand()
                self.onDiagnostic?("接管", "遥控器摇杆 L(\(leftHorizontal),\(leftVertical)) R(\(rightHorizontal),\(rightVertical))，立即释放 VLN")
                self.onManualTakeover?()
            } else if !moved {
                self.takeoverLatched = false
            }
            self.onTelemetry?(self.telemetry)
        }
    }

    nonisolated func remoteController(_ rc: DJIRemoteController, didUpdate gpsData: DJIRCGPSData) {
        guard gpsData.isValid.boolValue, CLLocationCoordinate2DIsValid(gpsData.location) else { return }
        Task { @MainActor in
            guard rc === self.aircraft?.remoteController else { return }
            self.lastRCGPSAt = Date()
            let sourceChanged = self.telemetry.remoteControllerLocationSource != "遥控器 GPS"
            self.telemetry.remoteController = GeoPoint(latitude: gpsData.location.latitude, longitude: gpsData.location.longitude)
            self.telemetry.remoteControllerLocationSource = "遥控器 GPS"
            if sourceChanged { self.onDiagnostic?("定位", "遥控器位置已切换为 RC GPS") }
            self.onTelemetry?(self.telemetry)
        }
    }

    nonisolated func remoteController(_ rc: DJIRemoteController, didUpdate batteryState: DJIRCBatteryState) {
        Task { @MainActor in
            guard rc === self.aircraft?.remoteController else { return }
            self.telemetry.rcBattery = Int(batteryState.remainingChargeInPercent)
            self.onTelemetry?(self.telemetry)
        }
    }
}

extension DJIFlightProviderV4: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0, newHeading.headingAccuracy <= 45,
              abs(newHeading.timestamp.timeIntervalSinceNow) <= 10 else { return }
        let usesTrueNorth = newHeading.trueHeading >= 0
        let heading = usesTrueNorth ? newHeading.trueHeading : newHeading.magneticHeading
        guard heading.isFinite else { return }
        Task { @MainActor in
            self.telemetry.remoteControllerHeading = heading
            self.telemetry.remoteControllerHeadingSource = usesTrueNorth ? "iPhone 真北" : "iPhone 磁北"
            self.onTelemetry?(self.telemetry)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 500,
              abs(location.timestamp.timeIntervalSinceNow) <= 10,
              CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        Task { @MainActor in
            guard self.foreground, Date().timeIntervalSince(self.lastRCGPSAt) > 5 else { return }
            let sourceChanged = self.telemetry.remoteControllerLocationSource != "iPhone 定位"
            self.telemetry.remoteController = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            self.telemetry.remoteControllerLocationSource = "iPhone 定位"
            self.locationErrorReported = false
            if sourceChanged {
                self.onDiagnostic?("定位", "遥控器位置使用 iPhone 定位，精度约 \(Int(location.horizontalAccuracy)) m")
            }
            self.onTelemetry?(self.telemetry)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard !self.locationErrorReported else { return }
            self.locationErrorReported = true
            self.onDiagnostic?("定位", "iPhone 定位不可用：\(error.localizedDescription)")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.phoneLocationManager.startUpdatingLocation()
                if CLLocationManager.headingAvailable() { self.phoneLocationManager.startUpdatingHeading() }
            } else if status == .denied || status == .restricted {
                self.onDiagnostic?("定位", "未获 iPhone 定位权限，遥控器位置只能使用 RC GPS")
            }
        }
    }
}

extension DJIFlightProviderV4: DJIAirLinkDelegate {
    nonisolated func airLink(_ airLink: DJIAirLink, didUpdateDownlinkSignalQuality quality: UInt) {
        Task { @MainActor in
            guard airLink === self.aircraft?.airLink else { return }
            self.telemetry.signal = Int(quality)
            self.onTelemetry?(self.telemetry)
        }
    }

    nonisolated func airLink(_ airLink: DJIAirLink, didUpdateUplinkSignalQuality quality: UInt) {
        Task { @MainActor in
            guard airLink === self.aircraft?.airLink else { return }
            self.telemetry.signal = min(self.telemetry.signal == 0 ? Int(quality) : self.telemetry.signal, Int(quality))
            self.onTelemetry?(self.telemetry)
        }
    }
}

extension DJIFlightProviderV4: DJIGimbalDelegate {
    nonisolated func gimbal(_ gimbal: DJIGimbal, didUpdate state: DJIGimbalState) {
        let receivedAt = Date()
        Task { @MainActor in
            guard gimbal === self.djiGimbal else { return }
            self.telemetry.gimbalPitch = Double(state.attitudeInDegrees.pitch)
            self.telemetry.gimbalRoll = Double(state.attitudeInDegrees.roll)
            self.telemetry.gimbalYaw = Double(state.attitudeInDegrees.yaw)
            self.telemetry.gimbalYawRelativeToAircraftHeading = state.yawRelativeToAircraftHeading
            self.telemetry.gimbalStateTimestamp = receivedAt
            self.telemetry.gimbalPitchAtStop = state.isPitchAtStop
            self.onTelemetry?(self.telemetry)
        }
    }
}

extension DJIFlightProviderV4: DJICameraDelegate {
    private func refreshSurveyCameraGeometry(_ target: DJICamera) {
        func value(_ parameter: String) -> DJIKeyedValue? {
            guard let key = DJICameraKey(index: Int(target.index), andParam: parameter) else { return nil }
            let now = Date()
            if now.timeIntervalSince(surveyReadbackRequests[parameter] ?? .distantPast) >= 1 {
                let generation = surveyReadbackGeneration
                surveyReadbackRequests[parameter] = now
                DJISDKManager.keyManager()?.getValueFor(key, withCompletion: { [weak self, weak target] result, error in
                    Task { @MainActor in
                        guard let self, let target, target === self.djiCamera,
                              self.surveyReadbackGeneration == generation,
                              self.surveyReadbackRequests[parameter] == now else { return }
                        if let result, error == nil {
                            self.surveyReadbackValues[parameter] = (result, Date())
                        } else {
                            self.surveyReadbackValues.removeValue(forKey: parameter)
                        }
                    }
                })
            }
            guard let sample = surveyReadbackValues[parameter],
                  now.timeIntervalSince(sample.receivedAt) >= 0,
                  now.timeIntervalSince(sample.receivedAt) <= 2 else { return nil }
            return sample.value
        }
        let resolution = SurveyCameraProfileCatalog.resolve(telemetry.productModel, telemetry.cameraModel)
        let ratioValue = value(DJICameraParamPhotoAspectRatio)?.unsignedIntegerValue
        let ratio: Double? = ratioValue.flatMap { raw in
            switch raw {
            case DJICameraPhotoAspectRatio.ratio4_3.rawValue: return 4.0 / 3.0
            case DJICameraPhotoAspectRatio.ratio3_2.rawValue: return 3.0 / 2.0
            case DJICameraPhotoAspectRatio.ratio16_9.rawValue: return 16.0 / 9.0
            default: return nil
            }
        }
        let mode = value(DJICameraParamFlatMode)?.unsignedIntegerValue
        let highResolution: Bool? = mode.flatMap { raw in
            switch raw {
            case DJIFlatCameraMode.photoSingle.rawValue, DJIFlatCameraMode.photoInterval.rawValue: return false
            case DJIFlatCameraMode.photoHighResolution.rawValue: return true
            default: return nil
            }
        }
        camera.surveyCameraProfile = SurveyCameraProfileCatalog.validatedCaptureProfile(
            resolution: resolution, aspectRatio: ratio,
            zoomRatio: value(DJICameraParamDigitalZoomFactor)?.doubleValue,
            zoomRequired: target.isDigitalZoomSupported(),
            highResolution: highResolution,
            resolutionRequired: resolution.profile.id == "dji-mavic-air-2-photo-12mp"
        )
        camera.surveyCameraUpdatedAt = Date()
    }

    nonisolated func camera(_ camera: DJICamera, didUpdate systemState: DJICameraSystemState) {
        Task { @MainActor in
            guard camera === self.djiCamera else { return }
            self.refreshSurveyCameraGeometry(camera)
            self.cameraHealthObserved = true
            self.camera.connected = true
            self.camera.recording = systemState.isRecording
            self.camera.recordingSeconds = Int(systemState.currentVideoRecordingTimeInSeconds)
            if systemState.isStoringPhoto {
                self.camera.message = "正在写入照片"
            } else if systemState.isRecording {
                self.camera.message = "录像中"
            } else if self.camera.captureStorageReady {
                self.camera.message = "相机就绪 · \(self.camera.storageName)"
            } else if !self.camera.message.contains("不可用") {
                self.camera.message = "\(self.camera.storageName)不可用"
            }
            self.onCamera?(self.camera)
            self.refreshWarnings()
        }
    }

    nonisolated func camera(_ camera: DJICamera, didUpdate storageState: DJICameraStorageState) {
        Task { @MainActor in
            guard camera === self.djiCamera else { return }
            guard !storageState.isInitializing else { return }
            let name: String
            switch storageState.location {
            case .sdCard: name = "SD 卡"
            case .internalStorage: name = "机载存储"
            default: name = "相机存储"
            }
            let failure: String?
            if !storageState.isInserted { failure = "未插入" }
            else if storageState.hasError { failure = "存储错误" }
            else if storageState.isReadOnly { failure = "只读" }
            else if storageState.isInvalidFormat { failure = "格式无效" }
            else if storageState.isFull || storageState.availableCaptureCount == 0 { failure = "空间不足" }
            else { failure = nil }
            self.cameraStorageStates[storageState.location.rawValue] = .init(
                inserted: storageState.isInserted,
                ready: failure == nil,
                readable: storageState.isInserted && !storageState.hasError
                    && !storageState.isInvalidFormat,
                photosRemaining: failure == nil ? Int(storageState.availableCaptureCount) : 0,
                name: name, failure: failure
            )
            self.refreshSelectedCameraStorage()
        }
    }
}

extension DJIFlightProviderV4: VideoFrameProcessor {
    private nonisolated static let modelFrameWidth = 1440
    private nonisolated static let modelFrameHeight = 1080

    private nonisolated static func normalizedModelJPEG(from source: CGImage,
                                                       width: Int = modelFrameWidth, height: Int = modelFrameHeight) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return UIImage(cgImage: scaled).jpegData(compressionQuality: 0.92)
    }

    nonisolated func videoProcessorEnabled() -> Bool { true }

    nonisolated func videoProcessFrame(_ frame: UnsafeMutablePointer<VideoFrameYUV>!) {
        guard let frame,
              let opaquePixelBuffer = frame.pointee.cv_pixelbuffer_fastupload,
              let captureGeneration = claimDecodedFrame() else { return }

        DJIVideoPreviewer.instance()?.unregistFrameProcessor(self)
        let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(opaquePixelBuffer).takeUnretainedValue()
        let retainedPixelBuffer = UInt(bitPattern: Unmanaged.passRetained(pixelBuffer).toOpaque())
        let capturedAt = Date()
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        modelFrameQueue.async { [weak self] in
            guard let retainedPointer = UnsafeRawPointer(bitPattern: retainedPixelBuffer) else { return }
            let pixelBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(retainedPointer).takeRetainedValue()
            var cgImage: CGImage?
            let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            let jpeg = autoreleasepool {
                guard status == noErr, let cgImage else { return nil as Data? }
                return Self.normalizedModelJPEG(from: cgImage)
            }
            let surveySize = SurveyUploadImage.previewSize(width: width, height: height)
            let surveyWidth = surveySize.width
            let surveyHeight = surveySize.height
            let surveyJPEG = autoreleasepool {
                guard self?.surveyFrameRequestActive() == true, status == noErr, let cgImage else { return nil as Data? }
                return Self.normalizedModelJPEG(from: cgImage, width: surveyWidth, height: surveyHeight)
            }
            Task { @MainActor in
                guard let self else { return }
                defer {
                    if self.isCurrentDecodedFrameGeneration(captureGeneration) {
                        self.modelFrameCaptureInFlight = false
                        self.releaseDecodedFrameClaim(generation: captureGeneration)
                    }
                }
                guard self.isCurrentDecodedFrameGeneration(captureGeneration),
                      self.camera.connected, self.videoFeed != nil,
                      let jpeg else { return }
                self.frameSequence += 1
                if let surveyJPEG, self.surveyFrameRequestActive() {
                    self.latestSurveyFrame = CameraFrame(sequence: self.frameSequence, capturedAt: capturedAt,
                        jpeg: surveyJPEG, width: surveyWidth, height: surveyHeight)
                }
                let modelFrame = CameraFrame(
                    sequence: self.frameSequence,
                    capturedAt: capturedAt,
                    jpeg: jpeg,
                    width: Self.modelFrameWidth,
                    height: Self.modelFrameHeight
                )
                self.latestFrame = modelFrame
                self.telemetry.frameTimestamp = modelFrame.capturedAt
                self.onFrame?(modelFrame)
                self.onTelemetry?(self.telemetry)
                if self.frameSequence == 1 {
                    print("[DJI][视频] 模型帧 \(width)x\(height) -> \(Self.modelFrameWidth)x\(Self.modelFrameHeight) -> Vision 288x192 · \(jpeg.count) bytes")
                    self.onDiagnostic?("视频", "VLN 模型帧已就绪：\(width)x\(height) → \(Self.modelFrameWidth)x\(Self.modelFrameHeight)")
                }
                if self.awaitingReconnectFrame {
                    self.awaitingReconnectFrame = false
                    self.onDiagnostic?("视频", "前台重连后解码帧已恢复：\(width)x\(height)")
                }
            }
        }
    }
}

extension DJIFlightProviderV4: DJIVideoFeedListener {
    nonisolated func videoFeed(_ videoFeed: DJIVideoFeed, didUpdateVideoData videoData: Data) {
        guard !videoData.isEmpty else { return }
        let receivedAt = Date()
        let receivedAtMonotonic = DispatchTime.now().uptimeNanoseconds
        if enqueueLiveVideoPublication(
            feed: videoFeed, receivedAt: receivedAt,
            monotonicNanoseconds: receivedAtMonotonic
        ) {
            Task { @MainActor [weak self] in
                self?.publishPendingLiveVideoTimestamp()
            }
        }
        videoData.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            DJIVideoPreviewer.instance()?.push(UnsafeMutablePointer(mutating: base), length: Int32(bytes.count))
        }
    }
}

extension DJIFlightProviderV4: DJIVideoFeedSourceListener {
    nonisolated func videoFeed(_ videoFeed: DJIVideoFeed, didChange physicalSource: DJIVideoFeedPhysicalSource) {
        Task { @MainActor in
            guard videoFeed == self.videoFeed else { return }
            self.configurePreviewer()
            self.onDiagnostic?("视频", "视频源已切换：\(physicalSource.rawValue)")
        }
    }
}

extension DJIFlightProviderV4: DJIVideoPreviewerFrameControlDelegate {
    nonisolated func parseDecodingAssistInfo(withBuffer buffer: UnsafeMutablePointer<UInt8>!, length: Int32, assistInfo: UnsafeMutablePointer<DJIDecodingAssistInfo>!) -> Bool {
        videoFeed?.parseDecodingAssistInfo(withBuffer: buffer, length: length, assistInfo: assistInfo) ?? false
    }

    nonisolated func decodingDidSucceed(withTimestamp timestamp: UInt32) {
        videoFeed?.decodingDidSucceed(withTimestamp: UInt(timestamp))
    }

    nonisolated func isNeedFitFrameWidth() -> Bool { false }

    nonisolated func syncDecoderStatus(_ isNormal: Bool) {
        videoFeed?.syncDecoderStatus(isNormal)
    }

    nonisolated func decodingDidFail() {
        videoFeed?.decodingDidFail()
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { min(max(self, range.lowerBound), range.upperBound) }
}

#else

@MainActor
final class DJIFlightProviderV4Unavailable: DJIFlightProvider {
    private(set) var telemetry = FlightTelemetry.disconnectedShanghai
    private(set) var camera = CameraStatus(connected: false, sdInserted: false, photosRemaining: 0, message: "当前构建未链接 DJI MSDK")
    private(set) var latestFrame: CameraFrame?
    private(set) var simulatorStatus = FlightSimulatorStatus()
    var onTelemetry: ((FlightTelemetry) -> Void)?
    var onCamera: ((CameraStatus) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onSimulator: ((FlightSimulatorStatus) -> Void)?
    var onManualTakeover: (() -> Void)?
    var onDiagnostic: ((String, String) -> Void)?
    let providerName = "DJI iOS MSDK V4.16.2 · unavailable"
    func start() { onTelemetry?(telemetry); onCamera?(camera); onSimulator?(simulatorStatus); onDiagnostic?("错误", camera.message) }
    func stop() {}
    func takeOff() throws { throw unavailable() }
    func land() throws { throw unavailable() }
    func cancelLanding() throws { throw unavailable() }
    func confirmLanding() throws { throw unavailable() }
    func returnHome() throws { throw unavailable() }
    func cancelReturnHome() throws { throw unavailable() }
    func setVirtualStick(enabled: Bool) {}
    func send(_ command: VelocityCommand) {}
    func takePhoto() throws { throw unavailable() }
    func toggleRecording() throws { throw unavailable() }
    func captureModelFrame() async throws -> CameraFrame { throw unavailable() }
    func setSimulator(enabled: Bool) async throws { throw unavailable() }
    func setSimulatorOrigin(_ point: GeoPoint) throws { throw unavailable() }
    func simulateDisconnect() {}
    func simulateStaleTelemetry() {}
    func simulateManualTakeover() {}
    func simulateCameraError() {}
    private func unavailable() -> FlightActionError { .unavailable("当前构建未链接 DJI iOS MSDK V4.16.2") }
}

#endif
