import Foundation

struct SurveyRuntimeSnapshot: Equatable {
    var state: SurveyExecutionState = .idle
    var phase: SurveyExecutionPhase?
    var legIndex = 0
    var legCount = 0
    var waypointIndex = 0
    var message = "未载入航测任务"
    var gateBlocks = Set<SurveyExecutionBlock>()
    var horizontalErrorMeters = 0.0
    var verticalErrorMeters = 0.0
    var lastCommand = VelocityCommand.zero
    var photoCount = 0
    var photoFeedbackSequence = 0
    var photoFeedbackSucceeded = true
    var currentSectionRemainingSeconds = 0.0
    var totalRemainingSeconds = 0.0
    var recoverableMissionName: String?
    var lowBatteryReturnSeconds: Int?
    var missionID: String?
    var currentTarget: SurveyWaypoint?
}

/// Executes survey routes through the existing audited DJI provider. The gate
/// selects DJI Simulator when active; otherwise it requires manual takeoff and
/// stable hover before allowing real-aircraft execution.
@MainActor
final class SurveyRuntimeController: ObservableObject {
    static let controlIntervalSeconds = 0.04
    static let virtualStickReleaseFallbackMillis: Int64 = 1_500
    static let runtimeReadinessGraceMillis: Int64 = 1_500

    @Published private(set) var snapshot = SurveyRuntimeSnapshot()
    /// True only while this runtime is deliberately handing the completed
    /// survey to DJI RTH. A returning-home telemetry sample in this window is
    /// acknowledgement of our own command, not an external intervention.
    var ownsPendingReturnHomeHandoff: Bool { returnHomeHandoffPending }
    /// The in-memory mission owned by a live execution session. UI presentation
    /// may read this value, but must not reconstruct the runtime from disk just
    /// because a planner view was created again.
    var liveMissionForPresentation: SurveyMission? {
        switch snapshot.state {
        case .arming, .running, .paused:
            return mission
        default:
            return nil
        }
    }
    var virtualFrameCaptureEnabled: (() -> Bool)?
    var latestVirtualFrame: (() -> CameraFrame?)?
    var onVirtualFrameCaptured: ((SurveyFrameCaptureRecord) -> Void)?
    var onSurveyFrameSaved: ((SurveyFrameCaptureRecord, SurveyCaptureView) -> Void)?

    private let provider: DJIFlightProvider
    private let log: EventLog
    private var telemetry = FlightTelemetry.disconnectedShanghai
    private var simulator = FlightSimulatorStatus()
    private var camera = CameraStatus(connected: false, sdInserted: false,
                                      photosRemaining: 0, message: "等待相机")
    private var mission: SurveyMission?
    private var machine: SurveyExecutionStateMachine?
    private var capture = SurveyDistanceCaptureController()
    private var timer: Timer?
    private var waypointDeadlineElapsedMillis: Int64 = 0
    private var legStartedElapsedMillis: Int64 = 0
    private var bestWaypointHorizontalErrorMeters = Double.infinity
    private var lastWaypointProgressElapsedMillis: Int64 = 0
    private var requestedGimbalPitch = Double.nan
    private var gimbalUnsettledSince: Int64 = 0
    private var lastGimbalCommand: Int64 = 0
    private var gimbalCommandAcceptedElapsedMillis: Int64 = 0
    private var gimbalVerificationStartedElapsedMillis: Int64 = 0
    private var gimbalCommandGeneration: Int64 = 0
    private var gimbalCommandInFlight = false
    private var gimbalAttempts = 0
    private var gimbalMechanicalLimitActive = false
    private var pendingGimbalCaptureStartWaypointIndex: Int?
    private var photoBusyUntil: Int64 = 0
    private var photoInFlight = false
    private var photoRequestGeneration: Int64 = 0
    private var photoRequestStartedElapsedMillis: Int64 = 0
    private var photoVirtualFrameStartSequence: Int?
    private var photoReason = ""
    private var postTriggerFrameCapturesPending = 0
    private var pointCapturePendingLegIndex: Int?
    private var pointCaptureCompletedLegIndex: Int?
    private var capturePoseWaypointIndex: Int?
    private var capturePoseStableSinceElapsedMillis: Int64 = 0
    private var capturePoseVerificationStartedElapsedMillis: Int64 = 0
    private var capturePoseTimeoutHandled = false
    private var armingDeadline: Int64 = 0
    private var autoTakeoffPending = false
    private var autoTakeoffDeadlineElapsedMillis: Int64 = 0
    private var autoTakeoffStableSinceElapsedMillis: Int64 = 0
    private var lowBatteryReturnTimer: Timer?
    private var lowBatteryReturnDeadlineElapsedMillis: Int64 = 0
    private var lowBatteryReturnIssued = false
    private var lowBatteryReturnCommandSent = false
    private var lowBatteryVirtualStickReleaseTimer: Timer?
    private var lowBatteryVirtualStickReleaseDeadlineElapsedMillis: Int64 = 0
    private var returnHomeHandoffGeneration: Int64 = 0
    private var returnHomeHandoffPending = false
    private var returnHomeHandoffCommandSent = false
    private var returnHomeHandoffReleaseDeadlineElapsedMillis: Int64 = 0
    private var controlStartedElapsedMillis: Int64 = 0
    private var tickCount: Int64 = 0
    private var flightStateCount: Int64 = 0
    private var lastFlightStateTimestamp = Date.distantPast
    private var resumingPausedMission = false
    private var runtimeReadinessFaultSinceElapsedMillis: Int64 = 0
    private var runtimeReadinessFaultSignature = Set<SurveyExecutionBlock>()

    private let missionKey = "openfly.survey.active-mission.v1"
    private let checkpointKey = "openfly.survey.execution-checkpoint.v2"

    init(provider: DJIFlightProvider, log: EventLog) {
        self.provider = provider
        self.log = log
        restoreCheckpointMetadata()
    }

    deinit {
        timer?.invalidate()
        lowBatteryReturnTimer?.invalidate()
        lowBatteryVirtualStickReleaseTimer?.invalidate()
    }

    func updateTelemetry(_ value: FlightTelemetry) {
        telemetry = value
        if value.flightStateTimestamp != lastFlightStateTimestamp {
            lastFlightStateTimestamp = value.flightStateTimestamp
            flightStateCount += 1
        }
        if value.mode == .emergency,
           snapshot.state == .arming || snapshot.state == .running {
            pause(reason: "DJI 飞控已进入保护状态")
        }
        monitorLowBatteryReturn()
        advanceLowBatteryVirtualStickRelease()
    }

    func updateSimulator(_ value: FlightSimulatorStatus) { simulator = value }
    func updateCamera(_ value: CameraStatus) { camera = value }

    func preflight(_ mission: SurveyMission) -> SurveyExecutionGateResult {
        let gate = gate(mission: mission, requireVirtualStick: false, preflight: true)
        snapshot.gateBlocks = gate.blocks
        snapshot.message = gate.allowed
            ? String(format: "预检通过 · 距起点 %.1f m · %@ · 未申请控制权",
                     gate.startDistanceMeters, simulator.active ? "SIMULATOR" : "REAL · 手动起飞")
            : "预检阻止：\(blockText(gate.blocks))"
        return gate
    }

    func startSimulator(_ value: SurveyMission, anotherControllerActive: Bool) {
        guard !anotherControllerActive else {
            snapshot.message = "启动阻止：VLN 或其他控制器尚未释放"
            return
        }
        guard snapshot.state == .idle || snapshot.state == .completed || snapshot.state == .aborted else {
            snapshot.message = "任务已处于 \(snapshot.state.rawValue)"
            return
        }
        let automaticTakeoff = value.constraints.takeoffMode == .autoSimulatorOnly
            && simulator.active && !simulator.flying
        if value.constraints.takeoffMode == .autoSimulatorOnly && !simulator.active {
            snapshot.message = "启动阻止：任务自动起飞仅允许 DJI Simulator；真机必须手动起飞"
            return
        }
        let armGate = gate(mission: value, requireVirtualStick: false, preflight: true,
                           allowNotFlying: automaticTakeoff,
                           allowGroundedPositionUnavailable: automaticTakeoff)
        guard armGate.allowed else {
            snapshot.state = .aborted
            snapshot.gateBlocks = armGate.blocks
            snapshot.message = "启动阻止：\(blockText(armGate.blocks))"
            log.append("SURVEY", snapshot.message + " · NO_CONTROL")
            return
        }
        do {
            try capture.configure(mode: value.constraints.captureTriggerMode,
                                  timedCaptureIntervalSeconds: value.constraints.timedCaptureIntervalSeconds)
        } catch {
            snapshot.message = "拍照策略无效：\(error.localizedDescription)"
            return
        }
        mission = value
        resumingPausedMission = false
        let stateMachine = SurveyExecutionStateMachine(
            mission: value, currentPoint: currentPoint(), returnPoint: surveyReturnPoint()
        )
        machine = stateMachine
        _ = stateMachine.requestArm(armGate)
        resetRuntimeTracking()
        snapshot = .init(state: .arming, phase: stateMachine.currentPhase,
                         legIndex: 0, legCount: stateMachine.executionLegCount,
                         waypointIndex: 0,
                         message: automaticTakeoff
                            ? "AUTO TAKEOFF · 正在等待 Simulator 起飞并稳定悬停"
                            : "ARMING · 正在申请 Virtual Stick",
                         gateBlocks: [], recoverableMissionName: value.name,
                         missionID: value.id, currentTarget: stateMachine.currentTarget)
        updateRemainingEstimate(stateMachine)
        persistCheckpoint()
        log.append("SURVEY", "任务申请控制权：\(value.name) · \(simulator.active ? "SIMULATOR" : "REAL") · \(stateMachine.executionLegCount) 段")
        provider.send(.zero)
        if automaticTakeoff {
            autoTakeoffPending = true
            autoTakeoffDeadlineElapsedMillis = elapsedMillis() + 30_000
            autoTakeoffStableSinceElapsedMillis = 0
            provider.takeOff { [weak self] error in
                guard let self, self.autoTakeoffPending, let error else { return }
                self.abort("Simulator 自动起飞失败：\(error.localizedDescription)")
            }
            if snapshot.state == .arming { startTimer() }
        } else {
            beginVirtualStickArming()
        }
    }

