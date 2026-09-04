import Foundation

@MainActor
final class MockFlightProvider: DJIFlightProvider {
    private(set) var telemetry = FlightTelemetry()
    private(set) var camera = CameraStatus()
    private(set) var latestFrame: CameraFrame? = .simulator(sequence: 0)
    private(set) var liveVideoTimestamp: Date? = Date()
    private(set) var simulatorStatus = FlightSimulatorStatus(available: true, message: "Mock 仿真器可用")
    private(set) var djiAccount = DJIAccountSnapshot(
        state: .loggedIn,
        maskedAccount: "Mock",
        lastError: nil
    )
    var onTelemetry: ((FlightTelemetry) -> Void)?
    var onCamera: ((CameraStatus) -> Void)?
    var onFrame: ((CameraFrame) -> Void)?
    var onSimulator: ((FlightSimulatorStatus) -> Void)?
    var onManualTakeover: (() -> Void)?
    var onDiagnostic: ((String, String) -> Void)?
    var onVirtualStickSendFailure: ((String) -> Void)?
    var onDJIAccount: ((DJIAccountSnapshot) -> Void)?
    let providerName = "Mac Simulator Mock"
    let djiAccountLoginIsSimulated = true

    private var timer: Timer?
    private var virtualStick = false
    private var command = VelocityCommand.zero
    private var stale = false
    private var landingStarted: Date?
    private var rthStarted: Date?
    private var tickCount = 0
    private var virtualStickReleaseDelayNanosecondsForTesting: UInt64 = 0
    private var takeoffCallbackErrorsForTesting: [Error] = []
    private var takeoffAcceptedWithoutAirborneForTesting = false
    private var simulatorStartProducesRawForTesting = true
    private var simulatorRawPublishOnRefreshAttemptForTesting: Int?
    private var simulatorSetErrorsForTesting: [Error] = []
    private var simulatorSetDelayNanosecondsForTesting: UInt64 = 0
    private var rawSimulatorStateStore: RawSimulatorStateStore?
    private var simulatorOrigin = OpenFlyDemoLocation.shanghaiCityCenter
    private(set) var takeoffRequestCount = 0
    private(set) var motorStartRequestCount = 0
    private(set) var simulatorSetRequestsForTesting: [Bool] = []
    private(set) var simulatorRefreshRequestCount = 0
    private(set) var lastAutopilotRequestSawVirtualStickActive = false
    private(set) var returnHomeRequestCount = 0
    private(set) var landingRequestCount = 0

