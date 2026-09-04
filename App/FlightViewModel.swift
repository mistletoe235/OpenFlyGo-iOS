import Foundation
import SwiftUI
import Combine

private enum SimulatorOriginStorage {
    // Versioned keys intentionally discard any pre-release coordinate that may
    // have been saved from a developer's or tester's current aircraft location.
    static let latitudeKey = "simulator.origin.latitude.shanghai-demo.v2"
    static let longitudeKey = "simulator.origin.longitude.shanghai-demo.v2"
}

struct SimulatorTakeoffTiming: Equatable {
    var readinessTimeoutNanoseconds: UInt64 = 30_000_000_000
    var readinessStableNanoseconds: UInt64 = 1_000_000_000
    var rawRefreshStartDelayNanoseconds: UInt64 = 1_000_000_000
    var rawRefreshAttempts = 5
    var rawRefreshIntervalNanoseconds: UInt64 = 500_000_000
    var simulatorActivationRetryDelayNanoseconds: UInt64 = 1_500_000_000
    var simulatorActivationAttempts = 20
    var simulatorOriginRestartDelayNanoseconds: UInt64 = 600_000_000
    var simulatorUnexpectedRecoveryDelayNanoseconds: UInt64 = 1_500_000_000
    var airbornePollAttempts = 150
    var airbornePollIntervalNanoseconds: UInt64 = 100_000_000

    static let production = SimulatorTakeoffTiming()
}

@MainActor
final class FlightViewModel: ObservableObject {
    static let customPromptID = "__custom__"

    @Published var telemetry = FlightTelemetry()
    @Published var camera = CameraStatus()
    @Published var latestFrame: CameraFrame?
    @Published var simulatorStatus = FlightSimulatorStatus()
    @Published private(set) var djiAccount = DJIAccountSnapshot()
    @Published private(set) var djiAccountLoginInProgress = false
    @Published private(set) var djiAccountLogoutInProgress = false
    @Published var showDJIAccountStartupPrompt = false
    @Published var simulatorChanging = false
    @Published var simulatorOriginLatitudeText = UserDefaults.standard.string(forKey: SimulatorOriginStorage.latitudeKey)
        ?? String(format: "%.6f", OpenFlyDemoLocation.shanghaiCityCenterLatitude)
    @Published var simulatorOriginLongitudeText = UserDefaults.standard.string(forKey: SimulatorOriginStorage.longitudeKey)
        ?? String(format: "%.6f", OpenFlyDemoLocation.shanghaiCityCenterLongitude)
    @Published private(set) var takeoffCommandPending = false
    @Published private(set) var takeoffStatus = "等待起飞"
    @Published var positionClosureMode: PositionClosureMode = .gps
    @Published var maxVLNHorizontalSpeed: Double = {
        let stored = UserDefaults.standard.double(forKey: "vln.maximum-horizontal-speed")
        return stored > 0 ? min(max(stored, 0.2), 4.0) : 1.0
    }()
    @Published var stopThreshold: Double = {
        let stored = (UserDefaults.standard.object(forKey: "vln.stop-threshold") as? NSNumber)?.doubleValue
        let value = stored ?? UAVFlowPolicyContract.defaultStopThreshold
        return min(max((value * 10).rounded() / 10, 0.1), 0.9)
    }()
    @Published var continuousChunkEnabled: Bool = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "vln.continuous-chunk") != nil else { return true }
        return defaults.bool(forKey: "vln.continuous-chunk")
    }()
    @Published var executedPrefix: Int = {
        let stored = UserDefaults.standard.integer(forKey: "vln.executed-prefix")
        return (1...UAVFlowPolicyContract.horizon).contains(stored)
            ? stored : UAVFlowPolicyContract.defaultExecutedPrefix
    }()
    @Published var flyThroughEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "vln.fly-through") == nil { return true }
        return UserDefaults.standard.bool(forKey: "vln.fly-through")
    }()
    @Published private(set) var chunkExecutionActive = false
    @Published private(set) var chunkStepsExecuted = 0
    @Published private(set) var chunkStepsTotal = 0
    @Published private(set) var chunkRemaining = 0
    @Published var manualRelativeX = 0.0
    @Published var manualRelativeY = 0.0
    @Published var manualRelativeZ = 0.0
    @Published var control = ControlSnapshot(
        mode: .manual, owner: .remote,
        reason: OpenFlyBuildFeatures.vlnInference ? "VLN 控制未启用" : "模型推理未编译"
    )
    @Published private(set) var prompt: String
    @Published private(set) var selectedPromptID: String
    @Published var modelLoaded = false
    @Published private(set) var modelOperationInProgress = false
    @Published private(set) var modelDownloadProgress: Double?
    @Published private(set) var modelDownloadStatus = "可从 OpenFly Azure 下载 UAVFlow 7071579"
    @Published var inferenceRunning = false
    @Published var autoInference = false
    @Published var vlnArmed = false
    @Published private(set) var autopilotCommandPending = false
    @Published var emergencyStopped = false
    @Published var latestAction: RelativeAction?
    @Published var latestDecision = SafetyDecision(command: .zero, eligible: false, reason: "等待模型指令")
    @Published var latestLatency: Double?
    @Published var mapFullscreen = false
    @Published var surveyPlannerPanelVisible = false
    @Published var galleryVisible = false
    @Published private(set) var mediaItems: [AircraftMediaItem] = []
    @Published private(set) var galleryStatus = "尚未读取飞机媒体"
    @Published private(set) var galleryLoading = false
    @Published var showLogs = false
    @Published var showMoreControls = false
    @Published var showSimulationTools = false
    @Published var showAircraftStatus = false
    @Published var alert: AppAlert?
    @Published var snapshotURL: URL?
    @Published private(set) var transientBanner: TransientBanner?

    let log = EventLog()
    let surveyRuntime: SurveyRuntimeController
    let hil: OpenFlyHILController
    let ueBridge = SurveyUeBridgeController()
    let promptPresets: [PromptPreset]
    let stopThresholdOptions = stride(from: 0.1, through: 0.9, by: 0.1).map { ($0 * 10).rounded() / 10 }

    private let provider: DJIFlightProvider
    private let inference: EmbeddedInferenceEngine
    private let safetyGate = SafetyGate()
    private let cloudModelInstaller = CloudUAVFlowModelInstaller()
    private let modelPackStore = ModelPackStore()
    private let supervisor = FlightControlSupervisor()
    private let positionLoop = RelativePositionClosedLoop()
    private var positionCommandLimiter = VelocityCommandSlewLimiter()
    private var commandTimestamp: Date?
    private var watchdog: Timer?
    private var autoTask: Task<Void, Never>?
    private var chunkTask: Task<Void, Never>?
    private var hilSimulatorActivationTask: Task<Void, Never>?
    private var hilSimulatorActivationGeneration: UInt64 = 0
    /// A DJI start command cannot be cancelled once it has crossed the SDK
    /// boundary. Keep that command serialized across HIL stop/restart so an
    /// old session cannot overlap a second `setSimulator(true)` request.
    private var hilSimulatorActivationCommandInFlight = false
    private var takeoffMonitorTask: Task<Void, Never>?
    private var takeoffRequestGeneration: UInt64 = 0
    /// DJI can publish the same autopilot/failsafe mode on every telemetry
    /// frame while an asynchronous Virtual Stick release is still pending.
    /// Handle that intervention once per continuous mode episode.
    private var externalInterventionHandled = false
    private var simulatorTakeoffRecoveryInProgress = false
    private var explicitSimulatorStopInProgress = false
    /// Matches Android V5: a user-requested stop keeps the HIL network alive
    /// and suppresses automatic Simulator re-enable until the user starts it
    /// again or explicitly starts a new HIL session.
    private var simulatorManuallyDisabled = false
    /// True only while a user-requested HIL start is still waiting for its
    /// first active DJI Simulator session. Once Simulator has been active, a
    /// later inactive callback is a transient source fault and must never
    /// trigger an automatic stop/start cycle.
    private var hilInitialSimulatorActivationPending = false
    private var movingSimulatorRawLossLatched = false
    private var appInBackground = false
    private var transientBannerTask: Task<Void, Never>?
    private var djiAccountStartupPromptHandled = false
    private var activeChunkPrompt: String?
    private var manualTakeover = false
    private var lastPositionLoopDiagnosticAt = Date.distantPast
    private var velocityModelStateEstimator = VelocityModelStateEstimator()
    private var chunkPlannedHeadingDegrees: Double?
    private var chunkCarryNorthMeters = 0.0
    private var chunkCarryEastMeters = 0.0
    private var chunkCarryUpMeters = 0.0
    private var cancellables = Set<AnyCancellable>()
    private var mediaThumbnailRequests = Set<String>()
    private let simulatorTakeoffTiming: SimulatorTakeoffTiming

    init(provider: DJIFlightProvider? = nil,
         inference: EmbeddedInferenceEngine? = nil,
         hil: OpenFlyHILController? = nil,
         simulatorTakeoffTiming: SimulatorTakeoffTiming = .production) {
        let presets = PromptPresetCatalog.load()
        let initialPrompt = presets.first ?? PromptPresetCatalog.fallback[0]
        promptPresets = presets
        prompt = initialPrompt.instruction
        selectedPromptID = initialPrompt.id
        self.simulatorTakeoffTiming = simulatorTakeoffTiming
        self.hil = hil ?? OpenFlyHILController()
        if let provider {
            self.provider = provider
        } else {
#if targetEnvironment(simulator)
            self.provider = MockFlightProvider()
#else
#if canImport(DJISDK)
            self.provider = DJIFlightProviderV4()
#else
            self.provider = DJIFlightProviderV4Unavailable()
#endif
#endif
        }
        self.inference = inference ?? DisabledInferenceEngine()
        self.provider.setRawSimulatorStateStore(self.hil.rawSimulatorStateStore)
        surveyRuntime = SurveyRuntimeController(provider: self.provider, log: log)
        if let latitude = Double(simulatorOriginLatitudeText),
           let longitude = Double(simulatorOriginLongitudeText) {
            try? self.provider.setSimulatorOrigin(.init(latitude: latitude, longitude: longitude))
        }
        surveyRuntime.virtualFrameCaptureEnabled = { [weak self] in
            self?.hil.useVirtualFrames == true && self?.hil.status.running == true
        }
        surveyRuntime.latestVirtualFrame = { [weak self] in
            self?.hil.latestFreshVirtualFrame(
                maxAgeMilliseconds: OpenFlyHILController.virtualFrameFreshMilliseconds
            )
        }
        surveyRuntime.onVirtualFrameCaptured = { [weak self] record in
            guard let self else { return }
            self.ueBridge.postCapture(record, peerHost: self.hil.status.peerHost)
        }
        self.hil.onVirtualFrame = { [weak self] frame in self?.latestFrame = frame }
        self.hil.onSafetyEvent = { [weak self] event in self?.handleHILEvent(event) }
        self.hil.onSimulatorFrequencyRequested = { [weak self] hz in
            self?.provider.setSimulatorUpdateFrequency(hz)
        }
        self.hil.onSimulatorStartRequested = { [weak self] in
            self?.ensureHILSimulatorActive()
        }
        self.hil.onVirtualFrameModeChanged = { [weak self] enabled in
            self?.handleHILFrameModeChanged(enabled)
        }
        self.hil.onVirtualFrameSafetyFault = { [weak self] reason in
            self?.handleHILFrameSafetyFault(reason)
        }
        self.hil.onDiagnostic = { [weak self] message in
            self?.log.append("HIL网络", message)
        }
        self.hil.shouldEnforceVirtualFrameSafety = { [weak self] in
            guard let self else { return false }
            return [.arming, .running].contains(self.surveyRuntime.snapshot.state)
                || self.vlnArmed || self.autoInference || self.inferenceRunning
                || self.chunkExecutionActive
        }
        surveyRuntime.$snapshot
            .dropFirst()
            .sink { [weak self] value in self?.updateControl(surveyState: value.state) }
            .store(in: &cancellables)
        // The flight controller remains at 25 Hz, but the map/HUD only needs a
        // 5 Hz presentation pulse. Previously assigning the same control state
        // on every tick invalidated the entire SwiftUI tree and repeatedly
        // redrew MapKit while the aircraft was flying.
        surveyRuntime.$snapshot
            .dropFirst()
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.hil.objectWillChange
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.hil.$status
            .map(\.message)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] message in
                guard let self else { return }
                if message.contains("失败") || message.contains("超时") {
                    self.showBanner(message, kind: .error, durationNanoseconds: 4_500_000_000)
                } else if message.contains("已连接") || message.contains("已自动锁定") {
                    self.showBanner(message, kind: .success)
                }
            }
            .store(in: &cancellables)
        bind()
        self.provider.start()
#if targetEnvironment(simulator)
        log.append("系统", "启动 \(self.provider.providerName)；Mac Simulator 验证")
#else
        log.append("系统", "启动 \(self.provider.providerName)；公开版本未包含端侧推理")
#endif
        log.append("控制", "已恢复 VLN 水平限速 \(String(format: "%.1f", maxVLNHorizontalSpeed)) m/s")
        log.append("控制", "已恢复模型 Stop 阈值 \(String(format: "%.1f", stopThreshold))")
        log.append("Prompt", "已加载 \(promptPresets.count) 条预设 Prompt；默认 \(initialPrompt.id)")
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["SIM_SHOW_LOGS"] == "1" { showLogs = true }
        if ProcessInfo.processInfo.environment["SIM_AUTORUN"] == "1" {
            Task { [weak self] in await self?.runSimulatorDemo() }
        }
#endif
#if !targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_FUNCTION_TEST"] == "1" {
            showLogs = true
            Task { [weak self] in await self?.runDJISimulatorFunctionMatrix() }
        } else if ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_AUTOTEST"] == "1" {
            showLogs = true
            Task { [weak self] in await self?.runDJISimulatorValidation() }
        }