    func pause(reason: String = "用户暂停") {
        guard let machine, snapshot.state == .running || snapshot.state == .arming else { return }
        invalidateReturnHomeHandoff()
        autoTakeoffPending = false
        invalidatePhotoRequest()
        resetGimbalVerification()
        _ = machine.pause(reason: reason, recoveryPoint: currentPoint())
        snapshot.state = .paused
        snapshot.message = "PAUSED · \(reason) · 已保存断点"
        stopAndRelease()
        persistCheckpoint()
        log.append("SURVEY", snapshot.message)
    }

    func resume(anotherControllerActive: Bool) {
        guard !anotherControllerActive else { snapshot.message = "恢复阻止：其他控制器尚未释放"; return }
        guard let mission, let machine, machine.status.state == .paused else {
            snapshot.message = "没有可恢复的暂停任务"; return
        }
        // A paused checkpoint is not an authorization token. Battery, RC/GPS,
        // Home, DJI height/radius limits and terrain evidence may all have
        // changed while the app or aircraft was away, so resume re-runs the
        // same fail-closed preflight used for a fresh real-flight start.
        let armGate = gate(mission: mission, requireVirtualStick: false, preflight: true)
        guard armGate.allowed else {
            snapshot.gateBlocks = armGate.blocks
            snapshot.message = "恢复阻止：\(blockText(armGate.blocks))"
            return
        }
        armingDeadline = elapsedMillis() + 8_000
        resumingPausedMission = true
        snapshot.state = .arming
        snapshot.message = "RESUMING · 正在重新申请 Virtual Stick"
        provider.send(.zero)
        provider.setVirtualStick(enabled: true)
        startTimer()
    }

    func abort(_ reason: String, clearCheckpoint: Bool = true) {
        // Kept for compatibility with callers that used `abort(..., false)` to
        // mean a recoverable external stop. Recoverable interruptions remain a
        // PAUSED checkpoint; terminal ABORTED states are never persisted.
        if !clearCheckpoint {
            pause(reason: reason)
            return
        }
        autoTakeoffPending = false
        invalidateReturnHomeHandoff()
        cancelLowBatteryReturn("任务已终止")
        if let machine, machine.status.state != .completed { _ = machine.abort(reason: reason) }
        snapshot.state = .aborted
        snapshot.message = "ABORTED · \(reason)"
        snapshot.lastCommand = .zero
        pendingGimbalCaptureStartWaypointIndex = nil
        gimbalMechanicalLimitActive = false
        resetGimbalVerification()
        capture.reset()
        stopAndRelease()
        clearPersistedCheckpoint()
        log.append("SURVEY", snapshot.message + " · zero velocity · VS released")
    }

    func manualTakeover() {
        if snapshot.state == .arming || snapshot.state == .running || snapshot.state == .paused {
            pause(reason: "检测到人工摇杆接管")
        }
    }

    func appEnteredBackground() {
        if snapshot.state == .arming || snapshot.state == .running {
            pause(reason: "App 进入后台")
        }
    }