    func start() {
        timer?.invalidate()
        onTelemetry?(telemetry)
        onCamera?(camera)
        publishSimulatorStatus()
        onDJIAccount?(djiAccount)
        latestFrame.map { onFrame?($0) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refreshDJIAccount() { onDJIAccount?(djiAccount) }

    func logIntoDJIAccount(completion: @escaping (Error?) -> Void) {
        djiAccount = DJIAccountSnapshot(state: .loggedIn, maskedAccount: "Mock", lastError: nil)
        onDJIAccount?(djiAccount)
        completion(nil)
    }

    func logOutOfDJIAccount(completion: @escaping (Error?) -> Void) {
        djiAccount = DJIAccountSnapshot(state: .notLoggedIn, maskedAccount: nil, lastError: nil)
        onDJIAccount?(djiAccount)
        completion(nil)
    }

    func configureDJIAccountForTesting(_ snapshot: DJIAccountSnapshot) {
        djiAccount = snapshot
        onDJIAccount?(snapshot)
    }

    func takeOff() throws {
        guard telemetry.connected else { throw FlightActionError.disconnected }
        telemetry.flying = true
        telemetry.mode = .gps
        telemetry.altitude = max(telemetry.altitude, 1.2)
        telemetry.asl = 5.4
        if simulatorStatus.active {
            simulatorStatus.motorsOn = true
            simulatorStatus.flying = true
            simulatorStatus.message = "Mock DJI 仿真飞行中"
            publishSimulatorStatus()
        }
        publish()
    }

    func takeOff(completion: @escaping (Error?) -> Void) {
        takeoffRequestCount += 1
        if !takeoffCallbackErrorsForTesting.isEmpty {
            completion(takeoffCallbackErrorsForTesting.removeFirst())
            return
        }
        if takeoffAcceptedWithoutAirborneForTesting {
            completion(nil)
            return
        }
        do {
            try takeOff()
            completion(nil)
        } catch {
            completion(error)
        }
    }

    func configureTakeoffCallbackErrorsForTesting(_ errors: [Error]) {
        takeoffCallbackErrorsForTesting = errors
    }

    func configureTakeoffAcceptedWithoutAirborneForTesting(_ enabled: Bool) {
        takeoffAcceptedWithoutAirborneForTesting = enabled
    }

    func turnOnMotors(completion: @escaping (Error?) -> Void) {
        motorStartRequestCount += 1
        guard telemetry.connected else {
            completion(FlightActionError.disconnected)
            return
        }
        guard simulatorStatus.active, simulatorStatus.stateReceived else {
            completion(FlightActionError.unavailable("Simulator 未激活或没有原始状态"))
            return
        }
        simulatorStatus.motorsOn = true
        simulatorStatus.message = "Mock DJI 仿真电机已启动"
        publishSimulatorStatus()
        completion(nil)
    }

    func land() throws {
        try requireFlying()
        landingRequestCount += 1
        lastAutopilotRequestSawVirtualStickActive = telemetry.virtualStickActive
        virtualStick = false; command = .zero
        telemetry.mode = .landing
        landingStarted = Date()
        publish()
    }

    func cancelLanding() throws {
        try requireFlying()
        guard telemetry.mode == .landing else { throw FlightActionError.unavailable("当前未在降落") }
        landingStarted = nil; telemetry.mode = .gps; telemetry.verticalSpeed = 0; publish()
    }

    func confirmLanding() throws {
        try requireFlying()
        guard telemetry.mode == .landing else {
            throw FlightActionError.unavailable("当前无需确认降落")
        }
        telemetry.landingConfirmationNeeded = false
        publish()
    }

    func returnHome() throws {
        try requireFlying()
        returnHomeRequestCount += 1
        lastAutopilotRequestSawVirtualStickActive = telemetry.virtualStickActive
        virtualStick = false; command = .zero
        telemetry.mode = .returningHome
        rthStarted = Date()
        publish()
    }

    func cancelReturnHome() throws {
        try requireFlying()
        guard telemetry.mode == .returningHome else { throw FlightActionError.unavailable("当前未在返航") }
        rthStarted = nil; telemetry.mode = .gps; telemetry.horizontalSpeed = 0; publish()
    }

    func setPhoneChargingEnabled(_ enabled: Bool) {
        telemetry.rcPhoneChargingAvailable = true
        telemetry.rcPhoneChargingMode = enabled ? "ALWAYS" : "NEVER"
        onDiagnostic?("DJI", enabled ? "遥控器将给手机充电" : "已关闭遥控器给手机充电")
        publish()
    }

    func setVirtualStick(enabled: Bool) {
        if !enabled, virtualStickReleaseDelayNanosecondsForTesting > 0 {
            let delay = virtualStickReleaseDelayNanosecondsForTesting
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                self?.applyVirtualStick(false)
            }
            return
        }
        applyVirtualStick(enabled)
    }

    private func applyVirtualStick(_ enabled: Bool) {
        virtualStick = enabled
        telemetry.virtualStickActive = enabled
        if !enabled { command = .zero; telemetry.horizontalSpeed = 0; telemetry.verticalSpeed = 0 }
        if telemetry.flying && telemetry.mode != .returningHome && telemetry.mode != .landing {
            telemetry.mode = enabled ? .vln : .gps
        }
        publish()
    }

    func configureVirtualStickReleaseDelayForTesting(_ nanoseconds: UInt64) {
        virtualStickReleaseDelayNanosecondsForTesting = nanoseconds
    }

    func simulateSticksForTesting(active: Bool) {
        telemetry.sticksActive = active
        publish()
    }

    func simulateFlightModeForTesting(_ mode: AircraftFlightMode) {
        telemetry.mode = mode
        publish()
    }

    func send(_ command: VelocityCommand) {
        guard virtualStick, telemetry.connected else { return }
        if !telemetry.flying, simulatorStatus.active, simulatorStatus.motorsOn, command.up > 0 {
            telemetry.flying = true
            telemetry.mode = .vln
            telemetry.altitude = max(telemetry.altitude, 0.8)
            simulatorStatus.flying = true
            simulatorStatus.positionZ = -max(0.8, -simulatorStatus.positionZ)
            simulatorStatus.message = "Mock DJI 仿真飞行中"
            publishSimulatorStatus()
            publish()
        }
        guard telemetry.flying else { return }
        self.command = command
    }

    func takePhoto() throws {
        guard camera.connected else { throw FlightActionError.unavailable(camera.message) }
        guard camera.sdInserted else { throw FlightActionError.unavailable("SD 卡未插入") }
        camera.photosRemaining = max(0, camera.photosRemaining - 1)
        camera.message = "照片已保存（Mock）"
        onCamera?(camera)
    }

    func toggleRecording() throws {
        guard camera.connected else { throw FlightActionError.unavailable(camera.message) }
        guard camera.sdInserted else { throw FlightActionError.unavailable("SD 卡未插入") }
        camera.recording.toggle()
        if !camera.recording { camera.recordingSeconds = 0 }
        camera.message = camera.recording ? "正在录像（Mock）" : "录像已停止"
        onCamera?(camera)
    }

    func refreshMediaList(update: @escaping ([AircraftMediaItem], String?) -> Void) {
        var items: [AircraftMediaItem] = []
        for index in 0..<12 {
            let extensionName = index % 4 == 0 ? "MP4" : "JPG"
            let sequence = String(format: "%04d", index + 1)
            let item = AircraftMediaItem(
                id: "mock-\(index)",
                fileName: "DJI_\(sequence).\(extensionName)",
                timeCreated: "Simulator",
                fileSizeBytes: Int64((index + 1) * 1_048_576),
                isVideo: index % 4 == 0,
                durationSeconds: index % 4 == 0 ? Double(8 + index) : 0,
                storageName: "Mock",
                thumbnail: nil
            )
            items.append(item)
        }
        update(items, nil)
    }

    func captureModelFrame() async throws -> CameraFrame {
        guard camera.connected else { throw FlightActionError.unavailable(camera.message) }
        tickCount += 1
        let frame = CameraFrame.simulator(sequence: tickCount)
        latestFrame = frame
        liveVideoTimestamp = frame.capturedAt
        telemetry.frameTimestamp = frame.capturedAt
        onFrame?(frame)
        return frame
    }

    func setRawSimulatorStateStore(_ store: RawSimulatorStateStore?) {
        rawSimulatorStateStore = store
        publishRawSimulatorStateToStore()
    }

    /// Mirrors the real DJI cold-start shape: encoded live-view packets are
    /// arriving before any on-demand model JPEG has been requested.
    func simulateRawVideoWithoutDecodedModelFrame(at timestamp: Date = Date()) {
        latestFrame = nil
        liveVideoTimestamp = timestamp
        onCamera?(camera)
    }

    func setSimulator(enabled: Bool) async throws {
        simulatorSetRequestsForTesting.append(enabled)
        if simulatorSetDelayNanosecondsForTesting > 0 {
            // Intentionally ignore cancellation: DJI SDK callbacks already in
            // flight cannot be cancelled by the app either.
            try? await Task.sleep(nanoseconds: simulatorSetDelayNanosecondsForTesting)
        }
        if !simulatorSetErrorsForTesting.isEmpty {
            throw simulatorSetErrorsForTesting.removeFirst()
        }
        if !enabled && (simulatorStatus.flying || simulatorStatus.motorsOn) {
            throw FlightActionError.unavailable("请先让仿真飞机降落")
        }
        simulatorStatus.active = enabled
        simulatorStatus.stateReceived = enabled && simulatorStartProducesRawForTesting
        simulatorStatus.originLatitudeDegrees = simulatorOrigin.latitude
        simulatorStatus.originLongitudeDegrees = simulatorOrigin.longitude
        simulatorStatus.sampleMonotonicNanoseconds = simulatorStatus.stateReceived
            ? DispatchTime.now().uptimeNanoseconds : 0
        simulatorStatus.message = enabled ? "Mock DJI 仿真已启动" : "Mock DJI 仿真已停止"
        telemetry.simulatorActive = enabled
        telemetry.positionSource = enabled ? "Mock DJI 仿真" : "Mock GPS"
        publishSimulatorStatus()
        publish()
    }

    func setSimulatorOrigin(_ point: GeoPoint) throws {
        guard point.latitude.isFinite, (-90...90).contains(point.latitude),
              point.longitude.isFinite, (-180...180).contains(point.longitude),
              abs(point.latitude) > 1e-9 || abs(point.longitude) > 1e-9 else {
            throw FlightActionError.unavailable("仿真起点必须是有效 WGS84 经纬度")
        }
        guard !simulatorStatus.active, !simulatorStatus.flying, !simulatorStatus.motorsOn else {
            throw FlightActionError.unavailable("请先关闭仿真器并保持电机停止")
        }
        simulatorStatus.originLatitudeDegrees = point.latitude
        simulatorStatus.originLongitudeDegrees = point.longitude
        simulatorOrigin = point
        simulatorStatus.message = String(format: "Mock 仿真起点已保存：%.6f, %.6f", point.latitude, point.longitude)
        publishSimulatorStatus()
    }

    func refreshSimulatorStateCallback() -> Bool {
        simulatorRefreshRequestCount += 1
        guard simulatorStatus.active else { return false }
        // Production installSimulatorDelegate() begins a new RAW session and
        // clears the old store before waiting for the new callback.
        rawSimulatorStateStore?.clear()
        simulatorStatus.stateReceived = false
        simulatorStatus.sampleMonotonicNanoseconds = 0
        publishSimulatorStatus()
        if simulatorRawPublishOnRefreshAttemptForTesting == simulatorRefreshRequestCount {
            simulatorStatus.stateReceived = true
            simulatorStatus.sampleMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
            simulatorStatus.message = "Mock DJI RAW callback 已恢复"
            publishSimulatorStatus()
        }
        return true
    }

    func configureSimulatorStatusForTesting(active: Bool, stateReceived: Bool) {
        simulatorStatus.active = active
        simulatorStatus.stateReceived = stateReceived
        simulatorStatus.motorsOn = false
        simulatorStatus.flying = false
        simulatorStatus.originLatitudeDegrees = telemetry.aircraft.latitude
        simulatorStatus.originLongitudeDegrees = telemetry.aircraft.longitude
        simulatorStatus.sampleMonotonicNanoseconds = active && stateReceived
            ? DispatchTime.now().uptimeNanoseconds : 0
        simulatorStatus.message = active
            ? (stateReceived ? "Mock DJI 仿真 RAW 已就绪" : "Mock DJI 仿真已激活但无 RAW")
            : "Mock DJI 仿真已停止"
        telemetry.simulatorActive = active
        telemetry.positionSource = active ? "Mock DJI 仿真" : "Mock GPS"
        publishSimulatorStatus()
        publish()
    }

    func configureSimulatorRawPublishOnRefreshAttemptForTesting(_ attempt: Int?) {
        simulatorRawPublishOnRefreshAttemptForTesting = attempt
    }

    func configureSimulatorStartProducesRawForTesting(_ enabled: Bool) {
        simulatorStartProducesRawForTesting = enabled
    }

    func configureSimulatorSetErrorsForTesting(_ errors: [Error]) {
        simulatorSetErrorsForTesting = errors
    }

    func configureSimulatorSetDelayForTesting(_ nanoseconds: UInt64) {
        simulatorSetDelayNanosecondsForTesting = nanoseconds
    }

    func simulateStaleMovingSimulatorRawForTesting(ageMilliseconds: UInt64 = 750) {
        simulatorStatus.active = true
        simulatorStatus.stateReceived = true
        simulatorStatus.motorsOn = true
        simulatorStatus.flying = true
        let ageNanoseconds = ageMilliseconds * 1_000_000
        let now = DispatchTime.now().uptimeNanoseconds
        simulatorStatus.sampleMonotonicNanoseconds = now > ageNanoseconds
            ? now - ageNanoseconds : 1
        simulatorStatus.message = "Mock DJI moving RAW stale"
        publishSimulatorStatus()
    }

    /// Mirrors the production provider's 100 Hz raw-store update that can
    /// arrive between its throttled 10 Hz SwiftUI snapshots.
    func simulateFreshRawWithoutUIPublishForTesting() {
        var raw = simulatorStatus
        raw.active = true
        raw.stateReceived = true
        raw.motorsOn = true
        raw.flying = true
        raw.sampleMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
        rawSimulatorStateStore?.submit(raw)
    }

    func simulateWarningForTesting(code: Int, title: String = "DJI diagnostic", detail: String? = nil) {
        telemetry.warnings = [FlightWarning(
            id: "mock-warning-\(code)",
            severity: .critical,
            title: title,
            detail: detail,
            code: code
        )]
        publish()
    }

    func simulateStaleFlightStateForTesting(ageSeconds: TimeInterval) {
        stale = true
        telemetry.timestamp = Date(timeIntervalSinceNow: -ageSeconds)
        telemetry.flightStateTimestamp = Date(timeIntervalSinceNow: -ageSeconds)
        onTelemetry?(telemetry)
    }

    func simulateDisconnect() {
        telemetry.connected.toggle()
        telemetry.mode = telemetry.connected ? .gps : .disconnected
        if !telemetry.connected { telemetry.flying = false; virtualStick = false; command = .zero }
        publish()
    }

    func simulateStaleTelemetry() { stale.toggle(); if stale { telemetry.timestamp = Date(timeIntervalSinceNow: -10) }; onTelemetry?(telemetry) }

    func simulateManualTakeover() {
        // Mirror the real provider: the hardware callback requests takeover;
        // FlightViewModel must explicitly disable Virtual Stick.
        command = .zero
        onManualTakeover?()
    }

    func simulateCameraError() {
        camera.connected.toggle()
        if !camera.connected { liveVideoTimestamp = nil }
        camera.message = camera.connected ? "相机已恢复（Mock）" : "相机连接异常（Mock）"
        onCamera?(camera)
    }

    private func tick() {
        guard telemetry.connected else { return }
        tickCount += 1
        if !stale {
            let now = Date()
            telemetry.timestamp = now
            telemetry.flightStateTimestamp = now
            telemetry.frameTimestamp = now
            if camera.connected { liveVideoTimestamp = now }
        }
        if simulatorStatus.active {
            simulatorStatus.stateReceived = true
            simulatorStatus.sampleMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
            simulatorStatus.measuredUpdateHz = 5
            publishSimulatorStatus()
        }
        if camera.recording && tickCount % 5 == 0 { camera.recordingSeconds += 1 }
        if camera.connected && !stale && tickCount % 5 == 0 {
            latestFrame = .simulator(sequence: tickCount / 5)
            latestFrame.map { onFrame?($0) }
        }

        if telemetry.mode == .landing {
            telemetry.verticalSpeed = -0.65
            telemetry.altitude = max(0, telemetry.altitude - 0.13)
            telemetry.asl = 4.2 + telemetry.altitude
            if telemetry.altitude <= 0.02 {
                telemetry.altitude = 0; telemetry.verticalSpeed = 0; telemetry.flying = false
                telemetry.mode = .gps; landingStarted = nil
                if simulatorStatus.active {
                    simulatorStatus.flying = false; simulatorStatus.motorsOn = false
                    simulatorStatus.message = "Mock DJI 仿真已着陆"
                    publishSimulatorStatus()
                }
            }
        } else if telemetry.mode == .returningHome {
            telemetry.horizontalSpeed = 1.8
            moveTowardHome(stepMeters: 0.36)
            if distanceMeters(telemetry.aircraft, telemetry.home) < 0.7 {
                telemetry.horizontalSpeed = 0; telemetry.mode = .gps; rthStarted = nil
            }
        } else if virtualStick && telemetry.flying {
            telemetry.horizontalSpeed = hypot(command.forward, command.right)
            telemetry.verticalSpeed = command.up
            telemetry.heading = normalized(telemetry.heading + command.yawRate * 0.2)
            telemetry.altitude = max(0.5, telemetry.altitude + command.up * 0.2)
            telemetry.asl = 4.2 + telemetry.altitude
            let heading = telemetry.heading * .pi / 180
            let north = command.forward * cos(heading) - command.right * sin(heading)
            let east = command.forward * sin(heading) + command.right * cos(heading)
            telemetry.velocityNorth = north
            telemetry.velocityEast = east
            telemetry.velocityDown = -command.up
            telemetry.aircraft.latitude += north * 0.2 / 111_111
            telemetry.aircraft.longitude += east * 0.2 / (111_111 * cos(telemetry.aircraft.latitude * .pi / 180))
            if simulatorStatus.active {
                // Mirror the Android-compatible HIL default pending the iOS
                // props-off A/B: positionX is north and positionY is east.
                simulatorStatus.positionX += north * 0.2
                simulatorStatus.positionY += east * 0.2
                simulatorStatus.positionZ -= command.up * 0.2
                simulatorStatus.sampleMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
                publishSimulatorStatus()
            }
        } else {
            telemetry.velocityNorth = 0
            telemetry.velocityEast = 0
            telemetry.velocityDown = 0
        }
        if tickCount % 300 == 0 { telemetry.aircraftBattery = max(5, telemetry.aircraftBattery - 1) }
        publish()
    }

    private func publish() {
        if !stale {
            let now = Date()
            telemetry.timestamp = now
            telemetry.flightStateTimestamp = now
        }
        onTelemetry?(telemetry)
        onCamera?(camera)
    }

    private func publishSimulatorStatus() {
        publishRawSimulatorStateToStore()
        onSimulator?(simulatorStatus)
    }

    private func publishRawSimulatorStateToStore() {
        guard simulatorStatus.active, simulatorStatus.stateReceived,
              simulatorStatus.sampleMonotonicNanoseconds > 0 else {
            rawSimulatorStateStore?.clear()
            return
        }
        rawSimulatorStateStore?.submit(simulatorStatus)
    }
    private func requireFlying() throws { guard telemetry.connected else { throw FlightActionError.disconnected }; guard telemetry.flying else { throw FlightActionError.notFlying } }
    private func normalized(_ value: Double) -> Double { var result = value.truncatingRemainder(dividingBy: 360); if result < 0 { result += 360 }; return result }
    private func distanceMeters(_ a: GeoPoint, _ b: GeoPoint) -> Double { hypot((a.latitude-b.latitude)*111_111, (a.longitude-b.longitude)*95_000) }
    private func moveTowardHome(stepMeters: Double) {
        let lat = telemetry.home.latitude - telemetry.aircraft.latitude
        let lon = telemetry.home.longitude - telemetry.aircraft.longitude
        let distance = max(0.001, hypot(lat * 111_111, lon * 95_000))
        telemetry.aircraft.latitude += lat * min(1, stepMeters / distance)
        telemetry.aircraft.longitude += lon * min(1, stepMeters / distance)
    }
}