#endif
    }

    deinit {
        watchdog?.invalidate(); autoTask?.cancel(); chunkTask?.cancel()
        hilSimulatorActivationTask?.cancel()
        takeoffMonitorTask?.cancel()
        transientBannerTask?.cancel()
    }

    var providerName: String { provider.providerName }
    var djiAccountStatusText: String {
        let base: String
        switch djiAccount.state {
        case .loggedIn:
            if let account = djiAccount.maskedAccount {
                base = AppLocalization.format("DJI 账号：已登录（%@）", account)
            } else {
                base = AppLocalization.string("DJI 账号：已登录")
            }
        case .notLoggedIn:
            base = AppLocalization.string("DJI 账号：未登录（真机飞行可能受限）")
        case .tokenOutOfDate:
            base = AppLocalization.string("DJI 账号：登录已过期")
        case .unknown:
            base = AppLocalization.string("DJI 账号：状态确认中")
        }
        guard let error = djiAccount.lastError, !error.isEmpty else { return base }
        return AppLocalization.format("%@\n最近登录错误：%@", base, error)
    }
    var djiAccountLoginButtonTitle: String {
        if djiAccountLoginIsSimulated {
            return djiAccountLoginInProgress
                ? AppLocalization.string("模拟中…")
                : AppLocalization.string("模拟登录回调")
        }
        if djiAccountLoginInProgress { return AppLocalization.string("登录中…") }
        return djiAccount.loggedIn
            ? AppLocalization.string("重新登录 DJI 账号")
            : AppLocalization.string("登录 DJI 账号")
    }
    var djiAccountOperationInProgress: Bool {
        djiAccountLoginInProgress || djiAccountLogoutInProgress
    }
    var djiAccountLoginIsSimulated: Bool { provider.djiAccountLoginIsSimulated }
    var inferenceName: String { inference.engineName }
    var controlEnvironmentLabel: String {
        if hil.status.running {
            return hil.status.peerFresh ? "HIL仿真/UE在线" : "HIL仿真/等待UE"
        }
        if simulatorChanging {
            return simulatorStatus.active ? "DJI仿真切换中" : "DJI仿真启动中"
        }
        if simulatorStatus.active || telemetry.simulatorActive { return "DJI仿真" }
        return "真机"
    }
    var simulatorPhaseLabel: String? {
        if simulatorChanging { return simulatorStatus.message }
        guard simulatorStatus.active || telemetry.simulatorActive else { return nil }
        if simulatorStatus.flying { return "仿真飞行中" }
        if simulatorStatus.motorsOn { return "仿真电机已启动" }
        if simulatorStatus.stateReceived { return "仿真" }
        return "仿真等待 RAW 状态"
    }
    var commandFresh: Bool { positionLoop.isActive || (commandTimestamp.map { Date().timeIntervalSince($0) <= 2.5 } ?? false) }
    var isReturningHome: Bool { telemetry.mode == .returningHome }
    var isLanding: Bool { telemetry.mode == .landing }
    var isAirborneForControl: Bool { simulatorStatus.active ? simulatorStatus.flying : telemetry.flying }
    private var djiFrameIsFresh: Bool {
        guard camera.connected else { return false }
        if let frame = provider.latestFrame,
           Date().timeIntervalSince(frame.capturedAt) <= 2.5 { return true }
        if let packetAt = provider.liveVideoTimestamp,
           Date().timeIntervalSince(packetAt) <= 2.5 { return true }
        return false
    }
    var liveCameraPreviewReady: Bool { djiFrameIsFresh }
    var inferenceFrameReady: Bool {
        hil.useVirtualFrames
            ? hil.status.running && hil.status.peerFresh && hil.virtualFrameIsFreshForInference
            : djiFrameIsFresh
    }
    var canInfer: Bool { modelLoaded && !modelOperationInProgress && inferenceFrameReady }
    var canStartInferenceAction: Bool {
        canInfer && (!continuousChunkEnabled || vlnArmed)
    }
    var inferenceFrameReadinessIssue: String {
        if !modelLoaded { return "模型未加载" }
        if hil.useVirtualFrames {
            if !hil.status.running { return "UE HIL 链路未启动" }
            if !hil.status.peerFresh { return "UE HIL 心跳未就绪" }
            if !hil.virtualFrameIsFreshForInference { return "UE 虚拟相机帧未就绪或已超过 2 秒" }
        } else if !camera.connected {
            return "DJI 相机未连接"
        } else if provider.latestFrame == nil && provider.liveVideoTimestamp == nil {
            return "尚未收到 DJI 图传数据"
        } else if !djiFrameIsFresh {
            return "DJI 图传帧已超过 2.5 秒"
        }
        return "推理输入未就绪"
    }
    var surveyControlActive: Bool {
        [.arming, .running, .paused].contains(surveyRuntime.snapshot.state)
    }
    private var hilSimulatorRawReadyForNewControl: Bool {
        !hil.status.running || simulatorRawStateFresh()
    }
    var canArmVLN: Bool {
        canInfer && telemetry.connected && isAirborneForControl && !emergencyStopped
            && !surveyControlActive && !autopilotCommandPending
            && telemetry.sticksActive != true && flightModeAllowsNewAppControl
            && hilSimulatorRawReadyForNewControl
    }
    var canExecuteManualRelativePosition: Bool {
        let age = Date().timeIntervalSince(telemetry.timestamp)
        return telemetry.connected && isAirborneForControl && !emergencyStopped
            && !surveyControlActive && !autopilotCommandPending
            && telemetry.sticksActive != true && flightModeAllowsNewAppControl
            && hilSimulatorRawReadyForNewControl
            && age >= 0 && age <= 0.75
    }
    var chunkExecutionSummary: String {
        if chunkExecutionActive {
            return "执行 \(chunkStepsExecuted)/\(max(chunkStepsTotal, chunkStepsExecuted)) · 队列剩余 \(chunkRemaining)"
        }
        if chunkStepsTotal > 0, chunkStepsExecuted == chunkStepsTotal {
            return "上次完成 \(chunkStepsExecuted)/\(chunkStepsTotal) · 当前悬停"
        }
        return continuousChunkEnabled ? "单次预测 H10，连续执行 H\(executedPrefix)" : "单次预测 H10，只执行 H1"
    }
    var galleryAvailable: Bool {
        let age = Date().timeIntervalSince(telemetry.flightStateTimestamp)
        return camera.connected && telemetry.connected && !camera.recording && !telemetry.flying
            && age >= 0 && age <= 1.5
    }

    func selectPrompt(id: String) {
        if id == Self.customPromptID {
            selectedPromptID = id
            return
        }
        guard let item = promptPresets.first(where: { $0.id == id }) else { return }
        if vlnArmed || chunkExecutionActive { normalStop("切换 Prompt") }
        selectedPromptID = id
        prompt = item.instruction
        log.append("Prompt", "选择预设 \(id)")
    }

    func setPromptText(_ value: String) {
        if value != prompt, vlnArmed || chunkExecutionActive { normalStop("编辑 Prompt") }
        prompt = value
        selectedPromptID = promptPresets.first(where: { $0.instruction == value })?.id ?? Self.customPromptID
    }

    func loadModel() {
        guard OpenFlyBuildFeatures.vlnInference else { report("当前发布版本未启用模型推理"); return }
        guard beginModelOperation("加载 UAVFlow 模型") else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.modelOperationInProgress = false }
            await self.waitForInferenceToFinish()
            _ = await self.loadModelNow()
        }
    }

    func downloadLatestUAVFlowModel() {
        guard OpenFlyBuildFeatures.vlnInference else { report("当前发布版本未启用模型推理"); return }
        guard beginModelOperation("更新 UAVFlow 模型") else { return }
        modelDownloadProgress = nil
        Task { [weak self] in
            guard let self else { return }
            defer { self.modelOperationInProgress = false }
            do {
                await self.waitForInferenceToFinish()
                let pack = try await cloudModelInstaller.installLatest { [weak self] phase, value in
                    Task { @MainActor in
                        self?.modelDownloadStatus = phase
                        self?.modelDownloadProgress = value
                    }
                }
                try modelPackStore.activate(pack)
                await inference.reset()
                modelLoaded = false
                modelDownloadProgress = 1
                modelDownloadStatus = "已安装 \(pack.manifest.packID)@\(pack.manifest.version)"
                log.append("模型", modelDownloadStatus + "；请重新加载")
            } catch {
                modelDownloadProgress = nil
                modelDownloadStatus = "下载失败：\(error.localizedDescription)"
                report(modelDownloadStatus)
            }
        }
    }

    func importUAVFlowModel(from url: URL) {
        guard OpenFlyBuildFeatures.vlnInference else { report("当前发布版本未启用模型推理"); return }
        guard beginModelOperation("导入 UAVFlow 模型") else { return }
        modelDownloadProgress = nil
        modelDownloadStatus = "校验并导入本地模型包"
        Task { [weak self] in
            guard let self else { return }
            defer { self.modelOperationInProgress = false }
            do {
                await self.waitForInferenceToFinish()
                let pack = try await self.modelPackStore.importPack(from: url)
                guard pack.manifest.packID == CloudUAVFlowModelInstaller.targetPackID,
                      pack.manifest.version.contains("currentonly"),
                      pack.manifest.artifacts.contains(where: { $0.role == "uavflow_config" }),
                      pack.manifest.artifacts.contains(where: { $0.role == "uavflow_heads" }) else {
                    throw CloudUAVFlowInstallError.importedPackMismatch
                }
                try self.modelPackStore.activate(pack)
                await self.inference.reset()
                self.modelLoaded = false
                self.modelDownloadStatus = "已导入并激活 \(pack.manifest.packID)@\(pack.manifest.version)"
                self.log.append("模型", self.modelDownloadStatus + "；请重新加载")
            } catch {
                self.modelDownloadStatus = "导入失败：\(error.localizedDescription)"
                self.report(self.modelDownloadStatus)
            }
        }
    }

    func inspectModelRuntime() {
        guard OpenFlyBuildFeatures.vlnInference else { report("当前发布版本未启用模型推理"); return }
        guard beginModelOperation("检查 UAVFlow 模型运行时") else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.modelOperationInProgress = false }
            await self.waitForInferenceToFinish()
            self.modelDownloadStatus = "正在执行模型运行时自检"
            guard await self.loadModelNow() else {
                self.modelDownloadStatus = "运行时自检失败；请查看日志"
                return
            }
            let diagnostics = await self.inference.diagnostics().sorted { $0.key < $1.key }
            let summary = diagnostics.prefix(3).map { "\($0.key)=\($0.value)" }.joined(separator: " · ")
            self.modelDownloadStatus = summary.isEmpty ? "运行时自检通过" : "运行时自检通过 · \(summary)"
            self.log.append("模型", self.modelDownloadStatus)
        }
    }

    func resetModelRuntime() {
        guard OpenFlyBuildFeatures.vlnInference else { report("当前发布版本未启用模型推理"); return }
        guard beginModelOperation("重置模型运行时") else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.modelOperationInProgress = false }
            await self.waitForInferenceToFinish()
            await self.inference.reset()
            self.modelLoaded = false
            self.modelDownloadProgress = nil
            self.modelDownloadStatus = "模型运行时已复位；飞控保持未武装"
            self.log.append("模型", self.modelDownloadStatus)
        }
    }

    private func beginModelOperation(_ reason: String) -> Bool {
        guard !modelOperationInProgress else {
            report("已有模型操作正在进行，请稍候")
            return false
        }
        modelOperationInProgress = true
        modelDownloadProgress = nil
        autoInference = false
        autoTask?.cancel()
        autoTask = nil
        if vlnArmed || chunkExecutionActive || positionLoop.isActive {
            normalStop(reason)
        }
        return true
    }

    private func waitForInferenceToFinish() async {
        while inferenceRunning {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func inferOnce() {
        guard OpenFlyBuildFeatures.vlnInference else { report("当前发布版本未启用模型推理"); return }
        guard !modelOperationInProgress else { report("模型维护进行中，请稍候"); return }
        guard !inferenceRunning else { return }
        let requestedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedPrompt.isEmpty else { report("Prompt 不能为空"); return }
        if continuousChunkEnabled {
            guard canInfer else { report(inferenceFrameReadinessIssue); return }
            guard vlnArmed else { report("Chunk 连续执行前请先启用 VLN 控制"); return }
            guard !positionLoop.isActive else { report("当前相对位置动作尚未完成"); return }
            beginChunkExecution(prompt: requestedPrompt)
        }
        let startsFreshChunk = continuousChunkEnabled
        Task {
            if startsFreshChunk && !inference.replansEveryAction { await inference.stop() }
            await performInference(promptOverride: requestedPrompt)
        }
    }

    func toggleAutoInference() {
        guard OpenFlyBuildFeatures.vlnInference else { report("当前发布版本未启用模型推理"); return }
        if !autoInference, modelOperationInProgress {
            report("模型维护进行中，请稍候")
            return
        }
        if !autoInference && !canInfer { report(inferenceFrameReadinessIssue); return }
        if !autoInference && continuousChunkEnabled && !vlnArmed {
            report("自动连续 Chunk 前请先启用 VLN 控制")
            return
        }
        autoInference.toggle()
        autoTask?.cancel()
        log.append("控制", autoInference ? "自动推理已启动" : "自动推理已停止")
        if autoInference {
            autoTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.automaticInferenceTick()
                    let delay: UInt64 = self?.continuousChunkEnabled == true ? 650_000_000 : 1_000_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
    }

    func toggleVLNControl() {
        guard OpenFlyBuildFeatures.vlnInference else { report("当前发布版本未启用模型推理"); return }
        if vlnArmed { normalStop("用户关闭 VLN 控制"); return }
        if emergencyStopped { report("请先重置急停"); return }
        guard !modelOperationInProgress else { report("模型维护进行中，请稍候"); return }
        guard !autopilotCommandPending else { report("正在释放控制并切换 DJI 自动飞行，请稍候"); return }
        guard telemetry.connected else { report("飞机未连接，禁止启用 VLN"); return }
        guard isAirborneForControl else { report("飞机未起飞，禁止启用 VLN"); return }
        guard flightModeAllowsNewAppControl else { report("DJI 正在返航、降落或保护状态，禁止启用 VLN"); return }
        guard telemetry.sticksActive != true else { report("请先将遥控器摇杆回中，再启用 VLN"); return }
        guard hilSimulatorRawReadyForNewControl else { report("飞行中的 DJI Simulator RAW 已超过 500 ms，禁止启用 VLN"); return }
        guard modelLoaded else { report("模型未加载，禁止启用 VLN"); return }
        guard inferenceFrameReady else { report("\(inferenceFrameReadinessIssue)，禁止启用 VLN"); return }
        guard !surveyControlActive else { report("航测控制仍处于活动/暂停状态，请先终止航测任务"); return }
        manualTakeover = false
        velocityModelStateEstimator.reset()
        velocityModelStateEstimator.update(telemetry)
        vlnArmed.toggle()
        provider.setVirtualStick(enabled: vlnArmed)
        if !vlnArmed { provider.send(.zero); latestDecision = safetyGate.blocked("用户关闭 VLN 控制") }
        log.append("控制", vlnArmed ? "VLN 已请求 DJI Virtual Stick" : "VLN 已释放控制权")
        updateControl()
    }

    /// Settings-level raw Virtual Stick switch, matching Android's separate
    /// diagnostic control. It deliberately does not arm VLN or require a model.
    func enableVirtualStickOnly() {
        guard telemetry.connected else { report("无法启用 VS：飞控未连接"); return }
        guard !surveyControlActive else { report("航测任务正在占用或保留 VS 控制权"); return }
        guard hilSimulatorRawReadyForNewControl else { report("飞行中的 DJI Simulator RAW 已超过 500 ms，禁止启用 VS"); return }
        provider.setVirtualStick(enabled: true)
        log.append("飞控", "已请求启用原始 Virtual Stick；VLN 仍保持关闭")
    }

    func releaseVirtualStickOnly() {
        normalStop("用户从设置释放 VS")
    }

    func selectPositionClosureMode(_ mode: PositionClosureMode) {
        guard mode != positionClosureMode else { return }
        if vlnArmed { normalStop("切换位置闭环方式") }
        positionLoop.cancel()
        velocityModelStateEstimator.reset()
        velocityModelStateEstimator.update(telemetry)
        positionClosureMode = mode
        latestDecision = safetyGate.blocked("已选择\(mode.label)，等待模型指令")
        log.append("控制", "位置闭环切换为\(mode.label)：\(mode.detail)")
        updateControl()
    }

    func setMaxVLNHorizontalSpeed(_ value: Double) {
        let clamped = min(max((value * 10).rounded() / 10, 0.2), 4.0)
        guard abs(clamped - maxVLNHorizontalSpeed) >= 0.01 else { return }
        if vlnArmed { normalStop("调整 VLN 最大速度") }
        maxVLNHorizontalSpeed = clamped
        UserDefaults.standard.set(clamped, forKey: "vln.maximum-horizontal-speed")
        log.append("控制", "VLN 水平最大速度设为 \(String(format: "%.1f", clamped)) m/s")
    }

    func setStopThreshold(_ value: Double) {
        let normalized = min(max((value * 10).rounded() / 10, 0.1), 0.9)
        guard abs(normalized - stopThreshold) >= 0.001 else { return }
        if vlnArmed { normalStop("调整模型 Stop 阈值") }
        stopThreshold = normalized
        UserDefaults.standard.set(normalized, forKey: "vln.stop-threshold")
        latestDecision = safetyGate.blocked("Stop 阈值已设为 \(String(format: "%.1f", normalized))，等待模型指令")
        log.append("控制", "模型 Stop 阈值设为 \(String(format: "%.1f", normalized))；stop ≥ 阈值时悬停")
        updateControl()
    }

    func setContinuousChunkEnabled(_ enabled: Bool) {
        guard enabled != continuousChunkEnabled else { return }
        continuousChunkEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "vln.continuous-chunk")
        if !enabled, chunkExecutionActive {
            abortChunkExecution("用户关闭 Chunk 连续模式")
        }
        log.append("控制", enabled ? "Chunk 连续执行已开启" : "Chunk 连续执行已关闭")
    }

    func setExecutedPrefix(_ value: Int) {
        let normalized = min(max(value, 1), UAVFlowPolicyContract.horizon)
        guard normalized != executedPrefix else { return }
        if vlnArmed { normalStop("调整 UAVFlow 执行前缀") }
        executedPrefix = normalized
        UserDefaults.standard.set(normalized, forKey: "vln.executed-prefix")
        log.append("控制", "UAVFlow 每次预测 H10，连续模式执行 H\(normalized)")
    }

    func setFlyThroughEnabled(_ enabled: Bool) {
        guard enabled != flyThroughEnabled else { return }
        if vlnArmed { normalStop("切换穿越航点模式") }
        flyThroughEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "vln.fly-through")
        log.append("控制", enabled ? "穿越航点已开启" : "穿越航点已关闭；每步末端悬停")
    }

    func executeManualRelativePosition() {
        guard !surveyControlActive else { report("航测控制仍处于活动/暂停状态，请先终止航测任务"); return }
        guard flightModeAllowsNewAppControl else { report("DJI 正在返航、降落或保护状态，禁止执行手动 XYZ"); return }
        guard telemetry.sticksActive != true else { report("请先将遥控器摇杆回中，再执行手动 XYZ"); return }
        guard canExecuteManualRelativePosition else {
            report("飞机需已连接、起飞且遥测新鲜，才能执行手动 XYZ")
            return
        }
        let action = RelativeAction(
            forwardMeters: manualRelativeX,
            rightMeters: manualRelativeY,
            upMeters: manualRelativeZ,
            yawDegrees: 0,
            confidence: 1,
            stopScore: 0,
            reason: "手动 XYZ 相对位置测试"
        )
        abortChunkExecution("切换至手动 XYZ", logEvent: false)
        autoInference = false
        autoTask?.cancel()
        positionLoop.cancel()
        provider.send(.zero)
        do {
            let step = try positionLoop.start(
                action: action,
                telemetry: telemetry,
                mode: positionClosureMode,
                maximumHorizontalSpeed: maxVLNHorizontalSpeed
            )
            if !vlnArmed {
                manualTakeover = false
                vlnArmed = true
                provider.setVirtualStick(enabled: true)
            }
            latestAction = action
            commandTimestamp = Date()
            log.append("控制", "手动 XYZ：前\(f(action.forwardMeters)) 右\(f(action.rightMeters)) 上\(f(action.upMeters))m")
            applyPositionStep(step)
            updateControl()
        } catch {
            positionLoop.cancel()
            provider.send(.zero)
            latestDecision = safetyGate.blocked(error.localizedDescription)
            report("手动 XYZ 已阻止：\(error.localizedDescription)")
        }
    }

    func stopManualRelativePosition() {
        normalStop("用户停止手动 XYZ")
    }

    func setSimulatorEnabled(_ enabled: Bool) {
        guard !simulatorChanging else {
            showBanner("DJI 内置仿真器正在切换，请稍候", kind: .warning)
            return
        }
        guard enabled != simulatorStatus.active else {
            simulatorManuallyDisabled = !enabled
            if !enabled {
                invalidateHILSimulatorActivation()
                hil.reportSimulatorSource("Simulator 已手动关闭；HIL 网络保持，自动启动暂停")
            } else if hil.status.running, !simulatorRawStateFresh() {
                ensureHILSimulatorActive()
            }
            showBanner(enabled ? "DJI 内置仿真器已经开启" : "DJI 内置仿真器已经关闭")
            return
        }
        if [.arming, .running].contains(surveyRuntime.snapshot.state) {
            surveyRuntime.pause(reason: "切换 DJI 内置仿真器")
            showBanner("航线已自动暂停并释放控制；断点已保留", kind: .warning)
        }
        if vlnArmed { normalStop("切换 DJI 内置仿真器") }
        simulatorManuallyDisabled = !enabled
        if !enabled { invalidateHILSimulatorActivation() }
        simulatorChanging = true
        let operation = enabled ? "启动" : "停止"
        simulatorStatus.message = "正在\(operation) DJI 内置仿真器…"
        log.append("仿真", simulatorStatus.message)
        showBanner(simulatorStatus.message)
        explicitSimulatorStopInProgress = !enabled
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.simulatorChanging = false
                self.explicitSimulatorStopInProgress = false
                if enabled, self.hil.status.running, !self.appInBackground,
                   !self.simulatorManuallyDisabled, !self.simulatorRawStateFresh() {
                    self.ensureHILSimulatorActive()
                }
            }
            do {
                try await self.provider.setSimulator(enabled: enabled)
                if enabled {
                    if self.hil.status.running, self.simulatorStatus.active,
                       !self.simulatorRawStateFresh() {
                        _ = await self.refreshHILSimulatorRawState(
                            activationGeneration: self.hilSimulatorActivationGeneration
                        )
                    }
                    self.simulatorStatus.message = "DJI 已接受启动请求，等待首个仿真状态…"
                    self.log.append("仿真", self.simulatorStatus.message)
                    self.showBanner(self.simulatorStatus.message)
                    let ready = await self.waitFor(
                        { self.simulatorStatus.active && self.simulatorStatus.stateReceived },
                        attempts: 100,
                        intervalNanoseconds: 100_000_000
                    )
                    if ready {
                        self.simulatorStatus.message = "DJI 内置仿真已就绪，等待起飞"
                        self.log.append("仿真", "DJI 内置仿真已就绪，可以长按起飞")
                        self.showBanner("DJI 内置仿真已就绪，可以起飞", kind: .success)
                    } else {
                        self.simulatorStatus.message = "仿真器启动超时：未收到 DJI SimulatorState"
                        self.report("仿真器启动超时：未收到首个状态；已保持当前会话，请勿反复开关")
                    }
                } else {
                    self.log.append("仿真", "DJI 内置仿真已停止")
                    if self.hil.status.running {
                        self.hil.reportSimulatorSource(
                            "Simulator 已手动关闭；HIL 网络保持，自动启动暂停"
                        )
                        self.log.append("HIL", "用户关闭 Simulator；UDP/TCP 会话保持，自动启动暂停")
                    }
                    self.showBanner("DJI 内置仿真已停止，HIL 网络保持", kind: .success)
                }
            } catch {
                // Android V5 treats SDK errors as operation-local conflicts and
                // reconciles against the actual Simulator state. Never poison
                // the whole App session merely because DJI returned 8012.
                if !enabled {
                    self.simulatorManuallyDisabled = false
                    if self.hil.status.running {
                        self.hil.reportSimulatorSource(
                            "Simulator 手动关闭失败；HIL 网络保持并恢复自动协调"
                        )
                    }
                }
                self.report(
                    "\(enabled ? "启动" : "停止") DJI 内置仿真失败：\(self.describeDJIError(error))；可重试"
                )
            }
        }
    }

    func saveSimulatorOrigin(useAircraftLocation: Bool = false) {
        guard !simulatorChanging else { report("DJI 内置仿真器正在切换，请稍候"); return }
        let point: GeoPoint
        if useAircraftLocation {
            guard telemetry.aircraftLocationValid else { report("当前没有有效飞机定位，不能设为仿真起点"); return }
            point = telemetry.aircraft
            simulatorOriginLatitudeText = String(format: "%.6f", point.latitude)
            simulatorOriginLongitudeText = String(format: "%.6f", point.longitude)
        } else {
            guard let latitude = Double(simulatorOriginLatitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let longitude = Double(simulatorOriginLongitudeText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                report("仿真起点经纬度格式无效")
                return
            }
            point = .init(latitude: latitude, longitude: longitude)
        }
        do {
            try provider.setSimulatorOrigin(point)
            persistSimulatorOrigin(point)
            log.append("仿真", "仿真起点已保存：\(simulatorOriginLatitudeText), \(simulatorOriginLongitudeText)")
            showBanner("仿真起点已保存，下次启动生效", kind: .success)
        } catch {
            report("设置仿真起点失败：\(error.localizedDescription)")
        }
    }

    var savedSimulatorOrigin: GeoPoint? {
        guard let latitude = Double(simulatorOriginLatitudeText),
              let longitude = Double(simulatorOriginLongitudeText),
              latitude.isFinite, (-90...90).contains(latitude),
              longitude.isFinite, (-180...180).contains(longitude) else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }

    /// Mirrors Android V5's survey-map origin picker. An active, grounded DJI
    /// Simulator must be stopped before its immutable start location can be
    /// changed, then restarted from the selected WGS84 point.
    func setSimulatorOriginFromSurveyMap(
        _ point: GeoPoint,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !simulatorChanging else {
            completion(false, "DJI 内置仿真器正在切换，请稍候")
            return
        }
        guard point.latitude.isFinite, (-90...90).contains(point.latitude),
              point.longitude.isFinite, (-180...180).contains(point.longitude),
              abs(point.latitude) > 1e-9 || abs(point.longitude) > 1e-9 else {
            completion(false, "仿真起点无效")
            return
        }
        guard !telemetry.flying, !simulatorStatus.flying, !simulatorStatus.motorsOn else {
            completion(false, "飞机/Simulator 已在空中，禁止切换起点")
            return
        }
        if vlnArmed { normalStop("切换 DJI 仿真起点") }

        let wasActive = simulatorStatus.active
        simulatorManuallyDisabled = false
        simulatorChanging = true
        explicitSimulatorStopInProgress = wasActive
        simulatorStatus.message = wasActive ? "正在切换仿真起点…" : "正在保存仿真起点…"
        log.append("仿真", simulatorStatus.message)
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.simulatorChanging = false
                self.explicitSimulatorStopInProgress = false
            }
            do {
                if wasActive {
                    try await self.provider.setSimulator(enabled: false)
                    try await Task.sleep(
                        nanoseconds: self.simulatorTakeoffTiming.simulatorOriginRestartDelayNanoseconds
                    )
                }
                try self.provider.setSimulatorOrigin(point)
                self.persistSimulatorOrigin(point)
                self.log.append(
                    "仿真", String(format: "航线地图选择仿真起点：%.6f, %.6f", point.latitude, point.longitude)
                )
                guard wasActive else {
                    let message = String(
                        format: "仿真起点已保存：%.6f, %.6f", point.latitude, point.longitude
                    )
                    self.simulatorStatus.message = message
                    self.showBanner(message, kind: .success)
                    completion(true, message)
                    return
                }

                try await self.provider.setSimulator(enabled: true)
                let ready = await self.waitFor(
                    { self.simulatorStatus.active && self.simulatorStatus.stateReceived },
                    attempts: 100,
                    intervalNanoseconds: 100_000_000
                )
                guard ready else {
                    let message = "起点已保存，但 Simulator 重启后未收到状态"
                    self.simulatorStatus.message = message
                    self.showBanner(message, kind: .warning)
                    completion(false, message)
                    return
                }
                let message = String(
                    format: "仿真起点已切换并重启：%.6f, %.6f", point.latitude, point.longitude
                )
                self.simulatorStatus.message = message
                self.showBanner(message, kind: .success)
                completion(true, message)
            } catch {
                let prefix = wasActive && !self.simulatorStatus.active
                    ? "起点切换失败，Simulator 当前已停止"
                    : "切换仿真起点失败"
                let message = "\(prefix)：\(self.describeDJIError(error))；可重新选择或手动启动"
                self.log.append("仿真", message)
                self.showBanner(message, kind: .warning, durationNanoseconds: 5_000_000_000)
                completion(false, message)
            }
        }
    }

    private func persistSimulatorOrigin(_ point: GeoPoint) {
        // Match Android V5: labels are rounded for readability, while the
        // persisted coordinate retains the map tap's full Double precision.
        simulatorOriginLatitudeText = String(point.latitude)
        simulatorOriginLongitudeText = String(point.longitude)
        UserDefaults.standard.set(simulatorOriginLatitudeText, forKey: SimulatorOriginStorage.latitudeKey)
        UserDefaults.standard.set(simulatorOriginLongitudeText, forKey: SimulatorOriginStorage.longitudeKey)
    }

    func normalStop(_ reason: String = "用户停止") {
        cancelTakeoffMonitoring(reason: reason)
        if surveyRuntime.snapshot.state == .arming || surveyRuntime.snapshot.state == .running {
            surveyRuntime.abort("外部停止：\(reason)", clearCheckpoint: false)
        }
        autoInference = false; autoTask?.cancel(); vlnArmed = false
        resetChunkExecutionState()
        velocityModelStateEstimator.reset()
        positionLoop.cancel()
        positionCommandLimiter.reset()
        provider.send(.zero); provider.setVirtualStick(enabled: false)
        latestDecision = safetyGate.blocked(reason); commandTimestamp = Date()
        Task { await inference.stop() }
        log.append("停止", "\(reason)；已归零并释放控制")
        updateControl()
    }

    func emergencyStop() {
        surveyRuntime.abort("本地急停")
        emergencyStopped = true; normalStop("本地急停已锁定")
        log.append("急停", "急停触发；必须显式重置")
        updateControl()
    }

    func resetEmergency() {
        emergencyStopped = false; manualTakeover = false; vlnArmed = false
        latestAction = nil; latestDecision = safetyGate.blocked("急停已重置，等待手动启动")
        Task { await inference.reset() }
        log.append("重置", "急停已清除；保持人工控制和零速度")
        updateControl()
    }

    func requestReturnHome() { alert = AppAlert(title: "开始返航", message: "将停止 VLN、归零并把控制权交给 DJI 飞控。", confirm: { [weak self] in self?.performAutopilot("自动返航") { try self?.provider.returnHome() } }) }
    func requestLanding() { alert = AppAlert(title: "开始自动降落", message: "将停止 VLN，请确认实际着陆区安全。", confirm: { [weak self] in self?.performAutopilot("自动降落") { try self?.provider.land() } }) }
    func cancelReturnHome() { perform("取消返航") { try provider.cancelReturnHome() } }
    func cancelLanding() { perform("取消降落") { try provider.cancelLanding() } }
    func confirmLanding() { perform("确认降落") { try provider.confirmLanding() } }
    func setPhoneChargingEnabled(_ enabled: Bool) {
        provider.setPhoneChargingEnabled(enabled)
    }
    func requestTakeOff() {
        log.append("起飞", "用户已触发起飞确认")
        showBanner("已收到起飞请求，请确认周围安全")
        alert = AppAlert(
            title: "确认起飞",
            message: "请确认周围安全。起飞会终止当前航测任务并清除其恢复点。",
            confirm: { [weak self] in
                guard let self else { return }
                if self.surveyControlActive { self.surveyRuntime.abort("用户请求起飞") }
                self.normalStop("准备自动起飞")
                self.takeOff()
            }
        )
    }

    func explainTakeoffInteraction(blockReason: String?) {
        let reason = blockReason ?? simulatorTakeoffReadinessIssue
        if let reason {
            log.append("起飞", "起飞交互已拦截：\(reason) · \(simulatorTakeoffDiagnostics)")
            if simulatorStatus.active || simulatorChanging {
                presentSimulatorTakeoffRecovery(reason: reason)
            } else {
                showBanner("起飞不可用：\(reason)", kind: .warning)
            }
            return
        }
        log.append("起飞", "单击起飞控件；当前就绪，等待长按")
        showBanner("为防误触，请长按起飞")
    }

    func takeOff() {
        guard !takeoffCommandPending else {
            report("起飞请求正在处理中，请等待当前结果")
            return
        }
        guard telemetry.connected else {
            failTakeoff("飞机未连接")
            return
        }
        if let flightStateFreshnessFailure = takeoffFlightStateFreshnessFailure() {
            failTakeoff(flightStateFreshnessFailure)
            return
        }
        guard !telemetry.flying, !isAirborneForControl else {
            takeoffStatus = "飞行中"
            return
        }
        guard flightModeAllowsNewAppControl else {
            failTakeoff("DJI 已进入返航、降落或保护状态")
            return
        }
        guard !simulatorChanging else {
            failTakeoff("DJI 内置仿真器仍在切换，请等待状态就绪")
            return
        }

        takeoffRequestGeneration &+= 1
        let generation = takeoffRequestGeneration
        takeoffMonitorTask?.cancel()
        takeoffCommandPending = true

        if hil.status.running || simulatorStatus.active {
            takeoffStatus = "正在等待仿真飞控就绪…"
            log.append("起飞", takeoffStatus)
            showBanner(takeoffStatus)
            takeoffMonitorTask = Task { [weak self] in
                guard let self else { return }
                await self.prepareSimulatorTakeoff(generation: generation)
            }
            return
        }
        submitTakeoff(generation: generation)
    }
    func resumeDJIConnection() {
        appInBackground = false
        provider.resumeConnection()
        provider.refreshDJIAccount()
        if hil.status.running, !simulatorManuallyDisabled {
            ensureHILSimulatorActive()
        }
    }
    func requestDJIAccountLogin() {
        guard !djiAccountOperationInProgress else { return }
        djiAccountStartupPromptHandled = true
        showDJIAccountStartupPrompt = false
        djiAccountLoginInProgress = true
        log.append("DJI账号", "dji_account_login_requested")
        provider.logIntoDJIAccount { [weak self] error in
            guard let self else { return }
            self.djiAccountLoginInProgress = false
            if let error {
                self.log.append("DJI账号", "dji_account_login_result=FAIL · \(error.localizedDescription)")
                self.showBanner(
                    AppLocalization.format("DJI 账号登录失败：%@", error.localizedDescription),
                    kind: .error,
                    durationNanoseconds: 4_500_000_000
                )
            } else {
                self.provider.refreshDJIAccount()
                if self.djiAccount.loggedIn {
                    if self.djiAccountLoginIsSimulated {
                        self.log.append("DJI账号", "dji_account_login_result=MOCK_SUCCESS")
                        self.showBanner(
                            AppLocalization.string("Mock 登录回调成功（非真实 DJI 登录）"),
                            kind: .success
                        )
                    } else {
                        self.log.append("DJI账号", "dji_account_login_result=SUCCESS")
                        self.showBanner(AppLocalization.string("DJI 账号登录成功"), kind: .success)
                    }
                } else {
                    self.log.append(
                        "DJI账号",
                        "dji_account_login_result=UNCONFIRMED · state=\(self.djiAccount.state.rawValue)"
                    )
                    self.showBanner(
                        AppLocalization.string("登录页面已结束，但 DJI SDK 尚未确认账号已登录，请重试或检查网络。"),
                        kind: .warning,
                        durationNanoseconds: 4_500_000_000
                    )
                }
            }
        }
    }
    func requestDJIAccountLogout() {
        guard djiAccount.loggedIn, !djiAccountOperationInProgress else { return }
        alert = AppAlert(
            title: AppLocalization.string("退出 DJI 账号"),
            message: AppLocalization.string("退出后，真机飞行能力可能受 DJI 激活与地区规则限制；你可以随时重新登录。"),
            cancelTitle: AppLocalization.string("取消"),
            confirmTitle: AppLocalization.string("确认退出"),
            confirm: { [weak self] in self?.performDJIAccountLogout() }
        )
    }
    private func performDJIAccountLogout() {
        guard djiAccount.loggedIn, !djiAccountOperationInProgress else { return }
        djiAccountLogoutInProgress = true
        log.append("DJI账号", "dji_account_logout_requested")
        provider.logOutOfDJIAccount { [weak self] error in
            guard let self else { return }
            self.djiAccountLogoutInProgress = false
            if let error {
                self.log.append("DJI账号", "dji_account_logout_result=FAIL · \(error.localizedDescription)")
                self.showBanner(
                    AppLocalization.format("DJI 账号退出失败：%@", error.localizedDescription),
                    kind: .error,
                    durationNanoseconds: 4_500_000_000
                )
                return
            }
            self.provider.refreshDJIAccount()
            self.log.append(
                "DJI账号",
                self.djiAccountLoginIsSimulated
                    ? "dji_account_logout_result=MOCK_SUCCESS"
                    : "dji_account_logout_result=SUCCESS"
            )
            self.showBanner(AppLocalization.string("DJI 账号退出成功"), kind: .success)
        }
    }
    func dismissDJIAccountStartupPrompt() {
        djiAccountStartupPromptHandled = true
        showDJIAccountStartupPrompt = false
        log.append("DJI账号", "dji_account_startup_prompt_choice=SKIP")
    }
    func startHIL() {
        invalidateHILSimulatorActivation()
        movingSimulatorRawLossLatched = false
        simulatorManuallyDisabled = false
        hilInitialSimulatorActivationPending = true
        showBanner("正在启动 HIL，并准备 DJI Simulator…")
        log.append("HIL", "用户请求启动 HIL")
        hil.start()
        if !hil.status.running {
            hilInitialSimulatorActivationPending = false
            report("HIL 启动失败：\(hil.status.message)")
        }
    }
    func stopHIL() {
        invalidateHILSimulatorActivation()
        movingSimulatorRawLossLatched = false
        hil.stop()
        log.append("HIL", "用户停止 HIL；UDP/TCP 端口已释放")
        showBanner("HIL 已停止，端口已释放", kind: .success)
    }
    func enterInactive() {
        // `.inactive` is also emitted for transient system interruptions and
        // presentation changes. It is not proof that the app left the screen,
        // and treating it as background used to pause a live survey when the
        // user switched between the map and camera. The real `.background`
        // transition below remains fail-closed.
        log.append("界面", "App 短暂失去活动状态；保持当前航测与控制状态")
    }
    func enterBackground() {
        appInBackground = true
        let shouldResumeInitialActivation = hilInitialSimulatorActivationPending
            || (hil.status.running && !simulatorStatus.active
                && (hilSimulatorActivationTask != nil
                    || hilSimulatorActivationCommandInFlight
                    || simulatorChanging))
        invalidateHILSimulatorActivation()
        hilInitialSimulatorActivationPending = shouldResumeInitialActivation
        surveyRuntime.appEnteredBackground()
        normalStop("App 进入后台")
        if hil.status.running {
            hil.reportSimulatorSource("App 已进入后台；控制与 DJI VS 已暂停，HIL UDP/TCP 会话保持")
            log.append("HIL", "App 进入后台；控制与 DJI VS 已暂停，UDP/TCP 会话保持")
        }
        provider.pauseConnection()
    }
    func takePhoto() { perform("拍照") { try provider.takePhoto() } }
    func toggleRecording() { perform(camera.recording ? "停止录像" : "开始录像") { try provider.toggleRecording() } }
    func openGallery() {
        guard camera.connected else { report("相机未连接，无法读取飞机相册"); return }
        guard telemetry.connected else { report("飞机连接不可用，无法读取飞机相册"); return }
        guard !camera.recording else { report("请先停止录像，再打开飞机相册"); return }
        let flightStateAge = Date().timeIntervalSince(telemetry.flightStateTimestamp)
        guard flightStateAge >= 0, flightStateAge <= 1.5 else {
            report("飞行状态遥测已过期，禁止切换相机媒体模式")
            return
        }
        guard !telemetry.flying else { report("飞行中禁止切换相机媒体模式"); return }
        galleryVisible = true
        refreshGallery()
    }
    func closeGallery() {
        galleryVisible = false
        galleryLoading = false
        mediaThumbnailRequests.removeAll()
        provider.exitMediaMode()
    }
    func refreshGallery() {
        guard galleryVisible else { return }
        galleryLoading = true
        galleryStatus = "正在读取飞机媒体…"
        mediaThumbnailRequests.removeAll()
        provider.refreshMediaList { [weak self] items, message in
            guard let self, self.galleryVisible else { return }
            if let message {
                self.galleryStatus = message
                self.galleryLoading = message.hasPrefix("正在")
                if !self.galleryLoading { self.log.append("错误", message) }
                return
            }
            self.mediaItems = items
            self.galleryLoading = false
            self.galleryStatus = items.isEmpty ? "飞机存储暂无媒体文件" : "已读取 \(items.count) 个媒体文件"
            self.log.append("相机", self.galleryStatus)
        }
    }
    func fetchMediaThumbnail(id: String) {
        guard galleryVisible, !mediaThumbnailRequests.contains(id),
              let index = mediaItems.firstIndex(where: { $0.id == id }),
              mediaItems[index].thumbnail == nil else { return }
        mediaThumbnailRequests.insert(id)
        provider.fetchMediaThumbnail(id: id) { [weak self] image in
            guard let self else { return }
            self.mediaThumbnailRequests.remove(id)
            guard let image, let index = self.mediaItems.firstIndex(where: { $0.id == id }) else { return }
            self.mediaItems[index].thumbnail = image
        }
    }
    func setSurveyGimbalPitch(_ degrees: Double) {
        perform(String(format: "航线云台 %.0f°", degrees)) { try provider.setGimbalPitch(degrees: degrees) }
    }

    func setSurveyGoHomeHeight(_ meters: Int) async throws {
        try await provider.setGoHomeHeight(meters: meters)
        log.append("航线", "返航高度已写入 \(meters) m")
    }
    func simulateDisconnect() { provider.simulateDisconnect() }
    func simulateStale() { provider.simulateStaleTelemetry(); log.append("仿真", "切换遥测新鲜度") }
    func simulateManualTakeover() { provider.simulateManualTakeover() }
    func simulateCameraError() { provider.simulateCameraError() }
    func exportSnapshot() { snapshotURL = log.snapshot(telemetry: telemetry, control: control); log.append("快照", snapshotURL == nil ? "导出失败" : "已生成状态快照") }

    @discardableResult
    func preflightSurvey(_ mission: SurveyMission) -> SurveyExecutionGateResult {
        surveyRuntime.preflight(mission)
    }

    func startSurveySimulator(_ mission: SurveyMission) {
        guard hilSimulatorRawReadyForNewControl else {
            report("飞行中的 DJI Simulator RAW 已超过 500 ms，禁止启动航测")
            return
        }
        surveyRuntime.startSimulator(mission, anotherControllerActive: vlnArmed || positionLoop.isActive)
        guard surveyRuntime.snapshot.state == .arming else { return }
        if hil.useVirtualFrames {
            if !ueBridge.enabled { ueBridge.toggle() }
            ueBridge.sendMission(mission, peerHost: hil.status.peerHost)
            log.append("HIL", "UE 航测图像已启用：自动开启只出站桥并发送任务")
        }
    }

    func pauseSurvey() { surveyRuntime.pause() }
    func resumeSurvey() {
        guard hilSimulatorRawReadyForNewControl else {
            report("飞行中的 DJI Simulator RAW 已超过 500 ms，禁止继续航测")
            return
        }
        surveyRuntime.resume(anotherControllerActive: vlnArmed || positionLoop.isActive)
    }
    func abortSurvey() { surveyRuntime.abort("用户终止航测") }
    func returnToCameraFromSurvey() {
        log.append("界面", "从航线地图返回相机主页；航测状态保持 \(surveyRuntime.snapshot.state.rawValue)")
        mapFullscreen = false
    }
    func restoreSurveyCheckpoint() -> SurveyMission? { surveyRuntime.restorePersistedMission() }
    func sendActiveSurveyMissionToUE() {
        let mission = try? SurveyMissionStore().restoreActive()
        ueBridge.sendMission(mission, peerHost: hil.status.peerHost)
    }

    private func ensureHILSimulatorActive() {
        guard hil.status.running, !appInBackground, !simulatorManuallyDisabled else { return }
        let activationGeneration = hilSimulatorActivationGeneration
        provider.setSimulatorUpdateFrequency(hil.configuration.simulatorStateHz)
        if simulatorStatus.active {
            hilInitialSimulatorActivationPending = false
            if simulatorRawStateFresh(), submitCurrentHILSimulatorSnapshot() {
                log.append("HIL", "已用当前 DJI Simulator RAW 状态初始化 HIL POSE；无需等待新的状态回调")
                hil.reportSimulatorSource("DJI Simulator RAW 已就绪")
                showBanner("HIL 已启动，DJI Simulator RAW 已就绪", kind: .success)
                return
            }
            guard hilSimulatorActivationTask == nil, !simulatorChanging else { return }
            simulatorChanging = true
            hil.reportSimulatorSource("DJI Simulator 已激活，正在刷新 RAW State 回调…")
            showBanner("Simulator 已激活，正在刷新 RAW 状态…")
            hilSimulatorActivationTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.hilSimulatorActivationGeneration == activationGeneration {
                        self.simulatorChanging = false
                        self.hilSimulatorActivationTask = nil
                    }
                }
                _ = await self.refreshHILSimulatorRawState(
                    activationGeneration: activationGeneration
                )
            }
            return
        }
        guard telemetry.connected else {
            hil.reportSimulatorSource("UDP/TCP 已启动；等待飞行器连接后恢复 Simulator")
            return
        }
        guard hilSimulatorActivationTask == nil, !simulatorChanging,
              !hilSimulatorActivationCommandInFlight else { return }
        simulatorChanging = true
        hil.reportSimulatorSource("正在自动启动 DJI Simulator…")
        showBanner("HIL 已启动，正在启动 DJI Simulator…")
        hilSimulatorActivationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.hilSimulatorActivationGeneration == activationGeneration {
                    self.simulatorChanging = false
                    self.hilSimulatorActivationTask = nil
                }
            }
            let maximumAttempts = max(1, self.simulatorTakeoffTiming.simulatorActivationAttempts)
            for attempt in 1...maximumAttempts {
                guard !Task.isCancelled, self.hil.status.running, !self.appInBackground,
                      self.hilSimulatorActivationGeneration == activationGeneration else { return }
                self.hil.reportSimulatorSource("正在自动启动 DJI Simulator（\(attempt)/\(maximumAttempts)）…")
                if attempt > 1 {
                    self.showBanner("Simulator 启动重试 \(attempt)/\(maximumAttempts)…", kind: .warning)
                }
                do {
                    try await self.issueHILSimulatorStart(
                        activationGeneration: activationGeneration
                    )
                    guard !Task.isCancelled, self.hil.status.running, !self.appInBackground,
                          self.hilSimulatorActivationGeneration == activationGeneration else { return }
                    self.hil.reportSimulatorSource("DJI Simulator 已启动，等待 RAW State 首样本")
                    self.log.append("HIL", "DJI Simulator 自动启动成功 attempt=\(attempt)；等待同源 RAW State")
                    self.showBanner("DJI Simulator 已启动，等待 RAW 状态…", kind: .success)
                    // MSDK4 may acknowledge Simulator start without delivering
                    // the first grounded SimulatorState.  Do the same bounded
                    // delegate refresh used for an already-active session now;
                    // otherwise POSE remains empty until a later takeoff changes
                    // the motor state and happens to trigger a new callback.
                    _ = await self.refreshHILSimulatorRawState(
                        activationGeneration: activationGeneration
                    )
                    return
                } catch {
                    guard !Task.isCancelled, self.hil.status.running, !self.appInBackground,
                          self.hilSimulatorActivationGeneration == activationGeneration else { return }
                    self.log.append("错误", "HIL Simulator 启动失败 attempt=\(attempt)/\(maximumAttempts)：\(self.describeDJIError(error))")
                    if attempt < maximumAttempts {
                        try? await Task.sleep(
                            nanoseconds: self.simulatorTakeoffTiming.simulatorActivationRetryDelayNanoseconds
                        )
                    } else {
                        self.hilInitialSimulatorActivationPending = false
                        let reason = "DJI Simulator 自动启动失败（已重试 \(maximumAttempts) 次）：\(self.describeDJIError(error))；HIL 网络保持"
                        self.hil.reportSimulatorSource(reason)
                        self.showBanner(reason, kind: .error, durationNanoseconds: 5_000_000_000)
                    }
                }
            }
        }
    }

    /// Rebinds only the SimulatorState delegate. It never stops or restarts the
    /// DJI Simulator and never tears down the HIL UDP/TCP session.
    @discardableResult
    private func refreshHILSimulatorRawState(activationGeneration: UInt64) async -> Bool {
        guard hil.status.running, !appInBackground,
              hilSimulatorActivationGeneration == activationGeneration else { return false }
        if simulatorRawStateFresh(), submitCurrentHILSimulatorSnapshot() {
            hil.reportSimulatorSource("DJI Simulator RAW 已就绪")
            return true
        }
        let attemptCount = max(1, simulatorTakeoffTiming.rawRefreshAttempts)
        for attempt in 1...attemptCount {
            guard !Task.isCancelled, hil.status.running, !appInBackground,
                  hilSimulatorActivationGeneration == activationGeneration,
                  simulatorStatus.active else { return false }
            let rebound = provider.refreshSimulatorStateCallback()
            hil.reportSimulatorSource(
                "Simulator RAW 回调刷新 \(attempt)/\(attemptCount) · \(rebound ? "已重绑" : "不可重绑")"
            )
            log.append("HIL", "Simulator RAW callback refresh attempt=\(attempt)/\(attemptCount) rebound=\(rebound)")
            try? await Task.sleep(nanoseconds: simulatorTakeoffTiming.rawRefreshIntervalNanoseconds)
            guard !Task.isCancelled, hil.status.running, !appInBackground,
                  hilSimulatorActivationGeneration == activationGeneration,
                  simulatorStatus.active else { return false }
            if simulatorRawStateFresh() {
                _ = submitCurrentHILSimulatorSnapshot()
                hil.reportSimulatorSource("DJI Simulator RAW 已恢复")
                showBanner("DJI Simulator RAW 状态已恢复", kind: .success)
                return true
            }
        }
        guard !Task.isCancelled, hil.status.running, !appInBackground,
              hilSimulatorActivationGeneration == activationGeneration else { return false }
        let reason = "Simulator 已激活，但连续 \(attemptCount) 次仍没有 RAW State；保持会话，不反复重启"
        hil.reportSimulatorSource(reason)
        showBanner(reason, kind: .error, durationNanoseconds: 5_000_000_000)
        log.append("错误", reason)
        return false
    }

    /// Serializes the non-cancellable DJI SDK command across HIL wire sessions.
    /// If the user stops and immediately restarts HIL while the SDK callback is
    /// outstanding, the old command is allowed to finish and the new session is
    /// then re-evaluated without issuing an overlapping start command.
    private func issueHILSimulatorStart(activationGeneration: UInt64) async throws {
        guard !appInBackground, hil.status.running,
              hilSimulatorActivationGeneration == activationGeneration,
              !hilSimulatorActivationCommandInFlight else {
            throw FlightActionError.unavailable("DJI Simulator 启动命令仍在等待 SDK 回调")
        }
        // Reconcile once more immediately before touching the SDK. A reconnect
        // callback can make Simulator active after ensureHILSimulatorActive()
        // selected the inactive branch but before this task gets the main actor.
        // In that case only RAW delegate refresh is needed.
        if simulatorStatus.active { return }
        hilSimulatorActivationCommandInFlight = true
        defer {
            hilSimulatorActivationCommandInFlight = false
            if hilSimulatorActivationGeneration != activationGeneration {
                simulatorChanging = false
                if hil.status.running, !appInBackground,
                   hilInitialSimulatorActivationPending
                    || (simulatorStatus.active && !simulatorRawStateFresh()) {
                    ensureHILSimulatorActive()
                }
            }
        }
        try await provider.setSimulator(enabled: true)
    }

    private func invalidateHILSimulatorActivation() {
        hilSimulatorActivationGeneration &+= 1
        let hadActivationTask = hilSimulatorActivationTask != nil
        hilSimulatorActivationTask?.cancel()
        hilSimulatorActivationTask = nil
        hilInitialSimulatorActivationPending = false
        if hadActivationTask, !hilSimulatorActivationCommandInFlight {
            simulatorChanging = false
        }
    }

    /// Starting the network session deliberately resets its wire-level pose.
    /// DJI MSDK4 may not emit another grounded SimulatorState until the motors
    /// change state, so seed the new HIL session from the ViewModel's last
    /// authoritative sample instead of waiting for a second provider callback.
    @discardableResult
    private func submitCurrentHILSimulatorSnapshot(
        _ simulator: FlightSimulatorStatus? = nil,
        command: VelocityCommand? = nil
    ) -> Bool {
        let simulator = simulator ?? authoritativeSimulatorState()
        guard hil.status.running,
              let simulator,
              SimulatorRawStatePolicy.hasAuthoritativeSample(simulator) else { return false }
        let appliedCommand = command ?? (surveyControlActive
            ? surveyRuntime.snapshot.lastCommand : latestDecision.command)
        hil.submit(telemetry: telemetry, simulator: simulator, command: appliedCommand)
        return true
    }

    /// A transient DJI/Simulator source loss is a control fault, not a network
    /// lifecycle event.  Keep UDP/TCP and the authenticated UE peer alive while
    /// stopping every app-owned motion path.  Resuming control remains explicit.
    private func pauseControlForTransientHILSourceLoss(
        _ reason: String,
        lastAuthoritativeSimulator: FlightSimulatorStatus? = nil
    ) {
        if [.arming, .running].contains(surveyRuntime.snapshot.state) {
            surveyRuntime.pause(reason: reason)
        }
        autoInference = false
        autoTask?.cancel()
        vlnArmed = false
        resetChunkExecutionState()
        velocityModelStateEstimator.reset()
        positionLoop.cancel()
        positionCommandLimiter.reset()
        provider.send(.zero)
        provider.setVirtualStick(enabled: false)
        latestDecision = safetyGate.blocked(reason)
        commandTimestamp = Date()
        Task { await inference.stop() }

        // Publish the zero command against the last valid pose when possible.
        // The provider may already have marked the new sample inactive, but UE
        // must never retain the previous non-zero applied-command fields.
        if let lastAuthoritativeSimulator {
            _ = submitCurrentHILSimulatorSnapshot(lastAuthoritativeSimulator, command: .zero)
        } else {
            _ = submitCurrentHILSimulatorSnapshot(command: .zero)
        }
        let message = "\(reason)；控制已归零并暂停，HIL UDP/TCP 会话保持，恢复后需手动继续"
        hil.reportSimulatorSource(message)
        log.append("HIL", message)
        showBanner(message, kind: .warning, durationNanoseconds: 4_500_000_000)
        updateControl()
    }

    private func handleHILFrameModeChanged(_ enabled: Bool) {
        let reason = enabled ? "切换到 UE 虚拟相机" : "切换回 DJI 图传"
        let surveyMoving = [.arming, .running].contains(surveyRuntime.snapshot.state)
        if surveyMoving {
            surveyRuntime.pause(reason: reason)
        } else if vlnArmed || autoInference || inferenceRunning || chunkExecutionActive {
            normalStop(reason)
        }
        // Android V4 keeps the low-latency HIL data plane independent from the
        // optional 30010 survey HTTP mirror. Selecting UE imagery alone must
        // not start 1 Hz HTTP telemetry or mission requests; that mirror is
        // enabled only when a survey mission actually starts (or explicitly
        // by the user in its own panel).
        if !enabled, let frame = provider.latestFrame {
            latestFrame = frame
        }
        log.append("HIL", "推理图像源：\(enabled ? "UE 虚拟相机" : "DJI 图传")")
        updateControl()
    }

    private func handleHILFrameSafetyFault(_ reason: String) {
        if [.arming, .running].contains(surveyRuntime.snapshot.state) {
            surveyRuntime.pause(reason: reason)
        } else if vlnArmed || autoInference || inferenceRunning || chunkExecutionActive {
            normalStop(reason)
        }
        let imageDisposition = hil.status.peerFresh
            ? "UE 图像源保持等待，位姿 UDP 仍正常"
            : "HIL 会话已失联，将切回 DJI 图传"
        log.append("错误", "HIL \(reason)；已暂停控制；\(imageDisposition)")
        showBanner("\(reason)；已暂停；\(imageDisposition)", kind: .warning,
                   durationNanoseconds: 4_500_000_000)
    }

    private func bind() {
        provider.onTelemetry = { [weak self] value in
            guard let self else { return }
            let telemetryWasConnected = self.telemetry.connected
            self.telemetry = value
            if !value.connected, self.takeoffCommandPending {
                self.failTakeoff("飞机连接在起飞过程中断开")
            }
            if telemetryWasConnected, !value.connected, self.hil.status.running {
                self.pauseControlForTransientHILSourceLoss("DJI 飞机连接暂时中断")
            } else if !telemetryWasConnected, value.connected, self.hil.status.running {
                _ = self.submitCurrentHILSimulatorSnapshot(command: .zero)
                let message = "DJI 飞机连接已恢复；HIL 会话继续，控制保持暂停"
                self.hil.reportSimulatorSource(message)
                self.log.append("HIL", message)
                self.showBanner(message, kind: .success)
                if !self.simulatorManuallyDisabled,
                   (!self.simulatorStatus.active || !self.simulatorRawStateFresh()) {
                    self.hilInitialSimulatorActivationPending = true
                    self.ensureHILSimulatorActive()
                }
            }
            self.velocityModelStateEstimator.update(value)
            self.surveyRuntime.updateTelemetry(value)
            let djiInterventionReason = SurveyExternalInterventionPolicy.reason(
                mode: value.mode,
                smartReturnToHomeState: value.smartReturnToHomeState,
                locallyInitiatedReturnHome: self.surveyRuntime.ownsPendingReturnHomeHandoff
            )
            let appControlStillActive = value.virtualStickActive || self.vlnArmed
                || self.positionLoop.isActive || self.autoInference
                || self.inferenceRunning || self.chunkExecutionActive
            let airborneLossReason = self.vlnMotionControlActive && !self.isAirborneForControl
                ? "检测到飞机已不在飞行状态"
                : nil
            let interventionReason = djiInterventionReason.flatMap {
                appControlStillActive ? $0 : nil
            } ?? airborneLossReason
            if interventionReason == nil {
                self.externalInterventionHandled = false
            }
            if let reason = interventionReason, !self.externalInterventionHandled {
                self.externalInterventionHandled = true
                // Operator/DJI intervention is recoverable for an active survey.
                // Pause first so normalStop cannot turn its checkpoint into ABORTED.
                if [.arming, .running].contains(self.surveyRuntime.snapshot.state) {
                    self.surveyRuntime.pause(reason: reason)
                }
                self.normalStop(reason)
            } else {
                self.advancePositionLoop()
            }
            self.updateControl()
            self.ueBridge.submit(telemetry: value, simulator: self.simulatorStatus,
                                 runtime: self.surveyRuntime.snapshot,
                                 peerHost: self.hil.status.peerHost)
        }
        provider.onCamera = { [weak self] value in
            self?.camera = value
            self?.surveyRuntime.updateCamera(value)
        }
        provider.onFrame = { [weak self] value in
            guard let self,
                  !(self.hil.status.running && self.hil.useVirtualFrames) else { return }
            self.latestFrame = value
        }
        provider.onSimulator = { [weak self] value in
            guard let self else { return }
            let previousSimulator = self.simulatorStatus
            let simulatorWasActive = self.simulatorStatus.active
            let simulatorHadState = self.simulatorStatus.stateReceived
            let wasInitialActivationPending = self.hilInitialSimulatorActivationPending
            self.simulatorStatus = value
            self.surveyRuntime.updateSimulator(value)
            if !previousSimulator.motorsOn, value.motorsOn {
                self.log.append("仿真", "检测到内八/电机解锁成功；等待离地")
                self.showBanner("仿真电机已启动，等待离地", kind: .success)
            }
            if !previousSimulator.flying, value.flying {
                self.log.append("仿真", "检测到仿真飞机已离地")
                self.showBanner("仿真飞行中", kind: .success)
            }
            if previousSimulator.motorsOn, !value.motorsOn, !value.flying {
                self.log.append("仿真", "检测到仿真电机已停止")
                self.showBanner("仿真电机已停止", kind: .warning)
            }
            if value.active {
                self.hilInitialSimulatorActivationPending = false
            }
            if value.active, value.stateReceived, !simulatorHadState {
                self.showBanner("DJI Simulator RAW 状态已就绪", kind: .success)
            }
            if simulatorWasActive, !value.active, self.takeoffCommandPending,
               !self.simulatorTakeoffRecoveryInProgress,
               !self.explicitSimulatorStopInProgress {
                self.failTakeoff("DJI Simulator 在起飞过程中断开")
            }
            if simulatorWasActive, !value.active, self.hil.status.running,
               !self.simulatorTakeoffRecoveryInProgress,
               !self.explicitSimulatorStopInProgress {
                self.pauseControlForTransientHILSourceLoss(
                    "DJI Simulator 状态暂时中断",
                    lastAuthoritativeSimulator: previousSimulator
                )
                if !self.simulatorManuallyDisabled {
                    self.hilInitialSimulatorActivationPending = true
                    let recoveryGeneration = self.hilSimulatorActivationGeneration
                    self.log.append("HIL", "Simulator 意外中断；1.5 秒后自动协调恢复，HIL 网络保持")
                    Task { [weak self] in
                        try? await Task.sleep(
                            nanoseconds: self?.simulatorTakeoffTiming.simulatorUnexpectedRecoveryDelayNanoseconds
                                ?? 1_500_000_000
                        )
                        guard let self, !Task.isCancelled,
                              self.hil.status.running, !self.appInBackground,
                              !self.simulatorManuallyDisabled,
                              self.hilSimulatorActivationGeneration == recoveryGeneration,
                              !self.simulatorStatus.active else { return }
                        self.ensureHILSimulatorActive()
                    }
                }
            }
            if value.active, !value.flying, self.vlnMotionControlActive {
                self.normalStop("检测到 DJI Simulator 已不在飞行状态")
            }
            if self.hil.status.running, value.active, value.stateReceived {
                _ = self.submitCurrentHILSimulatorSnapshot(value)
                if !simulatorWasActive {
                    let message = "DJI Simulator RAW 已恢复；HIL 会话继续，控制保持暂停"
                    self.hil.reportSimulatorSource(message)
                    self.log.append("HIL", message)
                }
            } else if self.hil.status.running, value.active, !value.stateReceived,
                      !self.simulatorTakeoffRecoveryInProgress,
                      !self.explicitSimulatorStopInProgress {
                // A reattached MSDK4 Simulator can report active before it
                // produces another grounded RAW sample. Rebind its delegate;
                // never stop/start the physical Simulator for this recovery.
                // If an inactive-state activation task is only waiting in its
                // settle window, replace it immediately with RAW-only recovery.
                if wasInitialActivationPending,
                   self.hilSimulatorActivationTask != nil,
                   !self.hilSimulatorActivationCommandInFlight {
                    self.hilSimulatorActivationTask?.cancel()
                    self.hilSimulatorActivationTask = nil
                    self.simulatorChanging = false
                }
                self.ensureHILSimulatorActive()
            } else if self.hil.status.running, value.available, !value.active,
                      self.hilInitialSimulatorActivationPending,
                      !self.simulatorTakeoffRecoveryInProgress,
                      !self.explicitSimulatorStopInProgress {
                self.ensureHILSimulatorActive()
            }
        }
        provider.onDJIAccount = { [weak self] snapshot in
            guard let self else { return }
            let changed = snapshot != self.djiAccount
            self.djiAccount = snapshot
            if changed {
                self.log.append(
                    "DJI账号",
                    "dji_account_state=\(snapshot.state.rawValue)" +
                        (snapshot.maskedAccount.map { " · account=\($0)" } ?? "")
                )
            }
            if snapshot.loggedIn {
                self.showDJIAccountStartupPrompt = false
            } else if snapshot.shouldOfferStartupLogin,
                      !self.djiAccountStartupPromptHandled {
                self.showDJIAccountStartupPrompt = true
            }
        }
        provider.onDiagnostic = { [weak self] kind, message in
            guard let self else { return }
            let localizedKind = AppLocalization.string(kind)
            let localizedMessage = AppLocalization.runtime(message)
            self.log.append(localizedKind, localizedMessage)
            if kind == "错误" {
                self.showBanner(localizedMessage, kind: .error, durationNanoseconds: 4_500_000_000)
            }
        }
        provider.onVirtualStickSendFailure = { [weak self] message in
            guard let self else { return }
            if [.arming, .running].contains(self.surveyRuntime.snapshot.state) {
                self.surveyRuntime.pause(reason: "Virtual Stick 发送失败：\(message)")
            }
            if self.vlnArmed {
                self.normalStop("Virtual Stick 发送失败")
            }
        }
        provider.onManualTakeover = { [weak self] in
            guard let self else { return }
            self.surveyRuntime.manualTakeover()
            self.manualTakeover = true; self.vlnArmed = false; self.autoInference = false; self.autoTask?.cancel()
            self.resetChunkExecutionState()
            self.positionLoop.cancel()
            self.positionCommandLimiter.reset()
            self.provider.send(.zero)
            self.provider.setVirtualStick(enabled: false)
            Task { await self.inference.stop() }
            self.latestDecision = self.safetyGate.blocked("人工摇杆接管")
            self.log.append("接管", "检测到人工摇杆；已归零并释放 Virtual Stick")
            self.updateControl()
        }
    }

    private func handleHILEvent(_ event: OpenFlyHILProtocol.Event) {
        log.append("HIL", "UE event=\(event.kind) stop=\(String(format: "%.3f", event.stopScore)) · \(event.reason)")
        switch event.kind {
        case .info: break
        case .stop:
            if event.stopScore.isFinite, event.stopScore >= stopThreshold,
               vlnArmed || autoInference || inferenceRunning || chunkExecutionActive || surveyControlActive {
                normalStop("UE HIL STOP \(String(format: "%.2f", event.stopScore)) ≥ \(String(format: "%.1f", stopThreshold))：\(event.reason)")
            }
        case .collision:
            if vlnArmed || autoInference || inferenceRunning || chunkExecutionActive || surveyControlActive {
                normalStop("UE HIL 碰撞：\(event.reason)")
            }
        case .emergency:
            emergencyStop()
        }
    }

    private func performInference(promptOverride: String? = nil) async {
        // Every inference path converges here, including queued chunk and auto
        // tasks that may resume after an await. A cancelled task must not
        // re-enter the runtime after model maintenance has taken ownership.
        guard !Task.isCancelled, !modelOperationInProgress else { return }
        guard modelLoaded else { report("请先加载模型"); return }
        guard !inferenceRunning else { return }
        let belongsToChunk = chunkExecutionActive
        let inferencePrompt = (activeChunkPrompt ?? promptOverride ?? prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inferencePrompt.isEmpty else {
            report("Prompt 不能为空")
            if belongsToChunk { abortChunkExecution("Prompt 为空") }
            return
        }
        inferenceRunning = true
        defer { inferenceRunning = false }
        do {
            await inference.configureExecution(
                executedPrefix: continuousChunkEnabled ? executedPrefix : 1,
                stopThreshold: stopThreshold
            )
            let queuedAction = await inference.hasQueuedAction()
            let frame: CameraFrame
            if queuedAction {
                frame = latestFrame ?? CameraFrame(
                    sequence: -1, capturedAt: telemetry.frameTimestamp,
                    jpeg: Data(), width: 0, height: 0
                )
            } else if hil.useVirtualFrames {
                frame = try hil.requireFreshVirtualFrame()
            } else {
                frame = try await provider.captureModelFrame()
            }
            if !queuedAction { latestFrame = frame }
            var inferenceTelemetry = telemetry
            inferenceTelemetry.frameTimestamp = frame.capturedAt
            let modelState = positionClosureMode == .velocityEstimate
                ? velocityModelStateEstimator.modelState : nil
            var result = try await inference.infer(
                frame: frame,
                prompt: inferencePrompt,
                telemetry: inferenceTelemetry,
                modelState: modelState
            )
            if !result.yawIsExplicit,
               hypot(result.action.forwardMeters, result.action.rightMeters) >= 0.05 {
                result.action.yawDegrees = OrinTrajectorySemantics.yawDeltaDegrees(
                    forward: result.action.forwardMeters,
                    right: result.action.rightMeters
                )
            }
            if result.replanned {
                log.captureInference(frame: frame, prompt: inferencePrompt, modelState: modelState, result: result)
            }
            guard !belongsToChunk || chunkExecutionActive else {
                provider.send(.zero)
                return
            }
            if belongsToChunk { registerChunkResult(result) }
            latestAction = result.action; latestLatency = result.latencyMilliseconds
            let decision = safetyGate.evaluate(
                action: result.action,
                telemetry: inferenceTelemetry,
                emergencyStopped: emergencyStopped,
                stopThreshold: stopThreshold
            )
            latestDecision = decision; commandTimestamp = Date()
            let pipelineState = result.replanned ? "重规划" : "队列"
            log.append("输出", "x=\(f(result.action.forwardMeters)) y=\(f(result.action.rightMeters)) z=\(f(result.action.upMeters)) yawΔ=\(f(result.action.yawDegrees))° stop=\(f(result.action.stopScore)) · \(Int(result.latencyMilliseconds))ms · \(pipelineState) 剩余\(result.chunkRemaining)")
            if result.replanned, !result.predictedActions.isEmpty {
                let stops = result.predictedActions.map { f($0.stopScore) }.joined(separator: ",")
                log.append("预测", "H\(result.predictedActions.count) stop=[\(stops)] · 执行至 H\(result.chunkRemaining + 1)")
            }
            if !result.stages.isEmpty {
                let stages = result.stages.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\(Int($0.value))ms" }.joined(separator: " ")
                log.append("阶段", stages)
            }
            if UAVFlowPolicyContract.shouldStop(result.action.stopScore, threshold: stopThreshold) {
                normalStop("模型停止 stop=\(f(result.action.stopScore)) ≥ \(f(stopThreshold))")
                return
            }
            if vlnArmed && decision.eligible {
                do {
                    let referenceHeading = belongsToChunk ? (chunkPlannedHeadingDegrees ?? telemetry.heading) : nil
                    let carryNorth = belongsToChunk ? chunkCarryNorthMeters : 0
                    let carryEast = belongsToChunk ? chunkCarryEastMeters : 0
                    let carryUp = belongsToChunk ? chunkCarryUpMeters : 0
                    let hasFollowingStep = belongsToChunk && chunkRemaining > 0
                    let step = try positionLoop.start(
                        action: result.action,
                        telemetry: telemetry,
                        mode: positionClosureMode,
                        maximumHorizontalSpeed: maxVLNHorizontalSpeed,
                        referenceHeadingDegrees: referenceHeading,
                        carryNorthMeters: carryNorth,
                        carryEastMeters: carryEast,
                        carryUpMeters: carryUp,
                        hasFollowingStep: hasFollowingStep,
                        flyThroughEnabled: flyThroughEnabled
                    )
                    if belongsToChunk {
                        chunkPlannedHeadingDegrees = OrinTrajectorySemantics.normalizedHeading(
                            (referenceHeading ?? telemetry.heading) + result.action.yawDegrees
                        )
                        chunkCarryNorthMeters = 0
                        chunkCarryEastMeters = 0
                        chunkCarryUpMeters = 0
                    }
                    let verticalDescription = abs(result.action.upMeters) <= 0.05
                        ? "垂直由 DJI 定高"
                        : "垂直速度积分目标 \(f(result.action.upMeters))m"
                    log.append("控制", "\(positionClosureMode.label)启动：前\(f(result.action.forwardMeters)) 右\(f(result.action.rightMeters))m；\(verticalDescription)")
                    applyPositionStep(step)
                } catch {
                    positionLoop.cancel()
                    provider.send(.zero)
                    latestDecision = safetyGate.blocked(error.localizedDescription)
                    report("位置闭环已阻止：\(error.localizedDescription)")
                    if belongsToChunk { abortChunkExecution("位置闭环阻止：\(error.localizedDescription)") }
                }
            } else if vlnArmed {
                positionLoop.cancel()
                provider.send(.zero)
                if belongsToChunk { abortChunkExecution("动作未通过安全门：\(decision.reason)") }
            }
            updateControl()
        } catch {
            report("推理失败：\(error.localizedDescription)")
            if belongsToChunk { abortChunkExecution("推理失败") }
        }
    }

    private func watchdogTick() {
        let authoritativeSimulator = authoritativeSimulatorState()
        let movingSimulatorRawStale = hil.status.running
            && simulatorStatus.active
            && (authoritativeSimulator?.motorsOn == true || authoritativeSimulator?.flying == true)
            && !(authoritativeSimulator.map {
                SimulatorRawStatePolicy.isReadyForControl($0)
            } ?? false)
        if movingSimulatorRawStale {
            let reason = "飞行中的 DJI Simulator RAW 已超过 500 ms；停止发送旧 POSE"
            let appMotionActive = telemetry.virtualStickActive || vlnArmed
                || positionLoop.isActive || autoInference || inferenceRunning
                || chunkExecutionActive
                || [.arming, .running].contains(surveyRuntime.snapshot.state)
            if appMotionActive {
                movingSimulatorRawLossLatched = true
                pauseControlForTransientHILSourceLoss(reason)
                return
            }
            if !movingSimulatorRawLossLatched {
                movingSimulatorRawLossLatched = true
                hil.reportSimulatorSource(reason)
                log.append("HIL", reason)
            }
        } else if movingSimulatorRawLossLatched, simulatorRawStateFresh() {
            movingSimulatorRawLossLatched = false
            let message = "DJI Simulator RAW 已恢复；控制保持暂停，需手动继续"
            hil.reportSimulatorSource(message)
            log.append("HIL", message)
        }
        if vlnArmed {
            if positionLoop.isActive {
                advancePositionLoop()
                updateControl()
                return
            }
            let decision = safetyGate.evaluate(
                action: latestAction,
                telemetry: telemetry,
                emergencyStopped: emergencyStopped,
                stopThreshold: stopThreshold
            )
            if !commandFresh || !decision.eligible {
                provider.send(.zero)
                latestDecision = commandFresh ? decision : safetyGate.blocked("指令看门狗超时")
            }
        }
        updateControl()
    }

    private func advancePositionLoop() {
        guard vlnArmed, positionLoop.isActive else { return }
        applyPositionStep(positionLoop.step(telemetry: telemetry))
    }

    private func applyPositionStep(_ step: RelativePositionClosedLoop.Step) {
        guard hilSimulatorRawReadyForNewControl else {
            let reason = "飞行中的 DJI Simulator RAW 已超过 500 ms；拒绝继续下发位置控制"
            movingSimulatorRawLossLatched = true
            pauseControlForTransientHILSourceLoss(reason)
            return
        }
        if step.terminal {
            let continuesChunk = handleChunkStepTerminal(step)
            if continuesChunk {
                log.append("Chunk", "动作 \(chunkStepsExecuted)/\(chunkStepsTotal) 已到达；连续衔接下一步")
            } else {
                positionCommandLimiter.reset()
                provider.send(.zero)
                latestDecision = safetyGate.blocked(step.reason)
                log.append(step.successful ? "控制" : "错误", "\(step.reason)；平面残差 \(f(step.horizontalErrorMeters))m，垂直残差 \(f(step.verticalErrorMeters))m，已悬停")
            }
        } else {
            let smoothedCommand = positionCommandLimiter.limit(step.command, at: telemetry.timestamp)
            latestDecision = SafetyDecision(command: smoothedCommand, eligible: true, reason: step.reason)
            provider.send(smoothedCommand)
            if (ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_AUTOTEST"] == "1" ||
                ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_FUNCTION_TEST"] == "1"),
               Date().timeIntervalSince(lastPositionLoopDiagnosticAt) >= 0.5 {
                lastPositionLoopDiagnosticAt = Date()
                log.append("闭环", String(
                    format: "%@ · cmd前%.2f右%.2f上%.2f · ALT %.2f · vZ上%.2f · vN%.2f vE%.2f · hdg%.1f · simX%.2f Y%.2f",
                    step.reason, smoothedCommand.forward, smoothedCommand.right, smoothedCommand.up,
                    telemetry.altitude, telemetry.verticalSpeed,
                    telemetry.velocityNorth, telemetry.velocityEast, telemetry.heading,
                    simulatorStatus.positionX, simulatorStatus.positionY
                ))
            }
        }
    }

    private func beginChunkExecution(prompt: String) {
        chunkTask?.cancel()
        positionCommandLimiter.reset()
        activeChunkPrompt = prompt
        chunkExecutionActive = true
        chunkStepsExecuted = 0
        chunkStepsTotal = 0
        chunkRemaining = 0
        chunkPlannedHeadingDegrees = telemetry.heading
        chunkCarryNorthMeters = 0
        chunkCarryEastMeters = 0
        chunkCarryUpMeters = 0
        log.append("Chunk", "开始连续执行一个完整 chunk")
    }

    private func registerChunkResult(_ result: InferenceResult) {
        chunkRemaining = max(0, result.chunkRemaining)
        if result.replanned || chunkStepsTotal == 0 {
            chunkStepsTotal = chunkStepsExecuted + chunkRemaining + 1
        }
        chunkStepsExecuted += 1
    }

    private func handleChunkStepTerminal(_ step: RelativePositionClosedLoop.Step) -> Bool {
        guard chunkExecutionActive else { return false }
        guard step.successful else {
            abortChunkExecution("动作 \(chunkStepsExecuted) 执行失败：\(step.reason)")
            return false
        }
        guard chunkRemaining > 0 else {
            let completed = chunkStepsExecuted
            let total = max(chunkStepsTotal, completed)
            resetChunkExecutionState(preserveProgress: true)
            chunkStepsExecuted = completed
            chunkStepsTotal = total
            log.append("Chunk", "连续执行完成 \(completed)/\(total)，已悬停")
            return false
        }

        chunkCarryNorthMeters = step.residualNorthMeters
        chunkCarryEastMeters = step.residualEastMeters
        chunkCarryUpMeters = step.residualUpMeters

        chunkTask?.cancel()
        chunkTask = Task { [weak self] in
            await Task.yield()
            guard let self, self.chunkExecutionActive, self.vlnArmed else { return }
            await self.performInference()
        }
        // Keep the previous bounded command during the single-frame queue-pop gap;
        // the next queued action replaces it without an artificial zero-speed pause.
        return true
    }

    private func automaticInferenceTick() async {
        guard autoInference, !inferenceRunning else { return }
        if continuousChunkEnabled {
            guard vlnArmed, !chunkExecutionActive, !positionLoop.isActive else { return }
            let requestedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requestedPrompt.isEmpty else {
                autoInference = false
                report("Prompt 不能为空；自动连续 Chunk 已停止")
                return
            }
            beginChunkExecution(prompt: requestedPrompt)
            if !inference.replansEveryAction { await inference.stop() }
            await performInference(promptOverride: requestedPrompt)
        } else {
            await performInference()
        }
    }

    private func abortChunkExecution(_ reason: String, logEvent: Bool = true) {
        let hadChunk = chunkExecutionActive || chunkRemaining > 0
        if autoInference && continuousChunkEnabled {
            autoInference = false
            autoTask?.cancel()
            log.append("停止", "自动连续 Chunk 已停止：\(reason)")
        }
        resetChunkExecutionState(preserveProgress: true)
        positionLoop.cancel()
        positionCommandLimiter.reset()
        provider.send(.zero)
        Task { await inference.stop() }
        if logEvent, hadChunk { log.append("停止", "Chunk 连续执行中止：\(reason)") }
    }

    private func resetChunkExecutionState(preserveProgress: Bool = false) {
        chunkTask?.cancel()
        chunkTask = nil
        chunkExecutionActive = false
        chunkRemaining = 0
        activeChunkPrompt = nil
        chunkPlannedHeadingDegrees = nil
        chunkCarryNorthMeters = 0
        chunkCarryEastMeters = 0
        chunkCarryUpMeters = 0
        if !preserveProgress {
            chunkStepsExecuted = 0
            chunkStepsTotal = 0
        }
    }

    private func updateControl(surveyState: SurveyExecutionState? = nil) {
        var controlTelemetry = telemetry
        if simulatorStatus.active { controlTelemetry.flying = simulatorStatus.flying }
        let resolved = supervisor.resolve(
            telemetry: controlTelemetry, emergencyStopped: emergencyStopped, vlnArmed: vlnArmed,
            commandFresh: commandFresh, commandExecuting: vlnArmed && latestDecision.eligible && !latestDecision.command.isZero,
            manualTakeover: manualTakeover, surveyState: surveyState ?? surveyRuntime.snapshot.state
        )
        let next = !OpenFlyBuildFeatures.vlnInference
            && resolved.mode == .manual && resolved.owner == .remote
            ? ControlSnapshot(mode: .manual, owner: .remote, reason: "手动飞行")
            : resolved
        if next != control { control = next }
    }

    /// A ground state is only an intervention after VLN has taken ownership.
    /// This deliberately excludes model-only inference and the settings-only VS
    /// diagnostic switch so an idle app on the ground does not report a fault.
    private var vlnMotionControlActive: Bool {
        vlnArmed || positionLoop.isActive || autoInference || chunkExecutionActive
    }

    private var flightModeAllowsNewAppControl: Bool {
        switch telemetry.mode {
        case .returningHome, .landing, .emergency, .disconnected:
            return false
        case .manual, .gps, .opti, .vln:
            return true
        }
    }

    private func performAutopilot(_ label: String, action: @escaping () throws -> Void) {
        guard !autopilotCommandPending else {
            report("正在切换 DJI 自动飞行，请稍候")
            return
        }
        if surveyControlActive { surveyRuntime.pause(reason: "切换至\(label)") }
        normalStop("切换至\(label)")
        autopilotCommandPending = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.autopilotCommandPending = false }
            let released = await self.waitFor(
                { !self.telemetry.virtualStickActive },
                attempts: 30,
                intervalNanoseconds: 50_000_000
            )
            if !released {
                self.log.append("飞控", "\(label)等待 VS 释放 1.5 秒超时；执行 DJI 兜底请求")
            }
            guard self.telemetry.connected, self.isAirborneForControl else {
                self.report("\(label)已取消：飞机已断开或不在飞行状态")
                return
            }
            guard self.flightModeAllowsNewAppControl else {
                self.report("\(label)已取消：DJI 已进入返航、降落或保护状态")
                return
            }
            self.perform(label, action)
        }
    }

    private func perform(_ label: String, _ action: () throws -> Void) {
        do { try action(); log.append("飞控", "\(label)指令已提交至 \(provider.providerName)"); updateControl() }
        catch { report("\(label)失败：\(error.localizedDescription)") }
    }

    private func prepareSimulatorTakeoff(generation: UInt64, commandAttempt: Int = 1) async {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var readySince: UInt64?
        var callbackRefreshAttempted = false
        var navigationWaitLogged = false

        while !Task.isCancelled, generation == takeoffRequestGeneration, takeoffCommandPending {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= startedAt,
                  now - startedAt < simulatorTakeoffTiming.readinessTimeoutNanoseconds else {
                failTakeoff("等待仿真飞控就绪超时 · \(simulatorTakeoffDiagnostics)", generation: generation)
                return
            }
            guard telemetry.connected else {
                failTakeoff("飞控桥接不可用", generation: generation)
                return
            }

            let rawReady = simulatorRawStateFresh(now: now)
            let navigationReady = simulatorNavigationReady
            if rawReady && navigationReady {
                if readySince == nil {
                    readySince = now
                    takeoffStatus = "仿真飞控已就绪，稳定 1 秒…"
                    log.append("起飞", "RAW SimulatorState 与导航状态就绪；稳定等待 1000 ms")
                    showBanner(takeoffStatus)
                }
                if let readySince,
                   now - readySince >= simulatorTakeoffTiming.readinessStableNanoseconds { break }
            } else {
                readySince = nil
                if rawReady, !navigationReady, !navigationWaitLogged {
                    navigationWaitLogged = true
                    takeoffStatus = "RAW 已就绪，等待 P-GPS / Home / 定位…"
                    log.append("起飞", "RAW 已就绪；等待 P-GPS/Home/location")
                    showBanner(takeoffStatus)
                }
            }

            if simulatorStatus.active, !rawReady, !simulatorStatus.motorsOn,
               !simulatorStatus.flying, !callbackRefreshAttempted,
               now - startedAt >= simulatorTakeoffTiming.rawRefreshStartDelayNanoseconds {
                callbackRefreshAttempted = true
                let recovered = await refreshGroundedSimulatorStateForTakeoff(generation: generation)
                guard recovered else { return }
                readySince = nil
                navigationWaitLogged = false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard !Task.isCancelled, generation == takeoffRequestGeneration,
              takeoffCommandPending else { return }
        if telemetry.virtualStickActive {
            takeoffStatus = "正在释放 Virtual Stick…"
            log.append("起飞", "仿真起飞前归零并释放 Virtual Stick")
            showBanner(takeoffStatus)
            provider.send(.zero)
            provider.setVirtualStick(enabled: false)
            let released = await waitFor(
                { !self.telemetry.virtualStickActive },
                attempts: 30,
                intervalNanoseconds: 50_000_000
            )
            guard released else {
                failTakeoff("释放 Virtual Stick 失败", generation: generation)
                return
            }
        }
        submitTakeoff(generation: generation, attempt: commandAttempt)
    }

    private func refreshGroundedSimulatorStateForTakeoff(generation: UInt64) async -> Bool {
        guard generation == takeoffRequestGeneration, takeoffCommandPending else { return false }
        simulatorTakeoffRecoveryInProgress = true
        takeoffStatus = "仿真状态未更新，正在刷新 RAW 回调…"
        log.append("起飞", "保持 Simulator/HIL 会话；仅刷新 RAW delegate，不执行 stop/start")
        showBanner(takeoffStatus)
        defer { simulatorTakeoffRecoveryInProgress = false }

        let attemptCount = max(1, simulatorTakeoffTiming.rawRefreshAttempts)
        for attempt in 1...attemptCount {
            guard !Task.isCancelled, generation == takeoffRequestGeneration,
                  takeoffCommandPending else { return false }
            let rebound = provider.refreshSimulatorStateCallback()
            log.append("起飞", "Simulator RAW delegate 刷新 \(attempt)/\(attemptCount) · \(rebound ? "已重绑" : "不可重绑")")
            try? await Task.sleep(nanoseconds: simulatorTakeoffTiming.rawRefreshIntervalNanoseconds)
            if simulatorRawStateFresh() {
                log.append("起飞", "RAW SimulatorState 已在第 \(attempt) 次 delegate 刷新后恢复")
                return true
            }
        }
        failTakeoff("连续 \(attemptCount) 次刷新 RAW delegate 仍无状态；已保持 Simulator 与 HIL 在线并停止起飞，请勿反复开关", generation: generation)
        return false
    }

    private var simulatorNavigationReady: Bool {
        SimulatorNavigationReadiness.isReady(
            simulator: simulatorStatus,
            telemetry: telemetry
        )
    }

    private func simulatorRawStateFresh(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard simulatorStatus.active else { return false }
        // Production DJI callbacks publish every raw sample to this lock-backed
        // store before throttling the SwiftUI snapshot to 10 Hz. Reading the UI
        // copy here would falsely pause control whenever MainActor is busy for
        // more than 500 ms even though RAW and UE POSE are still flowing.
        guard let authoritative = authoritativeSimulatorState() else { return false }
        return SimulatorRawStatePolicy.isReadyForControl(authoritative, now: now)
    }

    /// Returns the newest authoritative sample, preferring the provider-owned
    /// RAW store over the throttled SwiftUI snapshot when both are available.
    private func authoritativeSimulatorState() -> FlightSimulatorStatus? {
        guard simulatorStatus.active else { return nil }
        let candidates = [hil.rawSimulatorStateStore.latest(), simulatorStatus]
            .compactMap { $0 }
            .filter { SimulatorRawStatePolicy.hasAuthoritativeSample($0) }
        return candidates.max {
            $0.sampleMonotonicNanoseconds < $1.sampleMonotonicNanoseconds
        }
    }

    private var simulatorTakeoffDiagnostics: String {
        "connected=\(telemetry.connected) mode=\(telemetry.mode.rawValue) "
            + "gps=L\(telemetry.gpsSignalLevel) satellites=\(telemetry.satellites) "
            + "location=\(telemetry.aircraftLocationValid) home=\(telemetry.homeLocationSet) "
            + "simulator=\(simulatorStatus.active) raw=\(simulatorStatus.stateReceived) "
            + "motors=\(simulatorStatus.motorsOn) flying=\(simulatorStatus.flying)"
    }

    private var simulatorTakeoffReadinessIssue: String? {
        guard simulatorStatus.active else { return nil }
        guard simulatorStatus.stateReceived,
              simulatorStatus.sampleMonotonicNanoseconds > 0 else {
            return "Simulator 显示已开启，但尚未收到 DJI RAW 状态"
        }
        guard telemetry.satellites >= 6 else {
            return "Simulator 定位未就绪：GPS 卫星仅 \(telemetry.satellites) 颗"
        }
        guard (2...5).contains(telemetry.gpsSignalLevel) else {
            return "Simulator 定位未就绪：GPS 信号等级 \(telemetry.gpsSignalLevel)"
        }
        guard telemetry.aircraftLocationValid else {
            return "Simulator 定位未就绪：飞机位置无效"
        }
        guard telemetry.homeLocationSet else {
            return "Simulator 定位未就绪：返航点 Home 未建立"
        }
        return nil
    }

    private func presentSimulatorTakeoffRecovery(reason: String) {
        alert = AppAlert(
            title: "仿真起飞未就绪",
            message: "\(reason)\n\n可先重启 DJI 内置仿真器；如果仍然无法起飞，请退出并重新打开 OpenFly Go。",
            cancelTitle: "稍后处理",
            confirmTitle: "重启仿真",
            confirm: { [weak self] in self?.restartSimulatorForTakeoffRecovery() }
        )
    }

    private func restartSimulatorForTakeoffRecovery() {
        guard telemetry.connected else { report("重启仿真失败：飞机未连接"); return }
        guard !telemetry.flying, !simulatorStatus.flying, !simulatorStatus.motorsOn else {
            report("飞机或 Simulator 已在空中，禁止重启仿真")
            return
        }
        guard !simulatorChanging else {
            showBanner("DJI 内置仿真器正在切换，请稍候", kind: .warning)
            return
        }
        if surveyControlActive { surveyRuntime.abort("重启仿真器") }
        if vlnArmed { normalStop("重启 DJI 内置仿真器") }
        takeoffRequestGeneration &+= 1
        takeoffMonitorTask?.cancel()
        takeoffMonitorTask = nil
        takeoffCommandPending = false
        simulatorManuallyDisabled = false
        invalidateHILSimulatorActivation()
        simulatorChanging = true
        explicitSimulatorStopInProgress = true
        simulatorStatus.message = "正在重启 DJI 内置仿真器…"
        log.append("仿真", simulatorStatus.message)
        showBanner(simulatorStatus.message)

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.simulatorChanging = false
                self.explicitSimulatorStopInProgress = false
                if self.hil.status.running, !self.appInBackground,
                   !self.simulatorManuallyDisabled, !self.simulatorRawStateFresh() {
                    self.ensureHILSimulatorActive()
                }
            }
            do {
                if self.simulatorStatus.active {
                    try await self.provider.setSimulator(enabled: false)
                    try? await Task.sleep(
                        nanoseconds: self.simulatorTakeoffTiming.simulatorOriginRestartDelayNanoseconds
                    )
                }
                try await self.provider.setSimulator(enabled: true)
                let ready = await self.waitFor(
                    { self.simulatorStatus.active && self.simulatorStatus.stateReceived },
                    attempts: 100,
                    intervalNanoseconds: 100_000_000
                )
                guard ready else {
                    self.report("仿真器已重启，但 10 秒内未收到 DJI RAW 状态；请重启 OpenFly Go")
                    return
                }
                self.simulatorStatus.message = "DJI 内置仿真已重启，等待起飞"
                self.log.append("仿真", self.simulatorStatus.message)
                self.showBanner("仿真器已重启，可以长按起飞", kind: .success)
            } catch {
                self.report("重启 DJI 内置仿真失败：\(self.describeDJIError(error))；请重启 OpenFly Go")
            }
        }
    }

    private func submitTakeoff(generation: UInt64, attempt: Int = 1) {
        guard generation == takeoffRequestGeneration, takeoffCommandPending else { return }
        if let flightStateFreshnessFailure = takeoffFlightStateFreshnessFailure() {
            failTakeoff(flightStateFreshnessFailure, generation: generation)
            return
        }
        takeoffStatus = "正在尝试起飞…"
        log.append("起飞", "正在向 \(provider.providerName) 提交起飞请求 · attempt=\(attempt)")
        showBanner(attempt == 1 ? "正在尝试起飞…" : "起飞被拒绝，正在重试 \(attempt)/3…")
        takeoffMonitorTask?.cancel()
        takeoffMonitorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled,
                  generation == self.takeoffRequestGeneration,
                  self.takeoffCommandPending,
                  self.takeoffStatus == "正在尝试起飞…" else { return }
            self.failTakeoff("等待 DJI SDK 起飞回调超时", generation: generation)
        }
        provider.takeOff { [weak self] error in
            guard let self,
                  generation == self.takeoffRequestGeneration,
                  self.takeoffCommandPending else { return }
            self.takeoffMonitorTask?.cancel()
            self.takeoffMonitorTask = nil
            if let error {
                let reason = self.describeDJIError(error)
                let simulatorFlow = self.hil.status.running || self.simulatorStatus.active
                self.log.append("起飞", "DJI 起飞回调拒绝 · attempt=\(attempt) · \(reason)")
                if simulatorFlow, self.isSimulatorCommandPoison(error) {
                    self.startSimulatorMotorFallback(generation: generation, nativeError: reason)
                } else if simulatorFlow, attempt < 3 {
                    self.takeoffStatus = "起飞被拒绝，1 秒后重试 \(attempt + 1)/3…"
                    self.showBanner(self.takeoffStatus, kind: .warning)
                    self.takeoffMonitorTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        guard let self, !Task.isCancelled,
                              generation == self.takeoffRequestGeneration,
                              self.takeoffCommandPending else { return }
                        await self.prepareSimulatorTakeoff(
                            generation: generation,
                            commandAttempt: attempt + 1
                        )
                    }
                } else if simulatorFlow {
                    self.failTakeoff("连续 \(attempt) 次被 DJI 拒绝：\(reason)", generation: generation)
                } else {
                    self.failTakeoff(reason, generation: generation)
                }
                return
            }
            if self.isAirborneForControl {
                self.completeTakeoff(generation: generation)
                return
            }
            self.takeoffStatus = "DJI 已接受，等待离地…"
            self.log.append("起飞", "DJI SDK 已接受起飞请求；等待电机与飞行状态")
            self.showBanner("DJI 已接受起飞请求，等待离地…")
            self.takeoffMonitorTask = Task { [weak self] in
                guard let self else { return }
                let airborne = await self.waitFor(
                    { self.isAirborneForControl },
                    attempts: self.simulatorTakeoffTiming.airbornePollAttempts,
                    intervalNanoseconds: self.simulatorTakeoffTiming.airbornePollIntervalNanoseconds
                )
                guard !Task.isCancelled, generation == self.takeoffRequestGeneration else { return }
                if airborne {
                    self.completeTakeoff(generation: generation)
                } else {
                    let rebound = self.provider.refreshSimulatorStateCallback()
                    self.log.append("起飞", "DJI 已接受但未离地；仅刷新 Simulator delegate=\(rebound)，不执行电机回退或 stop/start")
                    let observedSeconds = Double(self.simulatorTakeoffTiming.airbornePollAttempts)
                        * Double(self.simulatorTakeoffTiming.airbornePollIntervalNanoseconds)
                        / 1_000_000_000
                    let reason = self.simulatorStatus.active
                        ? String(format: "DJI 已接受请求，但仿真状态 %.1f 秒内未进入飞行；已刷新 delegate 并停止，本次不会自动重试或电机回退", observedSeconds)
                        : String(format: "DJI 已接受请求，但 %.1f 秒内未检测到离地；已停止且不会自动重试", observedSeconds)
                    self.failTakeoff(reason, generation: generation)
                }
            }
        }
    }

    private func startSimulatorMotorFallback(generation: UInt64, nativeError: String) {
        if let flightStateFreshnessFailure = takeoffFlightStateFreshnessFailure() {
            failTakeoff(flightStateFreshnessFailure, generation: generation)
            return
        }
        guard generation == takeoffRequestGeneration, takeoffCommandPending,
              simulatorRawStateFresh() else {
            failTakeoff("DJI 原生起飞失败且 SimulatorState 已失效：\(nativeError)", generation: generation)
            return
        }
        takeoffStatus = "DJI 原生起飞不可用，正在用仿真电机路径起飞…"
        log.append("起飞", "原生起飞返回 code=255/Undefined Error；启用仿真电机回退")
        showBanner(takeoffStatus, kind: .warning)
        provider.turnOnMotors { [weak self] error in
            guard let self, generation == self.takeoffRequestGeneration,
                  self.takeoffCommandPending else { return }
            if let error, !self.simulatorStatus.motorsOn {
                self.failTakeoff(
                    "DJI 原生起飞和电机启动均失败：\(self.describeDJIError(error))",
                    generation: generation
                )
                return
            }
            self.provider.setVirtualStick(enabled: true)
            self.takeoffMonitorTask = Task { [weak self] in
                guard let self else { return }
                let enabled = await self.waitFor(
                    { self.telemetry.virtualStickActive },
                    attempts: 30,
                    intervalNanoseconds: 50_000_000
                )
                guard !Task.isCancelled, generation == self.takeoffRequestGeneration,
                      self.takeoffCommandPending else { return }
                guard enabled else {
                    self.failTakeoff("电机已启动，但临时 Virtual Stick 启用失败", generation: generation)
                    return
                }
                await self.driveSimulatorMotorFallback(generation: generation)
            }
        }
    }

    private func driveSimulatorMotorFallback(generation: UInt64) async {
        for _ in 0..<200 {
            guard !Task.isCancelled, generation == takeoffRequestGeneration,
                  takeoffCommandPending else {
                provider.send(.zero)
                provider.setVirtualStick(enabled: false)
                return
            }
            guard simulatorRawStateFresh() else {
                provider.send(.zero)
                provider.setVirtualStick(enabled: false)
                failTakeoff("电机路径已停止：SimulatorState 超过 500 ms", generation: generation)
                return
            }
            let simulatorHeight = max(telemetry.altitude, -simulatorStatus.positionZ)
            if simulatorStatus.flying && simulatorHeight >= 0.8 {
                provider.send(.zero)
                provider.setVirtualStick(enabled: false)
                let released = await waitFor(
                    { !self.telemetry.virtualStickActive },
                    attempts: 30,
                    intervalNanoseconds: 50_000_000
                )
                guard released else {
                    failTakeoff("已起飞，但 Virtual Stick 释放失败", generation: generation)
                    return
                }
                completeTakeoff(generation: generation)
                return
            }
            provider.send(VelocityCommand(forward: 0, right: 0, up: 1.0, yawRate: 0))
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        provider.send(.zero)
        provider.setVirtualStick(enabled: false)
        failTakeoff("电机路径 8 秒内未确认起飞", generation: generation)
    }

    private func isSimulatorCommandPoison(_ error: Error) -> Bool {
        let nsError = error as NSError
        let description = describeDJIError(error)
        return nsError.code == 255 || description.contains("code=255")
            || description.localizedCaseInsensitiveContains("Undefined Error")
    }

    private func takeoffFlightStateFreshnessFailure(now: Date = Date()) -> String? {
        let age = now.timeIntervalSince(telemetry.flightStateTimestamp)
        if age < 0 {
            return String(format: "飞控状态时间异常（领先 %.2f 秒），禁止起飞", -age)
        }
        if age > 1.5 {
            return String(format: "飞控状态已过期 %.2f 秒，禁止起飞", age)
        }
        return nil
    }

    private func describeDJIError(_ error: Error) -> String {
        let nsError = error as NSError
        let localized = error.localizedDescription
        if localized.contains("code=") || localized.contains("code:") { return localized }
        return "\(localized) (code=\(nsError.code))"
    }

    private func completeTakeoff(generation: UInt64) {
        guard generation == takeoffRequestGeneration else { return }
        takeoffMonitorTask?.cancel()
        takeoffMonitorTask = nil
        takeoffCommandPending = false
        takeoffStatus = "起飞成功"
        log.append("起飞", "已检测到飞行状态，起飞成功")
        showBanner("起飞成功", kind: .success)
        updateControl()
    }

    private func failTakeoff(_ reason: String, generation: UInt64? = nil) {
        if let generation, generation != takeoffRequestGeneration { return }
        takeoffMonitorTask?.cancel()
        takeoffMonitorTask = nil
        takeoffCommandPending = false
        let actionableReason = simulatorRestartGuidanceIfNeeded(reason)
        takeoffStatus = "起飞失败：\(actionableReason)"
        report(takeoffStatus)
        if simulatorStatus.active || simulatorChanging {
            presentSimulatorTakeoffRecovery(reason: actionableReason)
        }
        updateControl()
    }

    private func simulatorRestartGuidanceIfNeeded(_ reason: String) -> String {
        guard (simulatorStatus.active || simulatorChanging),
              !simulatorStatus.motorsOn, !simulatorStatus.flying,
              !reason.contains("重启飞机") else { return reason }
        let unlockFailure = ["解锁", "电机", "起飞", "拒绝", "未进入飞行"]
            .contains { reason.localizedCaseInsensitiveContains($0) }
        let opaqueDJIDiagnostic = telemetry.warnings.contains {
            $0.title == "DJI 设备状态异常"
        }
        guard unlockFailure || opaqueDJIDiagnostic else { return reason }
        return reason + "；" + AppLocalization.string(
            "若同时出现“DJI 设备状态异常”且仿真无法解锁，请关闭并重启飞机（不是只重启 App），待遥控器重新连接后再试。"
        )
    }

    private func cancelTakeoffMonitoring(reason: String) {
        guard takeoffCommandPending else { return }
        takeoffRequestGeneration &+= 1
        takeoffMonitorTask?.cancel()
        takeoffMonitorTask = nil
        takeoffCommandPending = false
        takeoffStatus = "起飞已取消：\(reason)"
        log.append("起飞", takeoffStatus)
        showBanner(takeoffStatus, kind: .warning)
    }

    private func report(_ message: String) {
        log.append("错误", message)
        showBanner(message, kind: .error, durationNanoseconds: 4_500_000_000)
    }

    func showBanner(
        _ message: String,
        kind: TransientBanner.Kind = .info,
        durationNanoseconds: UInt64 = 2_800_000_000
    ) {
        let banner = TransientBanner(message: message, kind: kind)
        transientBannerTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { transientBanner = banner }
        transientBannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            guard let self, !Task.isCancelled, self.transientBanner?.id == banner.id else { return }
            withAnimation(.easeOut(duration: 0.18)) { self.transientBanner = nil }
        }
    }
    private func f(_ value: Double) -> String { String(format: "%.2f", value) }

    private func runSimulatorDemo() async {
        loadModel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        takeOff(); toggleVLNControl(); inferOnce()
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func loadModelNow() async -> Bool {
        guard OpenFlyBuildFeatures.vlnInference else {
            report("当前发布版本未启用模型推理")
            return false
        }
        if modelLoaded { return true }
        log.append("模型", "开始加载 \(inference.engineName)")
        do {
            try await inference.load()
            modelLoaded = true
            log.append("模型", "加载完成")
            for item in await inference.diagnostics().sorted(by: { $0.key < $1.key }) {
                log.append("诊断", "\(item.key)：\(item.value)")
            }
            return true
        } catch {
            report("模型加载失败：\(error.localizedDescription)")
            return false
        }
    }

    private func runDJISimulatorValidation() async {
        log.append("仿真", "开始 DJI 内置仿真闭环自检；仅在 simulator active 后允许起飞")
        guard await waitFor({ self.telemetry.connected && self.simulatorStatus.available }, attempts: 80) else {
            report("DJI 内置仿真自检失败：飞机未连接或 simulator 不可用")
            return
        }
        if simulatorStatus.active && (simulatorStatus.flying || simulatorStatus.motorsOn) {
            log.append("仿真", "检测到上轮仿真仍在飞行，先执行归零与降落")
            await cleanupDJISimulatorValidation()
            guard !simulatorStatus.flying, !simulatorStatus.motorsOn else { return }
        }
        do {
            try await ensureSimulatorTakeoff()

            let validationMode: PositionClosureMode = ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_CONTROL_MODE"] == "gps"
                ? .gps : .velocityEstimate
            selectPositionClosureMode(validationMode)
            guard await loadModelNow() else { throw FlightActionError.unavailable("模型加载失败") }
            toggleVLNControl()
            guard vlnArmed else { throw FlightActionError.unavailable("仿真 Virtual Stick 未武装") }
            guard await waitFor({ self.telemetry.virtualStickActive }, attempts: 40) else {
                throw FlightActionError.unavailable("Virtual Stick 控制权确认超时")
            }

            let startX = simulatorStatus.positionX
            let startY = simulatorStatus.positionY
            let startZ = simulatorStatus.positionZ
            lastPositionLoopDiagnosticAt = .distantPast
            if let forcedZText = ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_FORCED_Z"],
               let forcedZ = Double(forcedZText) {
                let action = RelativeAction(
                    forwardMeters: 0,
                    rightMeters: 0,
                    upMeters: forcedZ,
                    yawDegrees: 0,
                    confidence: 1,
                    stopScore: 0,
                    reason: "DJI 仿真强制垂直动作"
                )
                latestAction = action
                log.append("仿真", "执行强制垂直相对目标 z=\(f(forcedZ))m")
                let step = try positionLoop.start(
                    action: action,
                    telemetry: telemetry,
                    mode: validationMode,
                    maximumHorizontalSpeed: maxVLNHorizontalSpeed
                )
                applyPositionStep(step)
            } else {
                log.append("仿真", "执行当前 Prompt 单步模型输出")
                await performInference()
                guard latestAction != nil else { throw FlightActionError.unavailable("模型没有返回动作") }
            }
            _ = await waitFor({ !self.positionLoop.isActive }, attempts: 90, intervalNanoseconds: 100_000_000)
            let deltaX = simulatorStatus.positionX - startX
            let deltaY = simulatorStatus.positionY - startY
            let deltaZ = simulatorStatus.positionZ - startZ
            let moved = hypot(deltaX, deltaY)
            log.append("仿真", "模型闭环结束：X \(f(deltaX)) Y \(f(deltaY)) Z \(f(deltaZ)) · 平面 \(f(moved))m · \(latestDecision.reason)")
        } catch {
            report("DJI 内置仿真自检失败：\(error.localizedDescription)")
        }
        await cleanupDJISimulatorValidation()
    }

    private func runDJISimulatorFunctionMatrix() async {
        var passed = 0
        var failed = 0
        func result(_ name: String, _ ok: Bool, _ detail: String = "") {
            ok ? (passed += 1) : (failed += 1)
            log.append("按钮测试", "\(ok ? "PASS" : "FAIL") · \(name)\(detail.isEmpty ? "" : " · \(detail)")")
        }

        log.append("按钮测试", "开始 DJI 内置仿真功能矩阵；飞行控制仅作用于内置仿真")
        guard await waitFor({ self.telemetry.connected && self.simulatorStatus.available }, attempts: 80) else {
            result("连接与仿真器可用", false, "飞机未连接或 simulator 不可用")
            return
        }
        result("连接与仿真器可用", true)

        if simulatorStatus.active && (simulatorStatus.flying || simulatorStatus.motorsOn) {
            await cleanupDJISimulatorValidation()
            guard !simulatorStatus.flying, !simulatorStatus.motorsOn else {
                result("清理上轮仿真飞行", false, "飞机仍在飞行")
                return
            }
        }

        do {
            try await provider.setSimulator(enabled: true)
            let simulatorReady = await waitFor({ self.simulatorStatus.active && self.simulatorStatus.stateReceived }, attempts: 50)
            result("内置仿真开关", simulatorReady, simulatorStatus.message)
            guard simulatorReady else { throw FlightActionError.unavailable("simulator 未返回状态") }

            await validateCameraButtons(result: result)

            try await ensureSimulatorTakeoff()
            result("长按起飞对应飞控动作", simulatorStatus.flying && telemetry.flying)

            let modelOK = await loadModelNow()
            result("加载模型", modelOK)
            guard modelOK else { throw FlightActionError.unavailable("模型加载失败") }

            selectPositionClosureMode(.velocityEstimate)
            result("速度积分闭环选项", positionClosureMode == .velocityEstimate)

            toggleVLNControl()
            let virtualStickAcquired = await waitFor({ self.telemetry.virtualStickActive }, attempts: 40)
            let armed = vlnArmed && virtualStickAcquired
            result("VLN 启用", armed)
            guard armed else { throw FlightActionError.unavailable("Virtual Stick 未取得") }

            normalStop("功能矩阵测试普通停止")
            let virtualStickReleased = await waitFor({ !self.telemetry.virtualStickActive }, attempts: 40)
            let normallyStopped = !vlnArmed && virtualStickReleased
            result("VLN 普通停止", normallyStopped)

            toggleVLNControl()
            let virtualStickReacquired = await waitFor({ self.telemetry.virtualStickActive }, attempts: 40)
            let rearmed = vlnArmed && virtualStickReacquired
            result("停止后重新启用", rearmed)
            emergencyStop()
            let emergencyVirtualStickReleased = await waitFor({ !self.telemetry.virtualStickActive }, attempts: 40)
            let emergencyReleased = emergencyStopped && !vlnArmed && emergencyVirtualStickReleased
            result("急停锁定并释放控制", emergencyReleased)

            resetEmergency()
            let resetOK = !emergencyStopped && !vlnArmed && latestDecision.command.isZero
            result("急停复位不自动重启", resetOK)

            toggleVLNControl()
            let postResetVirtualStickAcquired = await waitFor({ self.telemetry.virtualStickActive }, attempts: 40)
            guard vlnArmed && postResetVirtualStickAcquired else {
                throw FlightActionError.unavailable("复位后 Virtual Stick 未重新取得")
            }
            let startX = simulatorStatus.positionX
            let startY = simulatorStatus.positionY
            await performInference()
            let actionReturned = latestAction != nil
            _ = await waitFor({ !self.positionLoop.isActive }, attempts: 120, intervalNanoseconds: 100_000_000)
            let moved = hypot(simulatorStatus.positionX - startX, simulatorStatus.positionY - startY)
            result("预设 Prompt 单次推理", actionReturned, latestAction.map { "target=\(f(hypot($0.forwardMeters, $0.rightMeters)))m" } ?? "无输出")
            result("模型位置闭环与悬停", actionReturned && moved > 0.20 && !positionLoop.isActive, "实际移动 \(f(moved))m；\(latestDecision.reason)")
            normalStop("位置闭环测试结束")
            _ = await waitFor({ !self.telemetry.virtualStickActive }, attempts: 40)

            await validateReturnHomeButtons(result: result)
            if !simulatorStatus.flying {
                try await ensureSimulatorTakeoff()
                result("返航测试后再次起飞", simulatorStatus.flying)
            }
            await validateLandingButtons(result: result)
        } catch {
            result("功能矩阵中断", false, error.localizedDescription)
        }

        await cleanupDJISimulatorValidation()
        log.append("按钮测试", "完成：PASS \(passed) · FAIL \(failed)；飞机已降落，simulator 保持开启")
    }

    private func validateCameraButtons(result: (String, Bool, String) -> Void) async {
        let photoStart = Date()
        takePhoto()
        let photo = await waitForOperation("拍照", since: photoStart)
        result("拍照", photo == true, operationDetail(photo))

        // A successful Mini 2 photo callback can arrive before SD-card writing has
        // started. Give the camera time to finish the complete write cycle before
        // switching its flat mode to video.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        _ = await waitFor({ !self.camera.message.contains("写入") }, attempts: 30)
        let recordStart = Date()
        toggleRecording()
        let started = await waitForOperation("开始录像", since: recordStart)
        let recordingObserved = await waitFor({ self.camera.recording }, attempts: 30)
        result("开始录像", started == true && recordingObserved, operationDetail(started))

        if camera.recording {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let stopStart = Date()
            toggleRecording()
            let stopped = await waitForOperation("停止录像", since: stopStart)
            let idleObserved = await waitFor({ !self.camera.recording }, attempts: 30)
            result("停止录像", stopped == true && idleObserved, operationDetail(stopped))
        } else {
            result("停止录像", false, "录像未启动")
        }
    }

    private func validateReturnHomeButtons(result: (String, Bool, String) -> Void) async {
        let start = Date()
        requestReturnHome()
        let confirmationShown = alert?.title == "开始返航"
        alert?.confirm()
        alert = nil
        let started = await waitForOperation("返航", since: start)
        result("返航二次确认与提交", confirmationShown && started == true, operationDetail(started))

        if started == true {
            let cancelStart = Date()
            cancelReturnHome()
            let cancelled = await waitForOperation("取消返航", since: cancelStart)
            result("取消返航", cancelled == true, operationDetail(cancelled))
            _ = await waitFor({ self.telemetry.mode != .returningHome }, attempts: 30)
        } else {
            result("取消返航", false, "返航未进入执行态")
        }
    }

    private func validateLandingButtons(result: (String, Bool, String) -> Void) async {
        if telemetry.altitude < 3.0 {
            provider.setVirtualStick(enabled: true)
            guard await waitFor({ self.telemetry.virtualStickActive }, attempts: 40) else {
                result("降落测试高度准备", false, "Virtual Stick 未取得")
                return
            }
            provider.send(VelocityCommand(forward: 0, right: 0, up: 0.8, yawRate: 0))
            let climbed = await waitFor({ self.telemetry.altitude >= 3.0 }, attempts: 80, intervalNanoseconds: 100_000_000)
            provider.send(.zero)
            provider.setVirtualStick(enabled: false)
            _ = await waitFor({ !self.telemetry.virtualStickActive }, attempts: 40)
            result("降落测试高度准备", climbed, "ALT \(f(telemetry.altitude))m")
        }

        let start = Date()
        requestLanding()
        let confirmationShown = alert?.title == "开始自动降落"
        alert?.confirm()
        alert = nil
        let landingObserved = await waitFor({ self.telemetry.mode == .landing }, attempts: 100, intervalNanoseconds: 20_000_000)
        let cancelStart = Date()
        if landingObserved { cancelLanding() }
        let started = await waitForOperation("降落", since: start)
        result("降落二次确认与提交", confirmationShown && started == true, operationDetail(started))

        if started == true && landingObserved {
            let cancelled = await waitForOperation("取消降落", since: cancelStart)
            result("取消降落", cancelled == true, operationDetail(cancelled))
            _ = await waitFor({ self.telemetry.mode != .landing }, attempts: 30)
        } else {
            result("取消降落", false, "降落未进入执行态")
        }
    }

    private func waitForOperation(_ operation: String, since: Date) async -> Bool? {
        for _ in 0..<50 {
            if let event = log.events.last(where: {
                $0.timestamp >= since && ($0.message.hasPrefix("\(operation)指令执行成功") || $0.message.hasPrefix("\(operation)失败"))
            }) {
                return event.kind != "错误"
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func operationDetail(_ result: Bool?) -> String {
        switch result {
        case true: return "DJI SDK 回调成功"
        case false: return "DJI SDK 回调失败"
        case nil: return "等待 DJI SDK 回调超时"
        }
    }

    private func ensureSimulatorTakeoff() async throws {
        try await provider.setSimulator(enabled: true)
        guard await waitFor({ self.simulatorStatus.active && self.simulatorStatus.stateReceived }, attempts: 50) else {
            throw FlightActionError.unavailable("DJI simulator 未返回首个状态")
        }
        log.append("仿真", "simulator active，提交仿真起飞")
        try provider.takeOff()
        if !(await waitFor({ self.simulatorStatus.flying && self.telemetry.flying }, attempts: 30)) {
            log.append("仿真", "首次起飞状态未生效，保持 simulator active 并重试一次")
            try provider.takeOff()
        }
        guard await waitFor({ self.simulatorStatus.flying && self.telemetry.flying }, attempts: 70) else {
            throw FlightActionError.unavailable("仿真起飞超时；Mini 2 若已停止过 simulator，需要重启飞机一次")
        }
    }

    private func cleanupDJISimulatorValidation() async {
        normalStop("DJI 内置仿真自检收尾")
        try? await Task.sleep(nanoseconds: 500_000_000)
        if simulatorStatus.flying {
            do { try provider.land(); log.append("仿真", "已提交仿真降落") }
            catch { report("仿真降落失败：\(error.localizedDescription)") }
            if !(await waitFor({ !self.simulatorStatus.flying && !self.simulatorStatus.motorsOn }, attempts: 30)) {
                log.append("仿真", "仿真仍在 flying，重试一次自动降落")
                do { try provider.land() }
                catch { report("仿真降落重试失败：\(error.localizedDescription)") }
                _ = await waitFor({ !self.simulatorStatus.flying && !self.simulatorStatus.motorsOn }, attempts: 90)
            }
        }
        guard !simulatorStatus.flying, !simulatorStatus.motorsOn else {
            report("仿真飞机仍在飞行，保留 simulator active 供人工处理")
            return
        }
        if (ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_AUTOTEST"] == "1" ||
            ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_FUNCTION_TEST"] == "1"),
           ProcessInfo.processInfo.environment["DEVICE_DJI_SIM_STOP_AFTER_TEST"] != "1" {
            log.append("仿真", "仿真飞机已着陆；保持 simulator active，后续测试无需重启飞机")
            return
        }
        do {
            try await provider.setSimulator(enabled: false)
            log.append("仿真", "内置仿真自检完成并安全退出")
        } catch {
            report("退出 DJI 内置仿真失败：\(error.localizedDescription)")
        }
    }

    private func waitFor(
        _ condition: @escaping @MainActor () -> Bool,
        attempts: Int,
        intervalNanoseconds: UInt64 = 200_000_000
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return condition()
    }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var cancelTitle = "取消"
    var confirmTitle = "确认执行"
    let confirm: () -> Void
}

struct TransientBanner: Identifiable, Equatable {
    enum Kind: Equatable { case info, success, warning, error }

    let id = UUID()
    let message: String
    let kind: Kind
}