    func restorePersistedMission() -> SurveyMission? {
        // Reopening the map constructs a fresh planner view, but that is not a
        // process restart. Never replace an already-live runtime with the
        // persisted recovery snapshot: it would turn RUNNING into PAUSED merely
        // because the pilot switched camera -> map.
        if snapshot.state == .arming || snapshot.state == .running || snapshot.state == .paused {
            return mission
        }
        guard let raw = UserDefaults.standard.string(forKey: missionKey),
              let checkpointRaw = UserDefaults.standard.string(forKey: checkpointKey) else { return nil }
        do {
            let value = try SurveyMissionJSON.decode(raw)
            let checkpoint = try SurveyExecutionCheckpointJSON.decode(checkpointRaw)
            guard checkpoint.missionID == value.id,
                  SurveyRuntimeCheckpointPolicy.canRestore(checkpoint.state),
                  value.waypoints.indices.contains(checkpoint.waypointIndex) else {
                throw SurveyValidationError.invalid("checkpoint does not match the mission")
            }
            let stateMachine = SurveyExecutionStateMachine(
                mission: value, currentPoint: currentPoint(), returnPoint: surveyReturnPoint()
            )
            let target = value.waypoints[checkpoint.waypointIndex]
            let recovered = SurveyCheckpointRecoveryPolicy.position(
                waypointIndex: checkpoint.waypointIndex,
                executionLegIndex: checkpoint.executionLegIndex,
                state: checkpoint.state, phase: checkpoint.phase,
                targetCaptureAction: target.captureAction,
                hasRecoveryPoint: checkpoint.recoveryPoint != nil
            )
            _ = try stateMachine.restorePaused(
                waypointIndex: recovered.waypointIndex,
                legIndex: recovered.executionLegIndex,
                recoveryPoint: checkpoint.recoveryPoint
            )
            let captureRecovery = try SurveyCaptureCheckpointRecoveryPolicy.decide(
                mission: value, checkpoint: checkpoint, basePosition: recovered,
                baseTargetPassIndex: stateMachine.currentTarget.passIndex,
                baseMissionWaypointIndex: stateMachine.currentMissionWaypointIndex
            )
            if captureRecovery.rewoundToStripStart {
                _ = try stateMachine.restorePaused(
                    waypointIndex: captureRecovery.waypointIndex,
                    legIndex: captureRecovery.executionLegIndex,
                    recoveryPoint: captureRecovery.recoveryPoint
                )
            }
            mission = value; machine = stateMachine
            try restoreCaptureState(
                mission: value, recovery: captureRecovery
            )
            snapshot.state = .paused
            snapshot.phase = stateMachine.currentPhase
            snapshot.legIndex = stateMachine.executionLegIndex
            snapshot.legCount = stateMachine.executionLegCount
            snapshot.waypointIndex = captureRecovery.waypointIndex
            snapshot.message = AppLocalization.string(
                captureRecovery.rewoundToStripStart
                    ? "已恢复断点并回退到航带起点；需手动点击继续"
                    : "已恢复断点，保持暂停；需手动点击继续"
            )
            snapshot.recoverableMissionName = value.name
            snapshot.missionID = value.id
            snapshot.currentTarget = stateMachine.currentTarget
            updateRemainingEstimate(stateMachine)
            persistCheckpoint()
            return value
        } catch {
            snapshot.message = "断点恢复失败：\(error.localizedDescription)"
            clearPersistedCheckpoint()
            return nil
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let value = Timer(timeInterval: Self.controlIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }

    private func tick() {
        guard let mission, let machine else { return }
        switch snapshot.state {
        case .arming:
            if autoTakeoffPending {
                advanceAutomaticTakeoff()
                return
            }
            if elapsedMillis() >= armingDeadline {
                pause(reason: "Virtual Stick 获取超时")
                return
            }
            guard telemetry.virtualStickActive else { return }
            // Revalidate again after DJI actually grants VS; acquiring control
            // can take several seconds and readiness may degrade meanwhile.
            let runGate = gate(mission: mission, requireVirtualStick: true,
                               preflight: true)
            snapshot.gateBlocks = runGate.blocks
            let status = machine.status.state == .paused
                ? machine.resume(runGate, currentPoint: currentPoint()) : machine.onVirtualStickReady(runGate)
            guard status.state == .running else {
                _ = machine.pause(reason: status.reason ?? "Virtual Stick 就绪后复检失败",
                                  recoveryPoint: currentPoint())
                snapshot.state = .paused
                snapshot.message = "PAUSED · \(status.reason ?? "Virtual Stick 就绪后复检失败")"
                stopAndRelease()
                persistCheckpoint()
                return
            }
            snapshot.state = .running
            snapshot.gateBlocks = []
            resumingPausedMission = false
            snapshot.phase = machine.currentPhase
            snapshot.legIndex = machine.executionLegIndex
            snapshot.waypointIndex = machine.status.waypointIndex
            snapshot.currentTarget = machine.currentTarget
            snapshot.message = "RUNNING · \(phaseLabel(machine.currentPhase))"
            controlStartedElapsedMillis = elapsedMillis()
            tickCount = 0; flightStateCount = 0
            setWaypointDeadline()
            persistCheckpoint()
        case .running:
            tickCount += 1
            if returnHomeHandoffPending {
                advanceReturnHomeHandoff()
                return
            }
            runControlTick(mission: mission, machine: machine)
        default:
            break
        }
    }

    private func runControlTick(mission: SurveyMission, machine: SurveyExecutionStateMachine) {
        let now = elapsedMillis()
        if mission.constraints.completionAction == .returnToHome,
           machine.currentPhase == .returnHome {
            beginReturnHomeHandoff(machine: machine)
            return
        }
        if photoInFlight && now - photoRequestStartedElapsedMillis >= 8_000 {
            publishPhotoFeedback(success: false)
            invalidatePhotoRequest()
            pause(reason: "拍摄指令 8 秒无回调")
            return
        }
        pollVirtualFrameCapture(mission: mission, machine: machine)
        let runtimeGate = stabilizedRuntimeGate(
            gate(mission: mission, requireVirtualStick: true, preflight: false), now: now
        )
        // Preserve the structured runtime fault on the paused snapshot so the
        // UI and persisted diagnostics can explain why control was released.
        snapshot.gateBlocks = runtimeGate.blocks
        let failsafe = SurveyExecutionWatchdog.inspect(
            state: .running, gate: runtimeGate, trustedDJITelemetry: telemetry.connected,
            nowElapsedMillis: now, waypointDeadlineElapsedMillis: waypointDeadlineElapsedMillis
        )
        switch failsafe.action {
        case .continue: break
        case .pauseZeroAndRelease:
            pause(reason: failsafe.reason ?? "外部介入，航测已自动暂停")
            return
        case .abortZeroAndRelease:
            abort(failsafe.reason ?? "运行安全门失败")
            return
        }

        let current = currentPoint()
        let target = machine.currentTarget
        if !requestedGimbalPitch.isFinite || abs(requestedGimbalPitch - target.gimbalPitchDegrees) > 0.1 {
            requestedGimbalPitch = target.gimbalPitchDegrees
            gimbalUnsettledSince = 0; lastGimbalCommand = 0; gimbalAttempts = 0
            gimbalCommandAcceptedElapsedMillis = 0
            gimbalVerificationStartedElapsedMillis = now
            gimbalCommandGeneration += 1
            gimbalCommandInFlight = false
        }
        if capturePoseWaypointIndex != machine.executionLegIndex {
            capturePoseWaypointIndex = machine.executionLegIndex
            capturePoseStableSinceElapsedMillis = 0
            capturePoseVerificationStartedElapsedMillis = 0
            capturePoseTimeoutHandled = false
        }
        let settled = SurveyGimbalSettlePolicy.isSettled(
            targetPitchDegrees: target.gimbalPitchDegrees, actualPitchDegrees: telemetry.gimbalPitch
        )
        let mechanicalLimit = SurveyNadirGimbalPolicy.isMechanicalLimit(
            targetPitchDegrees: target.gimbalPitchDegrees,
            settled: settled, pitchAtStop: telemetry.gimbalPitchAtStop
        )
        let gimbalVerifiedForCapture = SurveyGimbalSettlePolicy.isVerifiedForCapture(
            targetPitchDegrees: target.gimbalPitchDegrees,
            actualPitchDegrees: telemetry.gimbalPitch,
            commandAcceptedElapsedMillis: gimbalCommandAcceptedElapsedMillis,
            nowElapsedMillis: now
        )
        if mechanicalLimit != gimbalMechanicalLimitActive {
            gimbalMechanicalLimitActive = mechanicalLimit
            log.append("SURVEY", String(
                format: "俯视云台机械下限 %@ · target %.0f° actual %.1f°",
                mechanicalLimit ? "ACTIVE" : "CLEARED",
                target.gimbalPitchDegrees, telemetry.gimbalPitch
            ))
        }
        gimbalUnsettledSince = SurveyGimbalSettlePolicy.updateUnsettledSince(
            nowElapsedMillis: now, unsettledSinceElapsedMillis: gimbalUnsettledSince,
            settled: settled || mechanicalLimit
        )
        if !gimbalVerifiedForCapture && !mechanicalLimit && SurveyGimbalSettlePolicy.hasTimedOut(
            nowElapsedMillis: now,
            settlingStartedElapsedMillis: gimbalVerificationStartedElapsedMillis
        ) {
            pause(reason: String(format: "云台超时 target=%.0f° actual=%.1f°",
                                 target.gimbalPitchDegrees, telemetry.gimbalPitch))
            return
        }
        if !gimbalVerifiedForCapture && !mechanicalLimit && !gimbalCommandInFlight
            && SurveyGimbalSettlePolicy.shouldRetry(
            nowElapsedMillis: now, lastCommandElapsedMillis: lastGimbalCommand
        ) {
            lastGimbalCommand = now; gimbalAttempts += 1
            gimbalCommandInFlight = true
            let generation = gimbalCommandGeneration
            provider.setSurveyGimbalPitch(degrees: target.gimbalPitchDegrees) { [weak self] error in
                Task { @MainActor in
                    guard let self, generation == self.gimbalCommandGeneration else { return }
                    self.gimbalCommandInFlight = false
                    if let error {
                        self.pause(reason: "云台控制失败：\(error.localizedDescription)")
                    } else {
                        self.gimbalCommandAcceptedElapsedMillis = self.elapsedMillis()
                    }
                }
            }
        }

        let poseAligned = SurveyStoppedCapturePosePolicy.aligned(
            telemetry: telemetry, target: target, position: current
        ) && gimbalVerifiedForCapture
        capturePoseStableSinceElapsedMillis = SurveyStoppedCapturePosePolicy.updateStableSince(
            aligned: poseAligned,
            previous: capturePoseStableSinceElapsedMillis,
            now: now,
        )
        let capturePoseReady = SurveyStoppedCapturePosePolicy.stable(
            since: capturePoseStableSinceElapsedMillis,
            now: now,
        )
        let pose = SurveyFollowerPose(latitude: current.latitude,
                                      longitude: current.longitude,
                                      altitudeMeters: current.altitudeMeters,
                                      headingDegrees: currentHeadingDegrees())
        let verticalMaximum = target.point.altitudeMeters < current.altitudeMeters
            ? mission.constraints.descentSpeedMetersPerSecond
            : mission.constraints.takeoffSpeedMetersPerSecond
        if runContinuousCaptureTick(mission: mission, machine: machine, pose: pose,
                                    position: current, gimbalVerified: gimbalVerifiedForCapture,
                                    maximumVerticalSpeed: verticalMaximum, now: now) { return }
        let command: SurveyFollowerCommand
        do {
            command = try SurveyWaypointFollower.command(
                pose: pose, target: target,
                maximumHorizontalSpeedMetersPerSecond: mission.constraints.speed(for: target.captureView),
                maximumVerticalSpeedMetersPerSecond: verticalMaximum,
                alignHeadingBeforeHorizontalMotion: machine.requiresHeadingAlignmentBeforeTranslation
            )
        } catch { abort("航点控制计算失败：\(error.localizedDescription)"); return }

        snapshot.horizontalErrorMeters = command.horizontalErrorMeters
        snapshot.verticalErrorMeters = command.verticalErrorMeters
        if command.horizontalErrorMeters + 0.5 < bestWaypointHorizontalErrorMeters {
            bestWaypointHorizontalErrorMeters = command.horizontalErrorMeters
            lastWaypointProgressElapsedMillis = now
        } else if SurveyWaypointDivergencePolicy.shouldPause(
            bestErrorMeters: bestWaypointHorizontalErrorMeters,
            currentErrorMeters: command.horizontalErrorMeters,
            lastProgressElapsedMillis: lastWaypointProgressElapsedMillis,
            nowElapsedMillis: now
        ) {
            pause(reason: String(
                format: "航点误差持续增大：最小 %.1fm，当前 %.1fm",
                bestWaypointHorizontalErrorMeters, command.horizontalErrorMeters
            ))
            return
        }
        let cameraReady = camera.canCapturePhotos && !photoInFlight
            && !camera.message.contains("写入") && now >= photoBusyUntil
        if SurveyNadirGimbalPolicy.canStartDeferredCapture(
            phase: machine.currentPhase, settled: gimbalVerifiedForCapture, cameraReady: cameraReady
        ),
           let pendingIndex = pendingGimbalCaptureStartWaypointIndex,
           mission.waypoints.indices.contains(pendingIndex) {
            let pending = mission.waypoints[pendingIndex]
            pendingGimbalCaptureStartWaypointIndex = nil
            do {
                if try capture.onWaypointReached(
                    pending, position: current, nowElapsedMillis: now, cameraReady: true
                ) {
                    triggerPhoto(reason: "DELAYED_START_DISTANCE_INTERVAL", position: current)
                }
                // Capture is now active. Persist immediately so a process death
                // cannot revive the older deferred state.
                persistCheckpoint()
                log.append("SURVEY", String(
                    format: "俯视云台已脱离机械下限，延迟开始拍照 · actual %.1f°",
                    telemetry.gimbalPitch
                ))
            } catch {
                pause(reason: "延迟拍照状态机失败：\(error.localizedDescription)")
                return
            }
        }
        if !command.reached, machine.currentPhase == .survey,
           SurveyNadirGimbalPolicy.canCapture(settled: gimbalVerifiedForCapture),
           capture.onPosition(current, nowElapsedMillis: now, cameraReady: cameraReady,
                              horizontalSpeedMetersPerSecond: telemetry.horizontalSpeed) {
            triggerPhoto(reason: mission.constraints.captureTriggerMode == .time ? "time interval" : "distance interval",
                         position: current)
        }
        if command.reached {
            let startsCapture = target.captureAction == .startDistanceInterval
            let stopsCapture = target.captureAction == .stopDistanceInterval
            let deferCaptureStart = SurveyNadirGimbalPolicy.shouldDeferCaptureStart(
                action: target.captureAction, mechanicalLimit: mechanicalLimit
            )
            if !deferCaptureStart { send(.zero) }
            if !gimbalVerifiedForCapture && !deferCaptureStart && !stopsCapture {
                publishProgress(machine)
                return
            }
            if (startsCapture || target.captureAction == .captureOnReach) &&
                !deferCaptureStart && !capturePoseReady {
                if capturePoseVerificationStartedElapsedMillis == 0 {
                    capturePoseVerificationStartedElapsedMillis = now
                }
                if now - capturePoseVerificationStartedElapsedMillis >= SurveyGimbalSettlePolicy.timeoutMillis {
                    pause(reason: "到点后机头或云台姿态长时间未稳定，航线已自动暂停")
                    return
                }
                publishProgress(machine)
                return
            }
            if stopsCapture, let pendingStartIndex = pendingGimbalCaptureStartWaypointIndex {
                send(.zero)
                pendingGimbalCaptureStartWaypointIndex = nil
                capture.reset()
                do {
                    // The strip produced no imagery. Rewind the executable
                    // checkpoint to START before pausing; otherwise Continue
                    // would immediately cross STOP and silently accept a gap.
                    _ = try machine.restorePaused(
                        waypointIndex: pendingStartIndex, legIndex: nil, recoveryPoint: nil
                    )
                    snapshot.phase = machine.currentPhase
                    snapshot.legIndex = machine.executionLegIndex
                    snapshot.waypointIndex = pendingStartIndex
                    snapshot.currentTarget = machine.currentTarget
                    pause(reason: "正射航带全程受云台下限限制，已回退航带起点；请调整航向或等待风况后重试")
                } catch {
                    abort("航带安全回退失败：\(error.localizedDescription)")
                }
                return
            }
            do {
                if deferCaptureStart && startsCapture {
                    pendingGimbalCaptureStartWaypointIndex = machine.status.waypointIndex
                    log.append("SURVEY", String(
                        format: "航带起点云台受机械下限限制，继续飞行并延迟开始拍照 · actual %.1f°",
                        telemetry.gimbalPitch
                    ))
                } else if SurveyNadirGimbalPolicy.shouldSkipEndFrame(
                    action: target.captureAction, settled: gimbalVerifiedForCapture
                ) {
                    capture.reset()
                    log.append("SURVEY", String(
                        format: "云台未收敛，跳过航带终点帧 · actual %.1f°",
                        telemetry.gimbalPitch
                    ))
                } else if target.captureAction == .captureOnReach,
                          pointCaptureCompletedLegIndex == machine.executionLegIndex {
                    // The asynchronous camera callback already completed this point.
                } else if try capture.onWaypointReached(
                    target, position: current, nowElapsedMillis: now, cameraReady: cameraReady
                ) {
                    if target.captureAction == .captureOnReach {
                        pointCapturePendingLegIndex = machine.executionLegIndex
                    }
                    triggerPhoto(reason: target.captureAction.rawValue, position: current)
                }
            } catch { abort("拍照状态机失败：\(error.localizedDescription)"); return }
            if target.captureAction == .captureOnReach,
               pointCaptureCompletedLegIndex != machine.executionLegIndex {
                publishProgress(machine); return
            }
            if target.captureAction == .stopDistanceInterval,
               capture.active || photoInFlight || now < photoBusyUntil {
                publishProgress(machine); return
            }
            guard advanceWaypoint(machine: machine, command: command) else { return }
            publishProgress(machine)
            return
        }
        send(.init(forward: command.forwardMetersPerSecond,
                   right: command.rightMetersPerSecond,
                   up: command.upMetersPerSecond,
                   yawRate: command.yawRateDegreesPerSecond))
        publishProgress(machine)
    }

    private func advanceWaypoint(machine: SurveyExecutionStateMachine, command: SurveyFollowerCommand) -> Bool {
        let reachedPhase = machine.currentPhase
        let reachedLeg = machine.executionLegIndex
        let status = machine.reachWaypoint()
        persistCheckpoint()
        log.append("SURVEY", String(format: "到达航段 %d/%d · %@ · h=%.2fm v=%+.2fm",
                                   reachedLeg + 1, machine.executionLegCount,
                                   phaseLabel(reachedPhase), command.horizontalErrorMeters,
                                   command.verticalErrorMeters))
        if status.state == .completed { complete(); return false }
        setWaypointDeadline()
        return true
    }

    private func runContinuousCaptureTick(mission: SurveyMission, machine: SurveyExecutionStateMachine,
                                          pose: SurveyFollowerPose, position: SurveyGeoPoint,
                                          gimbalVerified: Bool, maximumVerticalSpeed: Double, now: Int64) -> Bool {
        let index = machine.status.waypointIndex
        let target = machine.currentTarget
        guard machine.currentPhase == .survey, target.captureAction == .captureOnReach,
              SurveyContinuousRecapturePolicy.eligible(mission, index: index) else { return false }
        let pending = pointCapturePendingLegIndex == machine.executionLegIndex
        let completed = pointCaptureCompletedLegIndex == machine.executionLegIndex
        if !pending && !completed && SurveyContinuousRecapturePolicy.missedWindow(mission, index: index, pose: pose) {
            pause(reason: "连续补拍已越过拍照窗口，未确认照片；请检查后恢复")
            return true
        }
        let aligned = gimbalVerified && SurveyContinuousRecapturePolicy.poseReady(
            telemetry: telemetry, pose: pose, target: target)
        guard aligned else {
            if !pending && !completed { return false }
            pause(reason: "连续补拍等待确认期间姿态或遥测失效，已暂停")
            return true
        }
        do {
            let command = try SurveyContinuousRecapturePolicy.command(mission, index: index, pose: pose,
                maximumSpeed: mission.constraints.speed(for: target.captureView), maximumVerticalSpeed: maximumVerticalSpeed)
            snapshot.horizontalErrorMeters = command.horizontalErrorMeters
            snapshot.verticalErrorMeters = command.verticalErrorMeters
            let cameraReady = camera.canCapturePhotos && !photoInFlight
                && !camera.message.contains("写入") && now >= photoBusyUntil
            if !pending && !completed && command.reached,
               try capture.onWaypointReached(target, position: position, nowElapsedMillis: now, cameraReady: cameraReady) {
                pointCapturePendingLegIndex = machine.executionLegIndex
                log.append("SURVEY", "连续补拍请求 leg=\(machine.executionLegIndex)")
                triggerPhoto(reason: "CONTINUOUS_CAPTURE_ON_REACH", position: position)
            }
            guard snapshot.state == .running else { return true }
            if pointCaptureCompletedLegIndex == machine.executionLegIndex {
                log.append("SURVEY", "连续补拍确认 leg=\(machine.executionLegIndex)")
                guard advanceWaypoint(machine: machine, command: command) else { return true }
            }
            send(.init(forward: command.forwardMetersPerSecond, right: command.rightMetersPerSecond,
                       up: command.upMetersPerSecond, yawRate: command.yawRateDegreesPerSecond))
            publishProgress(machine)
        } catch {
            pause(reason: "连续补拍控制失败：\(error.localizedDescription)")
        }
        return true
    }

    private func triggerPhoto(reason: String, position: SurveyGeoPoint) {
        guard !photoInFlight else { return }
        let now = elapsedMillis()
        guard now >= photoBusyUntil else { return }
        photoInFlight = true
        photoRequestStartedElapsedMillis = now
        photoReason = reason
        photoRequestGeneration += 1
        let generation = photoRequestGeneration
        if SurveyCaptureSourcePolicy.usesHILVirtualFrame(
            hilVirtualFramesEnabled: virtualFrameCaptureEnabled?() == true,
            simulatorActive: simulator.active
        ) {
            photoVirtualFrameStartSequence = latestVirtualFrame?()?.sequence ?? -1
            log.append("SURVEY", "拍照请求：\(reason) · 等待下一张 UE HIL 虚拟帧")
            return
        }
        photoVirtualFrameStartSequence = nil
        log.append("SURVEY", "拍照请求：\(reason) · 等待 DJI 相机真实回调")
        provider.takeSurveyPhoto { [weak self] error in
            Task { @MainActor in
                guard let self, self.photoRequestGeneration == generation, self.photoInFlight else { return }
                if error == nil { self.capturePostTriggerDownlinkFrame(reason: reason) }
                self.finishPhotoRequest(generation: generation, error: error)
            }
        }
    }

    private func capturePostTriggerDownlinkFrame(reason: String) {
        guard let mission, let machine else { return }
        guard postTriggerFrameCapturesPending < 2 else {
            log.append("SURVEY", "手机图传帧保存队列繁忙；飞机拍照不受影响")
            return
        }
        postTriggerFrameCapturesPending += 1
        let missionSnapshot = mission
        let legIndex = machine.executionLegIndex
        let waypointIndex = machine.status.waypointIndex
        let captureView = machine.currentTarget.captureView
        Task { [weak self] in
            guard let self else { return }
            defer { self.postTriggerFrameCapturesPending = max(0, self.postTriggerFrameCapturesPending - 1) }
            do {
                let frame = try await self.provider.captureSurveyFrame()
                let pose = self.provider.telemetry
                self.log.captureSurveyFrame(
                    frame: frame, mission: missionSnapshot, reason: reason,
                    telemetry: pose, executionLegIndex: legIndex,
                    waypointIndex: waypointIndex
                ) { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        switch result {
                        case .success(let record):
                            self.log.append("SURVEY", "手机已保存拍照后图传帧：\(record.imageURL.lastPathComponent)")
                            self.onSurveyFrameSaved?(record, captureView)
                        case .failure(let error):
                            self.log.append("SURVEY", "手机图传帧保存失败（飞机拍照已成功）：\(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                self.log.append("SURVEY", "未取得拍照后的新图传帧（飞机拍照已成功）：\(error.localizedDescription)")
            }
        }
    }

    private func pollVirtualFrameCapture(mission: SurveyMission,
                                         machine: SurveyExecutionStateMachine) {
        guard photoInFlight, let startSequence = photoVirtualFrameStartSequence,
              let frame = latestVirtualFrame?(), frame.sequence > startSequence else { return }
        photoVirtualFrameStartSequence = nil
        let generation = photoRequestGeneration
        log.captureSurveyFrame(
            frame: frame, mission: mission, reason: photoReason, telemetry: telemetry,
            executionLegIndex: machine.executionLegIndex,
            waypointIndex: machine.status.waypointIndex
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let record):
                    self.onVirtualFrameCaptured?(record)
                    self.finishPhotoRequest(generation: generation, error: nil)
                case .failure(let error):
                    self.finishPhotoRequest(generation: generation, error: error)
                }
            }
        }
    }

    private func finishPhotoRequest(generation: Int64, error: Error?) {
        guard generation == photoRequestGeneration, photoInFlight else {
            log.append("SURVEY", "忽略过期拍照回调")
            return
        }
        photoInFlight = false
        photoVirtualFrameStartSequence = nil
        let now = elapsedMillis()
        let position = currentPoint()
        capture.onCaptureResult(position: position, nowElapsedMillis: now, success: error == nil)
        if let error {
            publishPhotoFeedback(success: false)
            let failedContinuousPoint = mission?.recaptureFlightMode == .continuousExperimental
                && pointCapturePendingLegIndex != nil
            pointCapturePendingLegIndex = nil
            if failedContinuousPoint {
                pause(reason: "连续补拍拍照失败，已暂停：\(error.localizedDescription)")
            } else if SurveyRuntimeFaultPolicy.shouldPauseCameraAction(
                label: "航测相机", ok: false, message: error.localizedDescription
            ) {
                pause(reason: "拍照超时，已自动暂停：\(error.localizedDescription)")
            } else {
                snapshot.message = "警告：单次航测拍照失败；航线继续，需航后检查缺口"
                log.append("SURVEY", "单次拍照失败，航线继续：\(error.localizedDescription)")
            }
            return
        }
        publishPhotoFeedback(success: true)
        photoBusyUntil = now + 1_200
        if let pending = pointCapturePendingLegIndex {
            pointCaptureCompletedLegIndex = pending
            pointCapturePendingLegIndex = nil
        }
        snapshot.photoCount += 1
        log.append("SURVEY", "拍照成功：count=\(snapshot.photoCount) · latency≈\(capture.estimatedCaptureLatencyMillis)ms")
    }

    private func publishPhotoFeedback(success: Bool) {
        snapshot.photoFeedbackSucceeded = success
        snapshot.photoFeedbackSequence &+= 1
    }

    private func complete(message: String = "COMPLETED · 已归零并释放 Virtual Stick") {
        invalidatePhotoRequest()
        invalidateReturnHomeHandoff()
        cancelLowBatteryReturn("任务完成")
        pendingGimbalCaptureStartWaypointIndex = nil
        gimbalMechanicalLimitActive = false
        snapshot.state = .completed
        snapshot.message = message
        capture.reset(); stopAndRelease(); clearPersistedCheckpoint()
        let elapsed = max(1, elapsedMillis() - controlStartedElapsedMillis)
        log.append("SURVEY", String(format: "完成 · VS %.1fHz · FC %.1fHz · zero velocity · VS released",
                                     Double(tickCount) * 1_000 / Double(elapsed),
                                     Double(flightStateCount) * 1_000 / Double(elapsed)))
    }

    private func gate(mission: SurveyMission, requireVirtualStick: Bool,
                      preflight: Bool, allowNotFlying: Bool = false,
                      allowGroundedPositionUnavailable: Bool = false) -> SurveyExecutionGateResult {
        let latitude = telemetry.aircraftLocationValid ? telemetry.aircraft.latitude : .nan
        let longitude = telemetry.aircraftLocationValid ? telemetry.aircraft.longitude : .nan
        let base = SurveyExecutionGate.evaluate(
            mission: mission,
            telemetry: .init(
                connected: telemetry.connected, simulatorActive: simulator.active,
                simulatorFlying: simulator.flying, virtualStickEnabled: telemetry.virtualStickActive,
                sticksActive: telemetry.sticksActive == true, latitude: latitude, longitude: longitude,
                altitudeMeters: telemetry.altitude,
                updatedAtEpochMillis: Int64(telemetry.flightStateTimestamp.timeIntervalSince1970 * 1_000),
                aircraftFlying: telemetry.flying, batteryPercent: telemetry.aircraftBattery,
                rcBatteryPercent: telemetry.rcBattery, rcSignalPercent: telemetry.signal,
                satelliteCount: telemetry.satellites,
                gpsSignalUsable: (4...5).contains(telemetry.gpsSignalLevel),
                homeLocationValid: telemetry.homeLocationSet,
                homeLatitude: telemetry.home.latitude, homeLongitude: telemetry.home.longitude,
                goHomeHeightMeters: telemetry.goHomeHeightMeters,
                maxFlightHeightMeters: telemetry.maxFlightHeightMeters,
                maxFlightRadiusMeters: telemetry.maxFlightRadiusMeters,
                maxFlightRadiusEnabled: telemetry.maxFlightRadiusEnabled,
                horizontalSpeedMetersPerSecond: telemetry.horizontalSpeed,
                verticalSpeedMetersPerSecond: telemetry.verticalSpeed,
                goingHome: telemetry.mode == .returningHome,
                landing: telemetry.mode == .landing
            ),
            nowEpochMillis: Int64(Date().timeIntervalSince1970 * 1_000),
            requireVirtualStick: requireVirtualStick,
            allowNotFlying: allowNotFlying,
            allowGroundedPositionUnavailable: allowGroundedPositionUnavailable,
            environment: simulator.active ? .djiSimulator : .realAircraftManualTakeoff,
            checkPreflightReadiness: preflight
        )
        var blocks = base.blocks
        let usesVirtualCapture = SurveyCaptureSourcePolicy.usesHILVirtualFrame(
            hilVirtualFramesEnabled: virtualFrameCaptureEnabled?() == true,
            simulatorActive: simulator.active
        )
        if !usesVirtualCapture && camera.surveyGeometryRequired {
            let sampleAge = Date().timeIntervalSince(camera.surveyCameraUpdatedAt)
            let geometryMatches = camera.surveyCameraProfile.map { profile in
                mission.activeMapping == nil
                    ? SurveyCameraProfileCatalog.matchesMission(mission.cameraProfile, current: profile)
                    : SurveyCameraProfileCatalog.compatibleRecapture(mission.cameraProfile, current: profile)
            } ?? false
            if !(0...2).contains(sampleAge) || !geometryMatches {
                blocks.insert(.cameraGeometryUnverified)
            }
        }
        if !usesVirtualCapture && !camera.canCapturePhotos {
            blocks.insert(.cameraUnavailable)
        }
        if !preflight && !simulator.active {
            if telemetry.signal < SurveyExecutionGate.realMinimumRCSignalPercent {
                blocks.insert(.rcSignalWeak)
            }
            if telemetry.satellites < SurveyExecutionGate.realMinimumSatellites {
                blocks.insert(.gpsSatellitesLow)
            }
            if !(4...5).contains(telemetry.gpsSignalLevel) { blocks.insert(.gpsSignalWeak) }
            if !telemetry.homeLocationSet { blocks.insert(.homeLocationRequired) }
        }
        return .init(allowed: blocks.isEmpty, blocks: blocks,
                     startDistanceMeters: base.startDistanceMeters)
    }

    private func stabilizedRuntimeGate(_ gate: SurveyExecutionGateResult,
                                       now: Int64) -> SurveyExecutionGateResult {
        let graceEligible: Set<SurveyExecutionBlock> = [
            .cameraUnavailable, .rcSignalWeak, .gpsSatellitesLow,
            .gpsSignalWeak, .homeLocationRequired,
        ]
        let degraded = gate.blocks.intersection(graceEligible)
        guard !degraded.isEmpty else {
            runtimeReadinessFaultSinceElapsedMillis = 0
            runtimeReadinessFaultSignature.removeAll()
            return gate
        }
        if runtimeReadinessFaultSinceElapsedMillis == 0 {
            runtimeReadinessFaultSinceElapsedMillis = now
        }
        // Keep the first fault time while any readiness fault remains present.
        // Alternating GPS/signal/camera failures must not reset the 1.5 s grace.
        runtimeReadinessFaultSignature = degraded
        guard now - runtimeReadinessFaultSinceElapsedMillis < Self.runtimeReadinessGraceMillis else {
            return gate
        }
        let immediateBlocks = gate.blocks.subtracting(degraded)
        return .init(allowed: immediateBlocks.isEmpty, blocks: immediateBlocks,
                     startDistanceMeters: gate.startDistanceMeters)
    }

    private func setWaypointDeadline() {
        guard let mission, let machine else { return }
        legStartedElapsedMillis = elapsedMillis()
        bestWaypointHorizontalErrorMeters = .infinity
        lastWaypointProgressElapsedMillis = legStartedElapsedMillis
        let current = currentPoint()
        let pose = SurveyFollowerPose(latitude: current.latitude,
                                      longitude: current.longitude,
                                      altitudeMeters: current.altitudeMeters,
                                      headingDegrees: currentHeadingDegrees())
        let horizontalMaximum = max(0.1, mission.constraints.speed(for: machine.currentTarget.captureView))
        let verticalMaximum = max(0.1,
            machine.currentTarget.point.altitudeMeters < current.altitudeMeters
                ? mission.constraints.descentSpeedMetersPerSecond
                : mission.constraints.takeoffSpeedMetersPerSecond)
        let estimate = try? SurveyWaypointFollower.command(
            pose: pose, target: machine.currentTarget,
            maximumHorizontalSpeedMetersPerSecond: horizontalMaximum,
            maximumVerticalSpeedMetersPerSecond: verticalMaximum
        )
        let horizontalSeconds = (estimate?.horizontalErrorMeters ?? 0) / horizontalMaximum
        let verticalSeconds = abs(estimate?.verticalErrorMeters ?? 0) / verticalMaximum
        let allowance = max(30, horizontalSeconds * 4 + verticalSeconds * 2 + 15)
        waypointDeadlineElapsedMillis = legStartedElapsedMillis + Int64(allowance * 1_000)
    }

    private func publishProgress(_ machine: SurveyExecutionStateMachine) {
        updateRemainingEstimate(machine)
        snapshot.state = machine.status.state
        snapshot.phase = machine.currentPhase
        snapshot.legIndex = machine.executionLegIndex
        snapshot.legCount = machine.executionLegCount
        snapshot.waypointIndex = machine.status.waypointIndex
        snapshot.missionID = mission?.id
        snapshot.currentTarget = machine.currentTarget
        snapshot.message = "RUNNING · \(phaseLabel(machine.currentPhase)) · 段 \(machine.executionLegIndex + 1)/\(machine.executionLegCount)"
    }

    private func updateRemainingEstimate(_ machine: SurveyExecutionStateMachine) {
        let remaining = machine.remainingEstimate(
            currentPosition: currentPoint(), currentHeadingDegrees: currentHeadingDegrees(),
            currentHorizontalSpeedMetersPerSecond: telemetry.horizontalSpeed,
            currentVerticalSpeedMetersPerSecond: telemetry.verticalSpeed
        )
        snapshot.currentSectionRemainingSeconds = remaining.currentSectionSeconds
        snapshot.totalRemainingSeconds = remaining.totalSeconds
    }

    private func send(_ command: VelocityCommand) {
        snapshot.lastCommand = command
        provider.sendSurvey(command)
    }

    private func stopAndRelease() {
        timer?.invalidate(); timer = nil
        send(.zero)
        provider.setVirtualStick(enabled: false)
    }

    private func resetRuntimeTracking() {
        invalidateReturnHomeHandoff()
        resetGimbalVerification()
        gimbalMechanicalLimitActive = false
        pendingGimbalCaptureStartWaypointIndex = nil
        pointCapturePendingLegIndex = nil
        pointCaptureCompletedLegIndex = nil
        capturePoseWaypointIndex = nil
        capturePoseStableSinceElapsedMillis = 0
        capturePoseVerificationStartedElapsedMillis = 0
        capturePoseTimeoutHandled = false
        runtimeReadinessFaultSinceElapsedMillis = 0
        runtimeReadinessFaultSignature.removeAll()
        photoBusyUntil = 0; waypointDeadlineElapsedMillis = 0
        bestWaypointHorizontalErrorMeters = .infinity
        lastWaypointProgressElapsedMillis = 0
        invalidatePhotoRequest()
        controlStartedElapsedMillis = 0; tickCount = 0; flightStateCount = 0
        resumingPausedMission = false
    }

    private func resetGimbalVerification() {
        capturePoseWaypointIndex = nil
        capturePoseStableSinceElapsedMillis = 0
        capturePoseVerificationStartedElapsedMillis = 0
        capturePoseTimeoutHandled = false
        requestedGimbalPitch = .nan
        gimbalUnsettledSince = 0
        lastGimbalCommand = 0
        gimbalAttempts = 0
        gimbalCommandAcceptedElapsedMillis = 0
        gimbalVerificationStartedElapsedMillis = 0
        gimbalCommandGeneration += 1
        gimbalCommandInFlight = false
    }

    private func beginVirtualStickArming() {
        armingDeadline = elapsedMillis() + 8_000
        snapshot.message = "ARMING · 正在申请 Virtual Stick"
        provider.send(.zero)
        provider.setVirtualStick(enabled: true)
        startTimer()
    }

    private func advanceAutomaticTakeoff() {
        let now = elapsedMillis()
        guard now < autoTakeoffDeadlineElapsedMillis else {
            abort("Simulator 自动起飞 30 秒未确认稳定悬停")
            return
        }
        guard telemetry.connected, simulator.active else {
            abort("Simulator 自动起飞条件失效")
            return
        }
        let stable = simulator.flying && telemetry.altitude >= 0.8
            && abs(telemetry.verticalSpeed) <= 0.5
        if stable {
            if autoTakeoffStableSinceElapsedMillis == 0 { autoTakeoffStableSinceElapsedMillis = now }
            if now - autoTakeoffStableSinceElapsedMillis >= 1_000 {
                autoTakeoffPending = false
                snapshot.message = "AUTO TAKEOFF · 稳定悬停完成，正在申请 Virtual Stick"
                beginVirtualStickArming()
            }
        } else {
            autoTakeoffStableSinceElapsedMillis = 0
        }
    }

    private func beginReturnHomeHandoff(machine: SurveyExecutionStateMachine) {
        guard !returnHomeHandoffPending, self.machine === machine else { return }
        returnHomeHandoffPending = true
        returnHomeHandoffCommandSent = false
        returnHomeHandoffGeneration += 1
        returnHomeHandoffReleaseDeadlineElapsedMillis = elapsedMillis()
            + Self.virtualStickReleaseFallbackMillis
        invalidatePhotoRequest()
        capture.reset()
        pendingGimbalCaptureStartWaypointIndex = nil
        send(.zero)
        provider.setVirtualStick(enabled: false)
        snapshot.message = "全部航线采集完成，正在释放控制权并移交 DJI 自动返航"
        log.append("SURVEY", "DJI RTH handoff started · zero velocity · waiting for VS release")
        advanceReturnHomeHandoff()
    }

    private func advanceReturnHomeHandoff() {
        guard returnHomeHandoffPending, !returnHomeHandoffCommandSent,
              let machine, machine.currentPhase == .returnHome else { return }
        let released = !telemetry.virtualStickActive
        let releaseTimedOut = elapsedMillis() >= returnHomeHandoffReleaseDeadlineElapsedMillis
        guard released || releaseTimedOut else { return }
        returnHomeHandoffCommandSent = true
        let generation = returnHomeHandoffGeneration
        let recoveryPoint = currentPoint()
        let releaseReason = released ? "VS released" : "VS release wait timed out after 1.5s"
        snapshot.message = "控制权已释放，正在请求 DJI 自动返航"
        provider.returnHome { [weak self, weak machine] error in
            Task { @MainActor in
                guard let self, let machine,
                      self.returnHomeHandoffPending,
                      self.returnHomeHandoffGeneration == generation,
                      self.machine === machine else { return }
                if let error {
                    self.returnHomeHandoffPending = false
                    self.returnHomeHandoffCommandSent = false
                    _ = machine.pause(
                        reason: "DJI 自动返航启动失败：\(error.localizedDescription)",
                        recoveryPoint: recoveryPoint
                    )
                    self.snapshot.state = .paused
                    self.snapshot.phase = machine.currentPhase
                    self.snapshot.legIndex = machine.executionLegIndex
                    self.snapshot.legCount = machine.executionLegCount
                    self.snapshot.waypointIndex = machine.status.waypointIndex
                    self.snapshot.currentTarget = machine.currentTarget
                    self.updateRemainingEstimate(machine)
                    self.snapshot.message = "DJI 自动返航启动失败，任务尚未完成：\(error.localizedDescription)"
                    self.stopAndRelease()
                    self.persistCheckpoint()
                    self.log.append("SURVEY", self.snapshot.message)
                    return
                }
                _ = machine.acceptDJIReturnHome()
                self.log.append("SURVEY", "DJI RTH accepted · \(releaseReason)")
                self.complete(message: "COMPLETED · DJI 自动返航已启动")
            }
        }
    }

    private func invalidateReturnHomeHandoff() {
        returnHomeHandoffGeneration += 1
        returnHomeHandoffPending = false
        returnHomeHandoffCommandSent = false
        returnHomeHandoffReleaseDeadlineElapsedMillis = 0
    }

    private func monitorLowBatteryReturn() {
        guard !returnHomeHandoffPending else { return }
        if !telemetry.flying {
            lowBatteryReturnIssued = false
            lowBatteryReturnCommandSent = false
            cancelLowBatteryReturn("飞机已落地")
            return
        }
        let shouldReturn = SurveyLowBatteryPolicy.shouldTrigger(
            batteryPercent: telemetry.aircraftBattery, aircraftFlying: telemetry.flying,
            simulatorActive: simulator.active, executionState: snapshot.state
        )
        guard shouldReturn else {
            if lowBatteryReturnPending { cancelLowBatteryReturn("触发条件已解除") }
            return
        }
        guard !lowBatteryReturnIssued, lowBatteryReturnDeadlineElapsedMillis == 0 else { return }
        lowBatteryReturnDeadlineElapsedMillis = elapsedMillis()
            + SurveyLowBatteryPolicy.autoReturnCountdownMillis
        if snapshot.state == .running || snapshot.state == .arming {
            pause(reason: "飞机电量低于 20%，已保存断点")
        }
        updateLowBatteryCountdown()
        lowBatteryReturnTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceLowBatteryReturnCountdown() }
        }
        lowBatteryReturnTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        log.append("SURVEY", "LOW BATTERY \(telemetry.aircraftBattery)% · 5 秒后自动返航 · checkpoint retained")
    }

    private func advanceLowBatteryReturnCountdown() {
        guard lowBatteryReturnDeadlineElapsedMillis > 0, !lowBatteryReturnIssued else { return }
        let stillRequired = SurveyLowBatteryPolicy.shouldTrigger(
            batteryPercent: telemetry.aircraftBattery, aircraftFlying: telemetry.flying,
            simulatorActive: simulator.active, executionState: snapshot.state
        )
        guard stillRequired else { cancelLowBatteryReturn("触发条件已解除"); return }
        if elapsedMillis() >= lowBatteryReturnDeadlineElapsedMillis {
            issueLowBatteryReturnNow()
        } else {
            updateLowBatteryCountdown()
        }
    }

    func issueLowBatteryReturnNow() {
        guard lowBatteryReturnDeadlineElapsedMillis > 0, !lowBatteryReturnIssued else { return }
        lowBatteryReturnIssued = true
        lowBatteryReturnCommandSent = false
        lowBatteryReturnDeadlineElapsedMillis = 0
        lowBatteryReturnTimer?.invalidate(); lowBatteryReturnTimer = nil
        snapshot.lowBatteryReturnSeconds = nil
        send(.zero)
        provider.setVirtualStick(enabled: false)
        lowBatteryVirtualStickReleaseDeadlineElapsedMillis = elapsedMillis()
            + Self.virtualStickReleaseFallbackMillis
        lowBatteryVirtualStickReleaseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceLowBatteryVirtualStickRelease() }
        }
        lowBatteryVirtualStickReleaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        snapshot.message = "LOW BATTERY · 正在释放 Virtual Stick，释放后自动返航"
        log.append("SURVEY", "LOW BATTERY · zero velocity · waiting for VS release before DJI RTH")
        advanceLowBatteryVirtualStickRelease()
    }

    private func advanceLowBatteryVirtualStickRelease() {
        guard lowBatteryReturnIssued, !lowBatteryReturnCommandSent,
              lowBatteryVirtualStickReleaseDeadlineElapsedMillis > 0 else { return }
        let stillRequired = SurveyLowBatteryPolicy.shouldTrigger(
            batteryPercent: telemetry.aircraftBattery, aircraftFlying: telemetry.flying,
            simulatorActive: simulator.active, executionState: snapshot.state
        )
        guard stillRequired else { cancelLowBatteryReturn("触发条件已解除"); return }
        if !telemetry.virtualStickActive {
            sendLowBatteryReturnHomeCommand(reason: "VS released")
        } else if elapsedMillis() >= lowBatteryVirtualStickReleaseDeadlineElapsedMillis {
            sendLowBatteryReturnHomeCommand(reason: "VS release wait timed out after 1.5s")
        }
    }

    private func sendLowBatteryReturnHomeCommand(reason: String) {
        guard lowBatteryReturnIssued, !lowBatteryReturnCommandSent else { return }
        lowBatteryReturnCommandSent = true
        lowBatteryVirtualStickReleaseDeadlineElapsedMillis = 0
        lowBatteryVirtualStickReleaseTimer?.invalidate()
        lowBatteryVirtualStickReleaseTimer = nil
        provider.returnHome { [weak self] error in
            guard let self, self.lowBatteryReturnIssued,
                  self.lowBatteryReturnCommandSent else { return }
            if let error {
                self.lowBatteryReturnCommandSent = false
                self.lowBatteryReturnIssued = false
                self.snapshot.message = "低电量返航请求失败：\(error.localizedDescription)；请立即手动返航"
                self.log.append("SURVEY", self.snapshot.message)
                // Keep the aircraft paused and re-arm the protected countdown.
                // A rejected asynchronous DJI callback must not leave the
                // low-battery workflow permanently idle.
                self.monitorLowBatteryReturn()
            } else {
                self.snapshot.message = "LOW BATTERY · 已保存航线进度并请求 DJI 自动返航"
                self.log.append("SURVEY", "LOW BATTERY · DJI RTH accepted · \(reason)")
            }
        }
    }

    private func updateLowBatteryCountdown() {
        let remaining = max(0, lowBatteryReturnDeadlineElapsedMillis - elapsedMillis())
        let seconds = Int(ceil(Double(remaining) / 1_000))
        snapshot.lowBatteryReturnSeconds = seconds
        snapshot.message = "LOW BATTERY · 航线已暂停并保存 · \(seconds) 秒后自动返航"
    }

    private func cancelLowBatteryReturn(_ reason: String) {
        guard lowBatteryReturnPending else { return }
        lowBatteryReturnDeadlineElapsedMillis = 0
        lowBatteryReturnTimer?.invalidate(); lowBatteryReturnTimer = nil
        lowBatteryVirtualStickReleaseDeadlineElapsedMillis = 0
        lowBatteryVirtualStickReleaseTimer?.invalidate(); lowBatteryVirtualStickReleaseTimer = nil
        if !lowBatteryReturnCommandSent { lowBatteryReturnIssued = false }
        snapshot.lowBatteryReturnSeconds = nil
        log.append("SURVEY", "低电量返航流程取消：\(reason)")
    }

    private var lowBatteryReturnPending: Bool {
        lowBatteryReturnDeadlineElapsedMillis > 0 || lowBatteryReturnTimer != nil
            || lowBatteryVirtualStickReleaseDeadlineElapsedMillis > 0
            || lowBatteryVirtualStickReleaseTimer != nil
            || (lowBatteryReturnIssued && !lowBatteryReturnCommandSent)
    }

    private func invalidatePhotoRequest() {
        photoRequestGeneration += 1
        photoInFlight = false
        photoRequestStartedElapsedMillis = 0
        photoVirtualFrameStartSequence = nil
        photoReason = ""
        pointCapturePendingLegIndex = nil
        capture.cancelPendingCapture()
    }

    private func currentPoint() -> SurveyGeoPoint {
        if !telemetry.aircraftLocationValid,
           let point = SurveySimulatorMapProjection.point(from: simulator) { return point }
        return .init(latitude: telemetry.aircraft.latitude, longitude: telemetry.aircraft.longitude,
                     altitudeMeters: telemetry.altitude)
    }

    private func currentHeadingDegrees() -> Double {
        !telemetry.aircraftLocationValid && simulator.active && simulator.stateReceived
            ? simulator.yawDegrees : telemetry.heading
    }

    /// Keep the execution launch point and DJI Home separate. Returning to the
    /// aircraft's position at task start is unsafe if Home was set elsewhere.
    private func surveyReturnPoint() -> SurveyGeoPoint {
        let home = telemetry.home
        if telemetry.homeLocationSet,
           home.latitude.isFinite, home.longitude.isFinite,
           (-90...90).contains(home.latitude), (-180...180).contains(home.longitude),
           abs(home.latitude) > 1e-9 || abs(home.longitude) > 1e-9 {
            return .init(latitude: home.latitude, longitude: home.longitude,
                         altitudeMeters: 1.2)
        }
        let current = currentPoint()
        return .init(latitude: current.latitude, longitude: current.longitude,
                     altitudeMeters: 1.2)
    }

    private func persistCheckpoint() {
        guard let mission, let machine else { return }
        guard SurveyRuntimeCheckpointPolicy.canRestore(machine.status.state) else {
            clearPersistedCheckpoint()
            return
        }
        guard let missionRaw = try? SurveyMissionJSON.encode(mission),
              let checkpoint = try? SurveyExecutionCheckpoint(
                missionID: mission.id, waypointIndex: machine.status.waypointIndex,
                state: machine.status.state, updatedAtEpochMillis: Int64(Date().timeIntervalSince1970 * 1_000),
                executionLegIndex: machine.executionLegIndex, phase: machine.currentPhase,
                recoveryPoint: machine.recoveryPoint(), captureStateRecorded: true,
                activeCaptureIntervalMeters: capture.activeIntervalMeters,
                pendingCaptureStartWaypointIndex: pendingGimbalCaptureStartWaypointIndex
              ), let checkpointRaw = try? SurveyExecutionCheckpointJSON.encode(checkpoint) else { return }
        UserDefaults.standard.set(missionRaw, forKey: missionKey)
        UserDefaults.standard.set(checkpointRaw, forKey: checkpointKey)
        snapshot.recoverableMissionName = mission.name
    }

    private func restoreCaptureState(mission: SurveyMission,
                                     recovery: SurveyCaptureCheckpointRecoveryDecision) throws {
        pendingGimbalCaptureStartWaypointIndex = nil
        gimbalMechanicalLimitActive = false
        try capture.configure(
            mode: mission.constraints.captureTriggerMode,
            timedCaptureIntervalSeconds: mission.constraints.timedCaptureIntervalSeconds
        )
        if let pendingIndex = recovery.pendingCaptureStartWaypointIndex {
            guard mission.waypoints.indices.contains(pendingIndex),
                  mission.waypoints[pendingIndex].captureAction == .startDistanceInterval else {
                throw SurveyValidationError.invalid("checkpoint pending capture waypoint is invalid")
            }
            pendingGimbalCaptureStartWaypointIndex = pendingIndex
        } else if let activeInterval = recovery.activeCaptureIntervalMeters {
            try capture.restoreActive(
                captureIntervalMeters: activeInterval,
                mode: mission.constraints.captureTriggerMode,
                timedCaptureIntervalSeconds: mission.constraints.timedCaptureIntervalSeconds
            )
        }
    }

    private func clearPersistedCheckpoint() {
        UserDefaults.standard.removeObject(forKey: checkpointKey)
        snapshot.recoverableMissionName = nil
    }

    private func restoreCheckpointMetadata() {
        guard let checkpointRaw = UserDefaults.standard.string(forKey: checkpointKey) else { return }
        guard let raw = UserDefaults.standard.string(forKey: missionKey),
              let value = try? SurveyMissionJSON.decode(raw),
              let checkpoint = try? SurveyExecutionCheckpointJSON.decode(checkpointRaw),
              checkpoint.missionID == value.id,
              SurveyRuntimeCheckpointPolicy.canRestore(checkpoint.state),
              value.waypoints.indices.contains(checkpoint.waypointIndex) else {
            UserDefaults.standard.removeObject(forKey: checkpointKey)
            return
        }
        snapshot.recoverableMissionName = value.name
        snapshot.message = "发现暂停断点：\(value.name)"
    }

    private func elapsedMillis() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    private func blockText(_ blocks: Set<SurveyExecutionBlock>) -> String {
        blocks.map(blockLabel).sorted().joined(separator: "、")
    }

    private func blockLabel(_ block: SurveyExecutionBlock) -> String {
        switch block {
        case .aircraftDisconnected: return "飞控未连接"
        case .simulatorRequired: return "仅允许 DJI 内置仿真器"
        case .simulatorNotFlying: return "仿真器尚未起飞"
        case .simulatorMustBeOff: return "真机执行前必须关闭 Simulator"
        case .realAircraftNotFlying: return "请先手动起飞并悬停"
        case .realAircraftNotStablyHovering: return "请在 1.5 m 以上稳定悬停"
        case .realRequiresManualTakeoff: return "真机仅允许手动起飞模式"
        case .telemetryStale: return "遥测过期"
        case .gpsUnavailable: return "GPS 不可用"
        case .manualTakeover: return "检测到摇杆接管"
        case .virtualStickRequired: return "VS 未就绪"
        case .unsupportedCoordinateFrame: return "任务不是 WGS-84"
        case .missionTooLong: return "任务航程超限"
        case .missionAltitudeUnsafe: return "任务高度不安全"
        case .cameraGeometryUnverified: return "相机参数未确认或与航线不符，请检查镜头、照片比例、分辨率和变焦"
        case .cameraUnavailable: return "相机或拍照存储不可用"
        case .cameraTriggerUnsafe: return "相机拍照间隔跟不上当前航速"
        case .aircraftBatteryLow: return "飞机电量低于 30%"
        case .rcBatteryLow: return "遥控器电量低于 30%"
        case .rcSignalWeak: return "遥控信号低于 40%"
        case .gpsSatellitesLow: return "GPS 卫星少于 12 颗"
        case .gpsSignalWeak: return "GPS 信号未达 LEVEL_4/5"
        case .homeLocationRequired: return "返航点无效"
        case .goHomeHeightUnsafe: return "返航高度低于任务最高高度"
        case .maxFlightHeightTooLow: return "最大飞行高度不足"
        case .maxFlightRadiusRequired: return "未开启最大飞行半径限制"
        case .maxFlightRadiusTooSmall: return "最大飞行半径覆盖不了航线"
        case .flightControllerFailsafeActive: return "飞控已进入返航或降落"
        case .terrainFeatureDisabled: return "当前发布版本未启用仿地飞行"
        case .terrainRealFlightNotVerified: return "DSM 仿地尚未完成真机验证，仅允许预演/仿真"
        }
    }

    private func phaseLabel(_ phase: SurveyExecutionPhase) -> String {
        switch phase {
        case .safeClimb: return "安全爬升"
        case .transitToStart: return "前往航线起点"
        case .recoveryToPause: return "返回暂停点"
        case .survey: return "采集"
        case .returnHome: return "返回起飞点"
        case .returnToStart: return "返回航线起点"
        }
    }
}
