import Foundation
import Network

private struct HILReceivedFrame: Sendable {
    let sourceFormatCode: UInt16
    let sourceFrameID: UInt64
    let sourcePoseSequence: UInt64
    let capturePeerMonotonicNanoseconds: UInt64
    let width: Int
    let height: Int
    let payload: Data
}

private struct HILFrameParseResult: Sendable {
    var frames: [HILReceivedFrame] = []
    var protocolError: String?
}

/// Android V4 keeps complete image frames in an atomic latest-frame store and
/// only renders a status snapshot on the UI thread. TCP throughput must not
/// enqueue one MainActor/SwiftUI update per frame because the DJI control timer
/// also needs deterministic main-run-loop service.
private final class HILVirtualFrameStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        let frame: CameraFrame?
        let receivedAt: UInt64?
        let receivedFrames: UInt64
        let rejectedFrames: UInt64
        let measuredReceiveHz: Double
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var frameSequence = 0
    private var latestFrame: CameraFrame?
    private var latestReceivedAt: UInt64?
    private var lastAcceptedSourceFrameID: UInt64?
    private var receivedFrames: UInt64 = 0
    private var rejectedFrames: UInt64 = 0
    private var rateWindowStarted: UInt64 = 0
    private var rateWindowFrames: UInt64 = 0
    private var measuredReceiveHz = 0.0

    func reset(generation: UInt64) {
        lock.withLock {
            self.generation = generation
            latestFrame = nil
            latestReceivedAt = nil
            lastAcceptedSourceFrameID = nil
            receivedFrames = 0
            rejectedFrames = 0
            rateWindowStarted = 0
            rateWindowFrames = 0
            measuredReceiveHz = 0
        }
    }

    func offer(_ frames: [HILReceivedFrame], receivedAt: UInt64,
               receivedDate: Date, generation: UInt64) {
        lock.withLock {
            guard generation == self.generation else { return }
            for value in frames {
                if let previous = lastAcceptedSourceFrameID,
                   value.sourceFrameID <= previous {
                    rejectedFrames &+= 1
                    continue
                }
                lastAcceptedSourceFrameID = value.sourceFrameID
                receivedFrames &+= 1
                if rateWindowStarted == 0 { rateWindowStarted = receivedAt }
                rateWindowFrames &+= 1
                if receivedAt >= rateWindowStarted,
                   receivedAt - rateWindowStarted >= 1_000_000_000 {
                    measuredReceiveHz = Double(rateWindowFrames) * 1_000_000_000
                        / Double(receivedAt - rateWindowStarted)
                    rateWindowStarted = receivedAt
                    rateWindowFrames = 0
                }
                frameSequence &+= 1
                latestReceivedAt = receivedAt
                latestFrame = CameraFrame(
                    sequence: frameSequence, capturedAt: receivedDate,
                    jpeg: value.payload, width: value.width, height: value.height,
                    sourceFormat: value.sourceFormatCode == 2 ? "png" : "jpeg",
                    sourceFrameID: value.sourceFrameID,
                    sourcePoseSequence: value.sourcePoseSequence,
                    sourceCapturePeerMonotonicNanoseconds: value.capturePeerMonotonicNanoseconds
                )
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(frame: latestFrame, receivedAt: latestReceivedAt,
                     receivedFrames: receivedFrames, rejectedFrames: rejectedFrames,
                     measuredReceiveHz: measuredReceiveHz)
        }
    }
}

/// Invalidates the previous TCP stream as soon as Network.framework accepts a
/// replacement, without waiting for a potentially busy MainActor. Only the
/// already-authenticated UDP peer may reserve a new frame-stream generation.
private final class HILFrameConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var expectedPeerHost: String?
    private var generation: UInt64 = 0

    func setExpectedPeerHost(_ host: String?) {
        lock.withLock { expectedPeerHost = host.map(Self.canonicalHost) }
    }

    func reserve(peerHost: String) -> UInt64? {
        lock.withLock {
            guard let expectedPeerHost,
                  Self.canonicalHost(peerHost) == expectedPeerHost else { return nil }
            generation &+= 1
            return generation
        }
    }

    func invalidate() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        lock.withLock { candidate == generation }
    }

    private static func canonicalHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasPrefix("::ffff:") { host = String(host.dropFirst("::ffff:".count)) }
        if host == "localhost" || host == "::1" {
            return "127.0.0.1"
        }
        return host
    }
}

/// Network.framework invokes one receive completion per UDP datagram. At the
/// UE heartbeat rate, forwarding every completion through its own MainActor
/// `Task` creates an unbounded executor backlog whenever SwiftUI is briefly
/// busy. Keep one thread-safe mailbox per HIL session instead: safety EVENTs
/// remain individual packets, while heartbeat/ping/pong are validated in a
/// batch and their side effects are coalesced by the MainActor drain.
private final class HILInboundUDPBuffer: @unchecked Sendable {
    struct Packet: @unchecked Sendable {
        let data: Data
        let endpoint: NWEndpoint
        let receivedAt: UInt64
    }

    struct Batch: @unchecked Sendable {
        let packets: [Packet]
        let hasMore: Bool
    }

    private let lock = NSLock()
    private var active = false
    private var drainScheduled = false
    private var packets: [Packet] = []

    func start() {
        lock.withLock {
            active = true
            drainScheduled = false
            packets.removeAll(keepingCapacity: true)
        }
    }

    func stop() {
        lock.withLock {
            active = false
            drainScheduled = false
            packets.removeAll(keepingCapacity: true)
        }
    }

    func offer(_ packet: Packet) {
        lock.withLock {
            guard active else { return }
            packets.append(packet)
        }
    }

    /// Called by a fixed-rate transport timer, never by the packet completion.
    /// At most one MainActor drain may be pending at a time.
    func requestDrain() -> Bool {
        lock.withLock {
            guard active, !packets.isEmpty, !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
    }

    func takeBatch(limit: Int) -> Batch {
        lock.withLock {
            guard active, !packets.isEmpty else {
                drainScheduled = false
                return .init(packets: [], hasMore: false)
            }
            let count = min(max(1, limit), packets.count)
            let batch = Array(packets.prefix(count))
            packets.removeFirst(count)
            let hasMore = !packets.isEmpty
            if !hasMore { drainScheduled = false }
            return .init(packets: batch, hasMore: hasMore)
        }
    }
}

/// Android's `HilUdpTransport` keeps its 100 Hz pose and 50 Hz heartbeat work
/// on a dedicated scheduled executor.  Keep the identical UDP wire cadence off
/// the iOS MainActor as well; SwiftUI rendering must never delay or burst HIL
/// packets.  `NWConnection.send` is thread-safe and all mutable snapshots below
/// are protected by the lock.
private final class HILRealtimeUDPSender: @unchecked Sendable {
    struct Statistics {
        let sentPoseCount: UInt64
    }

    private let lock = NSLock()
    private var running = false
    private var sessionID: UInt64 = 0
    private var sequence: UInt64 = 0
    private var connection: NWConnection?
    private var targetReady = false
    private var latestPose: OpenFlyHILProtocol.Pose?
    private var lastReceivedSequence: UInt64 = 0
    private var sentPoseCount: UInt64 = 0
    private let rawSimulatorStateStore: RawSimulatorStateStore

    init(rawSimulatorStateStore: RawSimulatorStateStore) {
        self.rawSimulatorStateStore = rawSimulatorStateStore
    }

    func start(sessionID: UInt64) {
        lock.lock()
        running = true
        self.sessionID = sessionID
        sequence = 0
        connection = nil
        targetReady = false
        latestPose = nil
        lastReceivedSequence = 0
        sentPoseCount = 0
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        connection = nil
        targetReady = false
        latestPose = nil
        lastReceivedSequence = 0
        lock.unlock()
    }

    func updateConnection(_ connection: NWConnection?, ready: Bool) {
        lock.lock()
        self.connection = connection
        targetReady = ready && connection != nil
        lock.unlock()
    }

    func updatePose(_ pose: OpenFlyHILProtocol.Pose?) {
        lock.lock()
        latestPose = pose
        lock.unlock()
    }

    func noteReceived(sequence: UInt64) {
        lock.lock()
        lastReceivedSequence = sequence
        lock.unlock()
    }

    /// Allocating a sequence and submitting the datagram must be one serialized
    /// operation. POSE/heartbeat run on the UDP queue while PONG/HELLO can be
    /// requested by the receive/UI path; splitting `nextSequence` from `send`
    /// allowed packet N+1 to be submitted before N and made strict UE peers
    /// reject valid control-state updates.
    func sendHello(_ value: OpenFlyHILProtocol.Hello,
                   completion: (@Sendable (Error?) -> Void)? = nil) -> Data {
        lock.lock()
        sequence &+= 1
        let packet = OpenFlyHILProtocol.encodeHello(
            sessionID: sessionID,
            sequence: sequence,
            value: value
        )
        if running, targetReady, let connection {
            connection.send(content: packet, completion: .contentProcessed { error in
                completion?(error)
            })
        }
        lock.unlock()
        return packet
    }

    func sendPong(echoed: UInt64, peer: UInt64) {
        lock.lock()
        guard running, targetReady, let connection else {
            lock.unlock()
            return
        }
        sequence &+= 1
        let packet = OpenFlyHILProtocol.encodePong(
            sessionID: sessionID,
            sequence: sequence,
            echoed: echoed,
            peer: peer
        )
        connection.send(content: packet, completion: .contentProcessed { _ in })
        lock.unlock()
    }

    func sendPoseTick() {
        lock.lock()
        guard running, targetReady, let connection else {
            lock.unlock()
            return
        }

        // The raw store belongs to the DJI provider, not to this network
        // session. MSDK4 can publish one authoritative grounded sample before
        // HIL starts and then remain quiet until the motors change state. A new
        // HIL session must therefore be able to seed a zero-command POSE from
        // that provider snapshot without retaining the previous session's
        // telemetry, command, peer, or sequence state.
        let raw = rawSimulatorStateStore.latest()
        let now = DispatchTime.now().uptimeNanoseconds
        var pose: OpenFlyHILProtocol.Pose
        if let latestPose {
            pose = latestPose
        } else if let raw,
                  SimulatorRawStatePolicy.hasAuthoritativeSample(raw, now: now) {
            pose = Self.safeSessionSeed(from: raw)
        } else {
            lock.unlock()
            return
        }

        if let raw {
            // Match Android V4's grounded behavior by retransmitting the latest
            // stationary pose at the configured UDP rate. Once motors/flying
            // become true, share the existing 500 ms control freshness boundary
            // so UE never integrates a stale in-flight pose indefinitely.
            guard SimulatorRawStatePolicy.isReadyForControl(raw, now: now) else {
                lock.unlock()
                return
            }
            pose.sampleMonotonicNanoseconds = raw.sampleMonotonicNanoseconds
            // Keep Android V4 compatibility as the current default: X is north
            // and Y is east. DJI's iOS header prose conflicts with its own NED
            // wording, and this iOS mapping still needs the dedicated real-device
            // A/B acceptance. The 1 Hz diagnostic prints raw X/Y/yaw plus this
            // mapping label so that check is observable instead of assumed.
            pose.eastMeters = raw.positionY
            pose.northMeters = raw.positionX
            pose.upMeters = -raw.positionZ
            pose.rollDegrees = raw.rollDegrees
            pose.pitchDegrees = raw.pitchDegrees
            pose.headingDegreesClockwiseFromNorth = raw.yawDegrees
            pose.measuredSimulatorHz = Float(raw.measuredUpdateHz)
            pose.stateFlags &= 4
            if raw.motorsOn { pose.stateFlags |= 1 }
            if raw.flying { pose.stateFlags |= 2 }
            if !raw.motorsOn, !raw.flying {
                // A grounded RAW sample may live for the whole session, so it
                // must not keep an earlier airborne command/velocity alive.
                pose.velocityNorthMetersPerSecond = 0
                pose.velocityEastMetersPerSecond = 0
                pose.velocityUpMetersPerSecond = 0
                pose.commandForwardMetersPerSecond = 0
                pose.commandRightMetersPerSecond = 0
                pose.commandUpMetersPerSecond = 0
                pose.commandYawRateDegreesPerSecond = 0
            }
        } else if pose.stateFlags & 3 != 0 {
            // A moving pose without its provider-owned RAW snapshot is only
            // usable inside the same 500 ms fail-closed boundary. Grounded
            // samples deliberately remain reusable because MSDK4 can stay
            // silent until the motors transition.
            guard pose.sampleMonotonicNanoseconds > 0,
                  now >= pose.sampleMonotonicNanoseconds,
                  now - pose.sampleMonotonicNanoseconds
                    <= SimulatorRawStatePolicy.movingMaximumAgeNanoseconds else {
                lock.unlock()
                return
            }
        }
        sequence &+= 1
        let packet = OpenFlyHILProtocol.encodePose(
            sessionID: sessionID,
            sequence: sequence,
            value: pose
        )
        sentPoseCount &+= 1
        connection.send(content: packet, completion: .contentProcessed { _ in })
        lock.unlock()
    }

    /// Builds only the fields owned by the Simulator provider. Everything
    /// supplied by flight telemetry or a prior controller session is reset to
    /// a fail-closed value until `OpenFlyHILController.submit` refreshes it.
    private static func safeSessionSeed(
        from raw: FlightSimulatorStatus
    ) -> OpenFlyHILProtocol.Pose {
        var flags: UInt32 = 0
        if raw.motorsOn { flags |= 1 }
        if raw.flying { flags |= 2 }
        return .init(
            sampleMonotonicNanoseconds: raw.sampleMonotonicNanoseconds,
            originLatitudeDegrees: raw.originLatitudeDegrees,
            originLongitudeDegrees: raw.originLongitudeDegrees,
            eastMeters: raw.positionY,
            northMeters: raw.positionX,
            upMeters: -raw.positionZ,
            rollDegrees: raw.rollDegrees,
            pitchDegrees: raw.pitchDegrees,
            headingDegreesClockwiseFromNorth: raw.yawDegrees,
            velocityNorthMetersPerSecond: 0,
            velocityEastMetersPerSecond: 0,
            velocityUpMetersPerSecond: 0,
            gimbalPitchDegrees: 0,
            commandForwardMetersPerSecond: 0,
            commandRightMetersPerSecond: 0,
            commandUpMetersPerSecond: 0,
            commandYawRateDegreesPerSecond: 0,
            flightStateAgeMilliseconds: UInt32(Int32.max),
            measuredSimulatorHz: Float(raw.measuredUpdateHz),
            stateFlags: flags
        )
    }

    func sendHeartbeatTick() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard running, targetReady, let connection else {
            lock.unlock()
            return
        }
        sequence &+= 1
        let heartbeat = OpenFlyHILProtocol.encodeHeartbeat(
            sessionID: sessionID,
            sequence: sequence,
            monotonicNanoseconds: now,
            lastReceivedSequence: lastReceivedSequence
        )
        sequence &+= 1
        let ping = OpenFlyHILProtocol.encodePing(
            sessionID: sessionID,
            sequence: sequence,
            monotonicNanoseconds: now
        )
        connection.send(content: heartbeat, completion: .contentProcessed { _ in })
        connection.send(content: ping, completion: .contentProcessed { _ in })
        lock.unlock()
    }

    func statistics() -> Statistics {
        lock.lock()
        let value = Statistics(sentPoseCount: sentPoseCount)
        lock.unlock()
        return value
    }
}

@MainActor
final class OpenFlyHILController: ObservableObject {
    /// Android V4 only offers a UE frame to inference for two seconds, while
    /// the link monitor deliberately uses a slightly wider 2.5 s freshness
    /// window before starting its 5 s dropout grace period.
    static let virtualFrameInferenceFreshMilliseconds = 2_000.0
    static let virtualFrameFreshMilliseconds = 2_500.0
    static let virtualFrameStartupGraceMilliseconds = 15_000.0
    static let virtualFrameDropoutGraceMilliseconds = 5_000.0

    struct Configuration: Codable, Equatable {
        /// Match Android's first-run behavior: the phone provides the hotspot
        /// and discovers the UE peer without asking the user for an IP.
        var mode: HILConnectionMode = .hotspot
        var host = ""
        var hotspotDiscoveryMode: HILHotspotDiscoveryMode = .automatic
        var hotspotHost = ""
        var udpServerPort: UInt16 = 30_020
        var udpLocalPort: UInt16 = 30_021
        var frameTCPPort: UInt16 = 30_022
        var poseSendHz = 100
        var simulatorStateHz = 100
        var heartbeatTimeoutMilliseconds = 1_000
        var legacyDiscoveryHosts = (2...14).map { "172.20.10.\($0)" }

        func validate() throws {
            if mode == .lan, destinationHost == nil {
                throw SurveyValidationError.invalid("局域网模式需要 UE 主机地址")
            }
            if mode == .hotspot, hotspotDiscoveryMode == .manual, destinationHost == nil {
                throw SurveyValidationError.invalid("手动热点模式需要填写 UE 电脑获得的 IP")
            }
            guard (1...150).contains(poseSendHz), (2...150).contains(simulatorStateHz),
                  (250...10_000).contains(heartbeatTimeoutMilliseconds) else {
                throw SurveyValidationError.invalid("HIL 频率或失联超时参数无效")
            }
        }

        var destinationHost: String? {
            if mode == .hotspot, hotspotDiscoveryMode == .automatic { return nil }
            let value = (mode == .lan ? host : hotspotHost)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    struct Status: Equatable {
        var running = false; var peerHost: String?; var peerFresh = false
        var frameListening = false; var frameConnected = false
        var sentPoseCount: UInt64 = 0; var receivedPacketCount: UInt64 = 0
        var receivedFrameCount: UInt64 = 0
        var rejectedFrameCount: UInt64 = 0
        var measuredPoseSendHz = 0.0; var measuredFrameReceiveHz = 0.0
        var roundTripMilliseconds: Double?
        var latestFrameAgeMilliseconds: Double?; var message = "HIL 未启动"
        /// TCP image transport is independent from the UDP pose/link state.
        var frameMessage = "TCP 图像未连接"
    }

    private static let configurationDefaultsKey = "openfly.hil.configuration.v1"
    static let lastAutomaticPeerDefaultsKey = "openfly.hil.last-automatic-peer.v1"
    private let defaults: UserDefaults
    private let listensForFrames: Bool
    private var lastAutomaticPeerHost: String?

    @Published private(set) var status = Status()
    @Published var configuration: Configuration {
        didSet { persistConfiguration() }
    }
    @Published var useVirtualFrames = false {
        didSet {
            guard oldValue != useVirtualFrames else { return }
            resetVirtualFrameSafetyTracking(enabled: useVirtualFrames)
            onVirtualFrameModeChanged?(useVirtualFrames)
        }
    }
    @Published private(set) var latestVirtualFrame: CameraFrame?
    var onVirtualFrame: ((CameraFrame) -> Void)?
    var onSafetyEvent: ((OpenFlyHILProtocol.Event) -> Void)?
    var onSimulatorFrequencyRequested: ((Int) -> Void)?
    var onSimulatorStartRequested: (() -> Void)?
    var onVirtualFrameModeChanged: ((Bool) -> Void)?
    var onVirtualFrameSafetyFault: ((String) -> Void)?
    var shouldEnforceVirtualFrameSafety: (() -> Bool)?
    var onDiagnostic: ((String) -> Void)?

    /// Match Android V4's independent executors. Large TCP frame reads/CRC must
    /// never block the UDP SimulatorState/heartbeat scheduler.
    private let udpQueue = DispatchQueue(label: "com.openfly.go.hil.udp", qos: .userInteractive)
    private let frameQueue = DispatchQueue(label: "com.openfly.go.hil.frame", qos: .userInitiated)
    nonisolated let rawSimulatorStateStore: RawSimulatorStateStore
    private nonisolated let virtualFrameStore = HILVirtualFrameStore()
    private nonisolated let frameConnectionGate = HILFrameConnectionGate()
    private nonisolated let inboundUDPBuffer = HILInboundUDPBuffer()
    private let realtimeUDPSender: HILRealtimeUDPSender
    private var udpListener: NWListener?, udpConnection: NWConnection?, frameListener: NWListener?
    private var udpReconnectTask: Task<Void, Never>?
    private var udpConnectionGeneration: UInt64 = 0
    private var udpTargetStartedAt: UInt64?
    private var udpTargetReadyAt: UInt64?
    private var frameClientConnection: NWConnection?
    private var frameClientReconnectTask: Task<Void, Never>?
    private var frameClientConnectTimeoutTask: Task<Void, Never>?
    private var frameClientGeneration: UInt64 = 0
    private var bonjourBrowser: NWBrowser?
    private var legacyProbeConnections: [NWConnection] = []
    private var udpReceiveConnections: [NWConnection] = []
    private var frameConnections: [NWConnection] = []
    /// Both Android-compatible TCP roles remain available, but an authenticated
    /// UE-initiated stream wins a simultaneous-connect race. Otherwise a late
    /// outbound `.ready` callback can replace it and repeatedly reset frame IDs.
    private var activeFrameConnectionIsInbound = false
    private var poseTimer: DispatchSourceTimer?, heartbeatTimer: DispatchSourceTimer?
    private var inboundUDPDrainTimer: DispatchSourceTimer?, statusTimer: DispatchSourceTimer?
    private var sessionID = UInt64.random(in: .min ... .max)
    private var startedAt = DispatchTime.now().uptimeNanoseconds
    private var lastPeerPacket: UInt64?, lastHelloSentAt: UInt64 = 0
    private var lastReceivedSequence: UInt64 = 0
    private var receivedSequenceWindow: UInt64 = 0
    private var receivedPacketCount: UInt64 = 0
    private var latestRoundTripMilliseconds: Double?
    private var lastInvalidPacketReportAt: UInt64 = 0
    private var suppressedInvalidPacketCount: UInt64 = 0
    private var lastDiagnosticSummaryAt: UInt64 = 0
    private var diagnosticLastEmittedAt: [String: UInt64] = [:]
    private var latestFrameReceivedAt: UInt64?
    private var frameConnectionGeneration: UInt64 = 0
    private var udpTargetReady = false
    private var virtualFrameModeEnabledAt: UInt64?
    private var virtualFrameUnavailableSince: UInt64?
    private var virtualFrameEverReady = false
    private var virtualFrameFaultReported = false
    /// Internal observability for deterministic batching/reconnect regression
    /// tests. It is intentionally not Published and has no UI render cost.
    private(set) var inboundUDPDrainCount = 0
    private(set) var udpTransportGeneration: UInt64 = 0

    init(defaults: UserDefaults = .standard, listensForFrames: Bool = true) {
        let rawSimulatorStateStore = RawSimulatorStateStore()
        self.rawSimulatorStateStore = rawSimulatorStateStore
        realtimeUDPSender = HILRealtimeUDPSender(rawSimulatorStateStore: rawSimulatorStateStore)
        self.defaults = defaults
        self.listensForFrames = listensForFrames
        if let data = defaults.data(forKey: Self.configurationDefaultsKey),
           let restored = try? JSONDecoder().decode(Configuration.self, from: data) {
            configuration = restored
        } else {
            configuration = Configuration()
        }
        if let stored = defaults.string(forKey: Self.lastAutomaticPeerDefaultsKey) {
            lastAutomaticPeerHost = Self.canonicalAutomaticPeerHost(stored)
            if lastAutomaticPeerHost == nil {
                // Never keep malformed or hostname-like values in an automatic
                // Personal Hotspot cache. The fixed scan and Bonjour remain the
                // authoritative fallback paths.
                defaults.removeObject(forKey: Self.lastAutomaticPeerDefaultsKey)
            }
        }
    }

    private func persistConfiguration() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.configurationDefaultsKey)
    }

    func start() {
        stop(resetVirtualFrameSource: false)
        // Android V4 exposes one HIL frequency and uses it for both the raw
        // SimulatorState request and latest-pose sender. Normalize any older
        // iOS configuration that stored these independently.
        configuration.poseSendHz = configuration.simulatorStateHz
        do { try configuration.validate() }
        catch { status.message = error.localizedDescription; return }
        onSimulatorFrequencyRequested?(configuration.simulatorStateHz)
        sessionID = .random(in: .min ... .max)
        startedAt = DispatchTime.now().uptimeNanoseconds
        inboundUDPDrainCount = 0
        inboundUDPBuffer.start()
        realtimeUDPSender.start(sessionID: sessionID)
        status = .init(running: true, message: initialConnectionMessage)
        diagnose("启动 mode=\(configuration.mode.rawValue) discovery=\(configuration.hotspotDiscoveryMode.rawValue) udpLocal=\(configuration.udpLocalPort) udpServer=\(configuration.udpServerPort) frameTCP=\(configuration.frameTCPPort) poseHz=\(configuration.poseSendHz) simulatorHz=\(configuration.simulatorStateHz) targets=\(diagnosticTargets)")
        frameConnectionGate.setExpectedPeerHost(configuration.destinationHost)
        startUDPListener()
        if listensForFrames { startFrameListener() }
        else { status.frameMessage = "TCP 入站监听关闭；仅验证 Android 兼容主动连接" }
        if let destination = configuration.destinationHost { connectUDP(host: destination) }
        else { startAutomaticHotspotDiscovery() }
        startTimers()
        resetVirtualFrameSafetyTracking(enabled: useVirtualFrames)
        onSimulatorStartRequested?()
    }

    func stop() {
        stop(resetVirtualFrameSource: true)
    }

    private func stop(resetVirtualFrameSource: Bool) {
        // Flip the externally observed state before cancelling Network objects:
        // their asynchronous `.cancelled` callbacks must never resurrect an
        // explicitly stopped session.
        status.running = false
        inboundUDPBuffer.stop()
        if resetVirtualFrameSource, useVirtualFrames { useVirtualFrames = false }
        poseTimer?.cancel(); heartbeatTimer?.cancel(); inboundUDPDrainTimer?.cancel(); statusTimer?.cancel()
        poseTimer = nil; heartbeatTimer = nil; inboundUDPDrainTimer = nil; statusTimer = nil
        realtimeUDPSender.stop()
        udpReconnectTask?.cancel(); udpReconnectTask = nil
        udpConnectionGeneration &+= 1
        udpTargetStartedAt = nil
        udpTargetReadyAt = nil
        let stoppedUDPConnection = udpConnection
        udpConnection = nil
        udpListener?.cancel(); stoppedUDPConnection?.cancel(); frameListener?.cancel()
        frameClientReconnectTask?.cancel(); frameClientReconnectTask = nil
        frameClientConnectTimeoutTask?.cancel(); frameClientConnectTimeoutTask = nil
        frameClientGeneration &+= 1
        frameClientConnection?.cancel(); frameClientConnection = nil
        bonjourBrowser?.cancel(); bonjourBrowser = nil
        legacyProbeConnections.forEach { $0.cancel() }; legacyProbeConnections.removeAll()
        udpReceiveConnections.forEach { $0.cancel() }; udpReceiveConnections.removeAll()
        frameConnectionGeneration &+= 1
        frameConnectionGate.setExpectedPeerHost(nil)
        _ = frameConnectionGate.invalidate()
        frameConnections.forEach { $0.cancel() }; frameConnections.removeAll()
        activeFrameConnectionIsInbound = false
        udpListener = nil; frameListener = nil
        lastPeerPacket = nil; lastHelloSentAt = 0
        lastReceivedSequence = 0; receivedSequenceWindow = 0; receivedPacketCount = 0
        latestRoundTripMilliseconds = nil; latestFrameReceivedAt = nil
        lastInvalidPacketReportAt = 0; suppressedInvalidPacketCount = 0
        lastDiagnosticSummaryAt = 0; diagnosticLastEmittedAt.removeAll()
        virtualFrameStore.reset(generation: frameConnectionGeneration)
        latestVirtualFrame = nil
        udpTargetReady = false
        resetVirtualFrameSafetyTracking(enabled: false)
        status = .init(message: "HIL 已停止；UDP/TCP 监听端口已释放")
    }

    func submit(telemetry: FlightTelemetry, simulator: FlightSimulatorStatus,
                command: VelocityCommand = .zero) {
        guard status.running, simulator.active, simulator.stateReceived,
              simulator.sampleMonotonicNanoseconds > 0 else { return }
        var flags: UInt32 = 0
        if simulator.motorsOn { flags |= 1 }; if simulator.flying { flags |= 2 }
        if telemetry.virtualStickActive { flags |= 4 }
        realtimeUDPSender.updatePose(.init(sampleMonotonicNanoseconds: simulator.sampleMonotonicNanoseconds,
            originLatitudeDegrees: simulator.originLatitudeDegrees,
            originLongitudeDegrees: simulator.originLongitudeDegrees,
            // Keep the Android V4-compatible default: X = north, Y = east.
            // The iOS SDK header prose is internally inconsistent with its
            // stated NED coordinate system; the iOS mapping remains subject to
            // the documented props-off real-device A/B acceptance.
            eastMeters: simulator.positionY, northMeters: simulator.positionX, upMeters: -simulator.positionZ,
            rollDegrees: simulator.rollDegrees, pitchDegrees: simulator.pitchDegrees,
            headingDegreesClockwiseFromNorth: simulator.yawDegrees,
            velocityNorthMetersPerSecond: telemetry.velocityNorth,
            velocityEastMetersPerSecond: telemetry.velocityEast,
            velocityUpMetersPerSecond: -telemetry.velocityDown,
            gimbalPitchDegrees: telemetry.gimbalPitch,
            commandForwardMetersPerSecond: command.forward,
            commandRightMetersPerSecond: command.right,
            commandUpMetersPerSecond: command.up,
            commandYawRateDegreesPerSecond: command.yawRate,
            flightStateAgeMilliseconds: UInt32(min(UInt64(UInt32.max), UInt64(max(0, Date().timeIntervalSince(telemetry.flightStateTimestamp) * 1_000)))),
            measuredSimulatorHz: Float(simulator.measuredUpdateHz), stateFlags: flags))
    }

    var virtualFrameIsFresh: Bool {
        guard let receivedAt = virtualFrameStore.snapshot().receivedAt else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= receivedAt else { return false }
        return Double(now - receivedAt) / 1_000_000 <= Self.virtualFrameFreshMilliseconds
    }

    var virtualFrameIsFreshForInference: Bool {
        guard let receivedAt = virtualFrameStore.snapshot().receivedAt else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= receivedAt else { return false }
        return Double(now - receivedAt) / 1_000_000
            <= Self.virtualFrameInferenceFreshMilliseconds
    }

    func latestFreshVirtualFrame(maxAgeMilliseconds: Double) -> CameraFrame? {
        let snapshot = virtualFrameStore.snapshot()
        let now = DispatchTime.now().uptimeNanoseconds
        guard let receivedAt = snapshot.receivedAt, now >= receivedAt,
              Double(now - receivedAt) / 1_000_000 <= maxAgeMilliseconds else { return nil }
        return snapshot.frame
    }

    func requireFreshVirtualFrame() throws -> CameraFrame {
        guard status.running, status.peerFresh else {
            throw SurveyValidationError.invalid("UE HIL 心跳未就绪")
        }
        guard let frame = latestFreshVirtualFrame(
            maxAgeMilliseconds: Self.virtualFrameInferenceFreshMilliseconds
        ) else {
            throw SurveyValidationError.invalid("UE 虚拟相机帧未就绪或已超过 2 秒")
        }
        return frame
    }

    func reportSimulatorSource(_ message: String) {
        guard status.running else { return }
        status.message = message
    }

    private func startUDPListener(attempt: Int = 0) {
        do {
            let parameters = NWParameters.udp; parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: .init(rawValue: configuration.udpLocalPort)!)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.status.running, self.udpListener === listener else {
                        connection.cancel()
                        return
                    }
                    self.acceptUDP(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.udpListener === listener else { return }
                    switch state {
                    case .ready:
                        self.diagnose("UDP listener ready port=\(self.configuration.udpLocalPort)")
                    case let .waiting(error):
                        self.diagnose("UDP listener waiting error=\(error)", key: "udp-listener-waiting")
                    case let .failed(error):
                        listener.cancel()
                        self.udpListener = nil
                        self.diagnose("UDP listener failed error=\(error)")
                        if case .posix(.EADDRINUSE) = error, attempt < 10, self.status.running {
                            self.status.message = "UDP 端口正在释放，准备重试（\(attempt + 1)/10）"
                            let session = self.sessionID
                            Task { [weak self] in
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                guard let self, self.status.running, self.sessionID == session,
                                      self.udpListener == nil else { return }
                                self.startUDPListener(attempt: attempt + 1)
                            }
                        } else {
                            self.fail("UDP 监听失败：\(error)")
                        }
                    default: break
                    }
                }
            }
            listener.start(queue: udpQueue); udpListener = listener
        } catch { fail("UDP 监听失败：\(error.localizedDescription)") }
    }

    private func connectUDP(host: String) {
        connectUDP(endpoint: .hostPort(host: .init(host), port: .init(rawValue: configuration.udpServerPort)!))
    }

    private func connectUDP(endpoint: NWEndpoint) {
        guard status.running else { return }
        udpReconnectTask?.cancel(); udpReconnectTask = nil
        udpConnectionGeneration &+= 1
        udpTransportGeneration &+= 1
        let generation = udpConnectionGeneration
        let previousConnection = udpConnection
        udpConnection = nil
        previousConnection?.cancel()
        udpTargetStartedAt = DispatchTime.now().uptimeNanoseconds
        udpTargetReadyAt = nil
        udpTargetReady = false
        realtimeUDPSender.updateConnection(nil, ready: false)
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let connection = NWConnection(to: endpoint, using: parameters)
        udpConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.status.running,
                      self.udpConnectionGeneration == generation,
                      self.udpConnection === connection else { return }
                switch state {
                case .ready:
                    self.diagnose("UDP target ready endpoint=\(connection.endpoint)")
                    self.udpTargetReady = true
                    self.udpTargetReadyAt = DispatchTime.now().uptimeNanoseconds
                    self.realtimeUDPSender.updateConnection(connection, ready: true)
                    self.sendHello()
                case let .failed(error):
                    self.diagnose("UDP target failed endpoint=\(connection.endpoint) error=\(error)")
                    self.handleUDPTransportLoss(
                        reason: "connection-failed",
                        message: "UDP 连接失败，正在自动重建：\(error.localizedDescription)"
                    )
                case .cancelled:
                    self.diagnose("UDP target cancelled endpoint=\(connection.endpoint)")
                    self.handleUDPTransportLoss(
                        reason: "connection-cancelled",
                        message: "UDP 连接中断，正在自动重建"
                    )
                default: break
                }
            }
        }
        connection.start(queue: udpQueue)
        // A conforming UE replies to the sender endpoint. Receive on the
        // connected UDP flow as well as on the fixed 30021 listener; otherwise
        // automatic discovery succeeds once, then the locked session times out
        // as soon as it switches from the probe to this connection.
        receiveUDP(connection)
    }

    /// Tear down only the outbound UDP target and rebuild it inside the same
    /// HIL session. Automatic hotspot mode returns to concurrent Bonjour/fixed
    /// discovery; LAN and manual hotspot modes retry their explicit address.
    /// `stop()` invalidates the generation and cancels the task, so an explicit
    /// stop can never reconnect in the background.
    private func handleUDPTransportLoss(reason: String, message: String) {
        guard status.running else { return }
        let wasFresh = status.peerFresh
        if wasFresh {
            status.peerFresh = false
            disconnectFramePeer()
            if useVirtualFrames, shouldEnforceVirtualFrameSafety?() == true {
                onVirtualFrameSafetyFault?(message)
                useVirtualFrames = false
            }
        }
        status.peerHost = nil
        status.message = message
        lastPeerPacket = nil
        lastReceivedSequence = 0
        receivedSequenceWindow = 0
        latestRoundTripMilliseconds = nil
        frameConnectionGate.setExpectedPeerHost(nil)

        udpConnectionGeneration &+= 1
        let oldConnection = udpConnection
        udpConnection = nil
        udpTargetReady = false
        udpTargetStartedAt = nil
        udpTargetReadyAt = nil
        realtimeUDPSender.updateConnection(nil, ready: false)
        oldConnection?.cancel()
        bonjourBrowser?.cancel(); bonjourBrowser = nil
        legacyProbeConnections.forEach { $0.cancel() }
        legacyProbeConnections.removeAll()

        udpReconnectTask?.cancel()
        let session = sessionID
        udpReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self, self.status.running,
                  self.sessionID == session else { return }
            self.udpReconnectTask = nil
            self.diagnose("UDP transport rebuild reason=\(reason)")
            if self.configuration.mode == .hotspot,
               self.configuration.hotspotDiscoveryMode == .automatic {
                self.status.message = "热点 UE 失联，正在自动重新发现"
                self.startAutomaticHotspotDiscovery()
            } else if let destination = self.configuration.destinationHost {
                self.status.message = self.configuration.mode == .lan
                    ? "局域网 UE 失联，正在按原 IP 重连"
                    : "热点 UE 失联，正在按已填 IP 重连"
                self.connectUDP(host: destination)
            }
        }
    }

    private var initialConnectionMessage: String {
        if configuration.mode == .lan {
            return "正在连接局域网 UE：\(configuration.destinationHost ?? "--")"
        }
        if configuration.hotspotDiscoveryMode == .automatic { return "正在自动发现热点 UE（兼容旧版 HELLO）" }
        return "正在连接热点 UE：\(configuration.destinationHost ?? "--")"
    }

    private func startAutomaticHotspotDiscovery() {
        startBonjourDiscovery()
        startLegacyHotspotDiscovery()
    }

    /// A remembered, authenticated hotspot IPv4 address is only a first probe,
    /// never an exclusive route. All configured legacy candidates are retained
    /// and Bonjour runs in parallel, so a stale cache cannot trap rediscovery.
    var automaticHotspotProbeHosts: [String] {
        guard configuration.mode == .hotspot,
              configuration.hotspotDiscoveryMode == .automatic else { return [] }
        var hosts: [String] = []
        var identities = Set<String>()
        func append(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let identity = Self.canonicalAutomaticPeerHost(trimmed)
                ?? trimmed.lowercased()
            guard identities.insert(identity).inserted else { return }
            hosts.append(trimmed)
        }
        if let lastAutomaticPeerHost { append(lastAutomaticPeerHost) }
        configuration.legacyDiscoveryHosts.forEach(append)
        return hosts
    }

    private func startBonjourDiscovery() {
        bonjourBrowser?.cancel()
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_openfly-hil._udp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.diagnose("Bonjour browser ready service=_openfly-hil._udp")
                case let .waiting(error):
                    self.diagnose("Bonjour browser waiting error=\(error)", key: "bonjour-waiting")
                case let .failed(error):
                    self.diagnose("Bonjour browser failed error=\(error)")
                    self.fail("Bonjour 自动发现失败：\(error)")
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let endpoint = results.map(\.endpoint).sorted(by: {
                String(describing: $0) < String(describing: $1)
            }).first else { return }
            Task { @MainActor in
                guard let self, self.status.running, !self.udpTargetReady else { return }
                self.diagnose("Bonjour discovered endpoint=\(endpoint)")
                self.status.message = "Bonjour 已发现 UE，正在建立 HIL 会话"
                self.connectUDP(endpoint: endpoint)
            }
        }
        browser.start(queue: udpQueue)
        bonjourBrowser = browser
    }

    /// Existing Android UE adapters discover the phone from OFHL HELLO packets on UDP 30020.
    /// Raw broadcast needs Apple's restricted multicast entitlement, so iOS probes the small
    /// Personal Hotspot client range with the identical v1 datagram. The wire protocol and
    /// the UE reply port (30021) stay unchanged.
    private func startLegacyHotspotDiscovery() {
        legacyProbeConnections.forEach { $0.cancel() }
        legacyProbeConnections = automaticHotspotProbeHosts.map { host in
            let endpoint = NWEndpoint.hostPort(
                host: .init(host),
                port: .init(rawValue: configuration.udpServerPort)!
            )
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(to: endpoint, using: parameters)
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.status.running,
                          self.legacyProbeConnections.contains(where: { $0 === connection }) else { return }
                    switch state {
                    case .ready:
                        self.diagnose("UDP probe ready endpoint=\(endpoint)")
                    case let .waiting(error):
                        self.diagnose("UDP probe waiting endpoint=\(endpoint) error=\(error)",
                                      key: "probe-waiting-\(endpoint)")
                    case let .failed(error):
                        self.diagnose("UDP probe failed endpoint=\(endpoint) error=\(error)",
                                      key: "probe-failed-\(endpoint)")
                    default: break
                    }
                }
            }
            connection.start(queue: udpQueue)
            // Android V4 sends HELLO from the same UDP socket that receives
            // the UE reply. Network.framework gives each unicast probe its
            // own source endpoint; a UE that correctly replies to the HELLO
            // source therefore sends the response back on this connection,
            // not necessarily to the separate 30021 listener. Receive on both
            // paths so the iOS unicast fallback preserves Android's socket
            // semantics instead of silently discarding discovery replies.
            receiveUDP(connection)
            return connection
        }
    }

    private func acceptUDP(_ connection: NWConnection) {
        diagnose("UDP listener accepted endpoint=\(connection.endpoint)")
        udpReceiveConnections.append(connection); connection.start(queue: udpQueue)
        receiveUDP(connection)
    }

    private nonisolated func receiveUDP(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            if error == nil { self?.receiveUDP(connection) }
            guard let self else { return }
            if let data {
                self.inboundUDPBuffer.offer(.init(
                    data: data, endpoint: connection.endpoint, receivedAt: receivedAt
                ))
            }
            if let error {
                Task { @MainActor [weak self] in
                    self?.diagnose("UDP receive failed endpoint=\(connection.endpoint) error=\(error)",
                                   key: "receive-error-\(connection.endpoint)")
                }
            }
        }
    }

    private func drainInboundUDP() {
        guard status.running else {
            inboundUDPBuffer.stop()
            return
        }
        let batch = inboundUDPBuffer.takeBatch(limit: 512)
        guard !batch.packets.isEmpty else { return }
        inboundUDPDrainCount &+= 1
        handleUDPBatch(batch.packets)
        if batch.hasMore {
            // Bound one MainActor turn under an EVENT burst, then yield without
            // falling back to one task per datagram.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.drainInboundUDP()
            }
        }
    }

    /// Validate every accepted sequence and preserve every EVENT, but publish
    /// link state once per receive batch. Heartbeats need no individual side
    /// effect; PING/PONG collapse to the newest valid response/RTT in the batch.
    private func handleUDPBatch(_ packets: [HILInboundUDPBuffer.Packet]) {
        guard status.running else { return }
        var nextStatus = status
        var automaticPeerToLock: (host: String, type: OpenFlyHILProtocol.MessageType)?
        var acceptedPeerHost: String?
        var latestPing: (echoed: UInt64, receivedAt: UInt64)?
        var latestPong: (echoed: UInt64, receivedAt: UInt64)?
        var acceptedAny = false

        // The mailbox append order is the receive-completion order. Keep it so
        // multiple safety EVENTs retain their original order even if two clock
        // reads happen to return the same nanosecond value.
        for packet in packets {
            do {
                let datagram = try OpenFlyHILProtocol.decode(packet.data)
                guard datagram.header.sessionID == sessionID else {
                    diagnose("UDP rejected endpoint=\(packet.endpoint) reason=session-mismatch type=\(datagram.header.type)",
                             key: "reject-session-\(packet.endpoint)")
                    continue
                }
                guard datagram.header.flags == 0 else {
                    throw SurveyValidationError.invalid("unsupported HIL header flags")
                }
                let inbound = try validateInbound(datagram)
                guard let discovered = endpointHost(packet.endpoint) else {
                    diagnose("UDP rejected endpoint=\(packet.endpoint) reason=missing-host", key: "reject-host")
                    continue
                }
                guard acceptPeer(discovered, currentPeer: nextStatus.peerHost) else {
                    diagnose("UDP rejected endpoint=\(packet.endpoint) reason=peer-mismatch current=\(nextStatus.peerHost ?? "none")",
                             key: "reject-peer-\(discovered)")
                    continue
                }
                let isSafetyEvent: Bool
                if case .event = inbound { isSafetyEvent = true }
                else { isSafetyEvent = false }
                if !isSafetyEvent {
                    let publishedAt = DispatchTime.now().uptimeNanoseconds
                    guard publishedAt >= packet.receivedAt,
                          publishedAt - packet.receivedAt
                            <= UInt64(configuration.heartbeatTimeoutMilliseconds) * 1_000_000 else {
                        diagnose("UDP rejected endpoint=\(packet.endpoint) reason=main-actor-delay", key: "reject-delay")
                        continue
                    }
                    if let previous = lastPeerPacket, packet.receivedAt < previous { continue }
                }
                guard acceptInboundSequence(datagram.header.sequence) else {
                    diagnose("UDP rejected endpoint=\(packet.endpoint) reason=replay sequence=\(datagram.header.sequence)",
                             key: "reject-sequence-\(discovered)")
                    continue
                }
                receivedPacketCount &+= 1
                acceptedAny = true
                diagnose("UDP received endpoint=\(packet.endpoint) type=\(datagram.header.type) sequence=\(datagram.header.sequence)",
                         key: "receive-\(discovered)-\(datagram.header.type)")
                if case let .event(event) = inbound {
                    // EVENT is never age-gated or coalesced: a UI stall must not
                    // hide a collision/stop/emergency. It still passes session,
                    // peer and replay validation above, but never refreshes the
                    // heartbeat age or locks a newly discovered peer.
                    onSafetyEvent?(event)
                    guard status.running else { return }
                    continue
                }
                if nextStatus.peerHost == nil,
                   configuration.mode == .hotspot,
                   configuration.hotspotDiscoveryMode == .automatic {
                    automaticPeerToLock = (discovered, datagram.header.type)
                }
                lastPeerPacket = packet.receivedAt
                nextStatus.peerFresh = true
                nextStatus.peerHost = discovered
                acceptedPeerHost = discovered
                switch inbound {
                case let .ping(echoed):
                    latestPing = (echoed, packet.receivedAt)
                case let .pong(echoed):
                    latestPong = (echoed, packet.receivedAt)
                case .event:
                    break // handled above without refreshing link freshness
                case .heartbeat:
                    break
                }
            } catch {
                reportInvalidPacket(error, into: &nextStatus)
            }
        }

        if let latestPong, latestPong.receivedAt >= latestPong.echoed {
            latestRoundTripMilliseconds = Double(latestPong.receivedAt - latestPong.echoed) / 1_000_000
        }
        nextStatus.receivedPacketCount = receivedPacketCount
        nextStatus.roundTripMilliseconds = latestRoundTripMilliseconds
        if nextStatus != status { status = nextStatus }
        if acceptedAny { realtimeUDPSender.noteReceived(sequence: lastReceivedSequence) }
        if let automaticPeerToLock {
            diagnose("UDP peer lock host=\(automaticPeerToLock.host) type=\(automaticPeerToLock.type)")
            lockAutomaticPeer(automaticPeerToLock.host)
        }
        if let acceptedPeerHost { ensureFrameClient(host: acceptedPeerHost) }
        if let latestPing {
            realtimeUDPSender.sendPong(echoed: latestPing.echoed, peer: latestPing.receivedAt)
        }
    }

    private enum ValidatedInbound {
        case heartbeat
        case ping(UInt64)
        case pong(UInt64)
        case event(OpenFlyHILProtocol.Event)
    }

    private func validateInbound(_ datagram: OpenFlyHILProtocol.Datagram) throws -> ValidatedInbound {
        switch datagram.header.type {
        case .heartbeat:
            guard datagram.payload.count == 24 else {
                throw SurveyValidationError.invalid("invalid heartbeat payload")
            }
            return .heartbeat
        case .ping:
            guard datagram.payload.count == 8 else {
                throw SurveyValidationError.invalid("invalid ping payload")
            }
            let echoed = datagram.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
            return .ping(echoed)
        case .pong:
            guard datagram.payload.count == 16 else {
                throw SurveyValidationError.invalid("invalid pong payload")
            }
            let echoed = datagram.payload.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
            return .pong(echoed)
        case .event:
            return .event(try OpenFlyHILProtocol.decodeEvent(datagram.payload))
        case .hello, .pose:
            throw SurveyValidationError.invalid("unexpected inbound HIL type \(datagram.header.type)")
        }
    }

    private func reportInvalidPacket(_ error: Error, into statusSnapshot: inout Status) {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastInvalidPacketReportAt != 0,
           now >= lastInvalidPacketReportAt,
           now - lastInvalidPacketReportAt < 2_000_000_000 {
            suppressedInvalidPacketCount &+= 1
            return
        }
        let suffix = suppressedInvalidPacketCount > 0
            ? "（已抑制 \(suppressedInvalidPacketCount) 条重复错误）" : ""
        statusSnapshot.message = "丢弃无效 HIL 包：\(error.localizedDescription)\(suffix)"
        diagnose("UDP rejected reason=decode-or-payload error=\(error.localizedDescription)\(suffix)")
        lastInvalidPacketReportAt = now
        suppressedInvalidPacketCount = 0
    }

    private func acceptPeer(_ host: String, currentPeer: String? = nil) -> Bool {
        if let peer = currentPeer ?? status.peerHost { return peer == host }
        guard let configured = configuration.destinationHost else {
            return configuration.mode == .hotspot && configuration.hotspotDiscoveryMode == .automatic
        }
        // The UI contract asks for an IP. Keep localhost aliases convenient for
        // simulator regression without weakening the first-session peer lock.
        if configured == "localhost" { return host == "127.0.0.1" || host == "::1" }
        return canonicalHost(configured) == canonicalHost(host)
    }

    private func endpointHost(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return canonicalHost("\(host)")
    }

    private func canonicalHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasPrefix("::ffff:") { host = String(host.dropFirst("::ffff:".count)) }
        return host == "localhost" || host == "::1" ? "127.0.0.1" : host
    }

    private static func canonicalAutomaticPeerHost(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.hasPrefix("::ffff:") { host = String(host.dropFirst("::ffff:".count)) }
        guard let address = IPv4Address(host) else { return nil }
        return String(describing: address)
    }

    private func rememberAutomaticPeer(_ host: String) {
        guard configuration.mode == .hotspot,
              configuration.hotspotDiscoveryMode == .automatic,
              let canonical = Self.canonicalAutomaticPeerHost(host) else { return }
        lastAutomaticPeerHost = canonical
        defaults.set(canonical, forKey: Self.lastAutomaticPeerDefaultsKey)
    }

    private func lockAutomaticPeer(_ host: String) {
        rememberAutomaticPeer(host)
        bonjourBrowser?.cancel(); bonjourBrowser = nil
        legacyProbeConnections.forEach { $0.cancel() }; legacyProbeConnections.removeAll()
        connectUDP(host: host)
        frameConnectionGate.setExpectedPeerHost(host)
        status.message = "已自动锁定 UE：\(host)"
    }

    private func startTimers() {
        let pose = DispatchSource.makeTimerSource(queue: udpQueue)
        pose.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / configuration.poseSendHz), leeway: .microseconds(200))
        pose.setEventHandler { [weak realtimeUDPSender] in realtimeUDPSender?.sendPoseTick() }
        pose.resume(); poseTimer = pose
        let heartbeat = DispatchSource.makeTimerSource(queue: udpQueue)
        heartbeat.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        heartbeat.setEventHandler { [weak realtimeUDPSender] in realtimeUDPSender?.sendHeartbeatTick() }
        heartbeat.resume(); heartbeatTimer = heartbeat
        let inbound = DispatchSource.makeTimerSource(queue: udpQueue)
        inbound.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        inbound.setEventHandler { [weak self] in
            guard let self, self.inboundUDPBuffer.requestDrain() else { return }
            Task { @MainActor [weak self] in self?.drainInboundUDP() }
        }
        inbound.resume(); inboundUDPDrainTimer = inbound
        let status = DispatchSource.makeTimerSource(queue: udpQueue)
        status.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(5))
        status.setEventHandler { [weak self] in
            Task { @MainActor in self?.updateLinkStatus() }
        }
        status.resume(); statusTimer = status
    }

    private func updateLinkStatus() {
        guard status.running else { return }
        var nextStatus = status
        publishVirtualFrameSnapshot(into: &nextStatus)
        let realtimeStatistics = realtimeUDPSender.statistics()
        nextStatus.sentPoseCount = realtimeStatistics.sentPoseCount
        nextStatus.receivedPacketCount = receivedPacketCount
        nextStatus.roundTripMilliseconds = latestRoundTripMilliseconds
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1e9
        nextStatus.measuredPoseSendHz = Double(nextStatus.sentPoseCount) / max(seconds, 0.001)
        let now = DispatchTime.now().uptimeNanoseconds
        if !nextStatus.peerFresh, now - lastHelloSentAt >= 100_000_000 { sendHello() }
        let peerTimedOut = lastPeerPacket.map {
            now - $0 > UInt64(configuration.heartbeatTimeoutMilliseconds) * 1_000_000
        } ?? false
        let handshakeTimeoutNanoseconds = max(
            1_000_000_000,
            UInt64(configuration.heartbeatTimeoutMilliseconds) * 2_000_000
        )
        let handshakeTimedOut = udpTargetReady && lastPeerPacket == nil
            && udpTargetReadyAt.map { now >= $0 && now - $0 > handshakeTimeoutNanoseconds } == true
        let connectionReadyTimedOut = !udpTargetReady && udpConnection != nil
            && udpTargetStartedAt.map { now >= $0 && now - $0 > handshakeTimeoutNanoseconds } == true
        // Publish one coherent 10 Hz status snapshot instead of emitting an
        // ObservableObject invalidation for every individual counter/age.
        // The HIL settings page observes this controller directly, so the old
        // per-field mutations caused dozens of redundant SwiftUI passes/sec.
        if nextStatus != status { status = nextStatus }
        if peerTimedOut {
            let staleMessage = configuration.mode == .hotspot
                ? (configuration.hotspotDiscoveryMode == .automatic
                   ? "热点 UE 失联，正在自动重新发现" : "热点 UE 失联，按已填 IP 重连")
                : "局域网 UE 心跳超时，正在按原 IP 重连"
            diagnose("UDP peer timeout host=\(status.peerHost ?? "none") received=\(receivedPacketCount)")
            // Clear the replay baseline only after a real watchdog transition.
            // The rebuilt connection can then accept a UE process whose reply
            // sequence restarted at one without restarting the phone session.
            handleUDPTransportLoss(reason: "heartbeat-timeout", message: staleMessage)
        } else if handshakeTimedOut {
            diagnose("UDP peer handshake timeout endpoint=\(udpConnection.map { String(describing: $0.endpoint) } ?? "none")")
            handleUDPTransportLoss(
                reason: "handshake-timeout",
                message: configuration.mode == .lan
                    ? "局域网 UE 握手超时，正在按原 IP 重连"
                    : "热点 UE 握手超时，正在自动恢复"
            )
        } else if connectionReadyTimedOut {
            diagnose("UDP target ready timeout endpoint=\(udpConnection.map { String(describing: $0.endpoint) } ?? "none")")
            handleUDPTransportLoss(
                reason: "connection-ready-timeout",
                message: configuration.mode == .lan
                    ? "局域网 UDP 连接未就绪，正在按原 IP 重建"
                    : "热点 UDP 连接未就绪，正在自动恢复"
            )
        }
        if now - lastDiagnosticSummaryAt >= 1_000_000_000 {
            lastDiagnosticSummaryAt = now
            let summaryStatus = status
            let rawAge: String
            let rawPosition: String
            if let raw = rawSimulatorStateStore.latest(), now >= raw.sampleMonotonicNanoseconds {
                rawAge = String(format: "%.0f", Double(now - raw.sampleMonotonicNanoseconds) / 1_000_000)
                rawPosition = String(
                    format: "rawX=%.3f rawY=%.3f rawYaw=%.2f mapping=android-compat(X->N,Y->E)",
                    raw.positionX, raw.positionY, raw.yawDegrees
                )
            } else {
                rawAge = "none"
                rawPosition = "rawX=none rawY=none rawYaw=none mapping=android-compat(X->N,Y->E)"
            }
            diagnose(String(format: "UDP summary peer=%@ fresh=%@ targetReady=%@ sentPose=%llu sendHz=%.1f received=%llu rawAgeMs=%@ %@",
                            summaryStatus.peerHost ?? "none", summaryStatus.peerFresh.description,
                            udpTargetReady.description, summaryStatus.sentPoseCount,
                            summaryStatus.measuredPoseSendHz, summaryStatus.receivedPacketCount, rawAge,
                            rawPosition))
        }
        monitorVirtualFrameSafety(now: now)
    }

    /// UDP may legitimately reorder adjacent datagrams even when the sender's
    /// sequence is monotonic. Android V4 accepts those packets; a strict
    /// `sequence > previous` check made iOS report bursts of false rejections.
    /// Keep a 64-packet replay window: unique reordered packets are accepted,
    /// while duplicates and packets older than the window cannot refresh the
    /// authenticated heartbeat or replay a safety EVENT.
    private func acceptInboundSequence(_ sequence: UInt64) -> Bool {
        guard receivedSequenceWindow != 0 else {
            lastReceivedSequence = sequence
            receivedSequenceWindow = 1
            return true
        }
        if sequence > lastReceivedSequence {
            let delta = sequence - lastReceivedSequence
            receivedSequenceWindow = delta >= 64
                ? 1
                : (receivedSequenceWindow << Int(delta)) | 1
            lastReceivedSequence = sequence
            return true
        }
        let delta = lastReceivedSequence - sequence
        guard delta < 64 else { return false }
        let mask = UInt64(1) << Int(delta)
        guard receivedSequenceWindow & mask == 0 else { return false }
        receivedSequenceWindow |= mask
        return true
    }

    private func sendHello() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard udpTargetReady || !legacyProbeConnections.isEmpty else { return }
        lastHelloSentAt = now
        let hello = OpenFlyHILProtocol.Hello(monotonicNanoseconds: now,
            requestedPoseHz: UInt32(configuration.poseSendHz), simulatorStateHz: UInt32(configuration.simulatorStateHz),
            frameTCPPort: UInt32(configuration.frameTCPPort), capabilities: 3)
        let packet = realtimeUDPSender.sendHello(hello) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.diagnose("HELLO send failed path=target error=\(error)", key: "hello-target-error")
            }
        }
        legacyProbeConnections.forEach { connection in
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.diagnose("HELLO send failed path=probe endpoint=\(connection.endpoint) error=\(error)",
                                   key: "hello-probe-error-\(connection.endpoint)")
                }
            })
        }
    }

    private var diagnosticTargets: String {
        if let destination = configuration.destinationHost { return destination }
        return automaticHotspotProbeHosts.joined(separator: ",")
    }

    private func diagnose(_ message: String, key: String? = nil,
                          minimumIntervalNanoseconds: UInt64 = 1_000_000_000) {
        let now = DispatchTime.now().uptimeNanoseconds
        if let key, let previous = diagnosticLastEmittedAt[key],
           now >= previous, now - previous < minimumIntervalNanoseconds { return }
        if let key { diagnosticLastEmittedAt[key] = now }
        onDiagnostic?(message)
    }

    private func startFrameListener(attempt: Int = 0) {
        do {
            let parameters = frameTCPParameters()
            let listener = try NWListener(using: parameters, on: .init(rawValue: configuration.frameTCPPort)!)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self,
                      let received = Self.endpointHostNonisolated(connection.endpoint),
                      let generation = self.frameConnectionGate.reserve(peerHost: received) else {
                    connection.cancel()
                    return
                }
                Task { @MainActor in
                    guard self.status.running, self.frameListener === listener else {
                        connection.cancel()
                        return
                    }
                    self.acceptFrames(connection, reservedGeneration: generation)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.frameListener === listener else { return }
                    if case .ready = state {
                        self.status.frameListening = true
                        if !self.status.frameConnected {
                            self.status.frameMessage = "TCP 入站已监听，等待 UE；UDP 位姿独立运行"
                        }
                    }
                    if case let .failed(error) = state {
                        listener.cancel()
                        self.frameListener = nil
                        self.status.frameListening = false
                        if case .posix(.EADDRINUSE) = error, attempt < 10, self.status.running {
                            self.status.frameMessage = "图像端口正在释放，准备重试（\(attempt + 1)/10）"
                            let session = self.sessionID
                            Task { [weak self] in
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                guard let self, self.status.running, self.sessionID == session,
                                      self.frameListener == nil else { return }
                                self.startFrameListener(attempt: attempt + 1)
                            }
                        } else {
                            self.status.frameMessage = "虚拟相机监听失败：\(error)"
                        }
                    }
                }
            }
            listener.start(queue: frameQueue); frameListener = listener
        } catch { status.frameMessage = "虚拟相机监听失败：\(error.localizedDescription)" }
    }

    private func acceptFrames(_ connection: NWConnection, reservedGeneration: UInt64) {
        activateFrameConnection(connection, alreadyStarted: false, direction: "TCP入站",
                                isInbound: true, reservedGeneration: reservedGeneration)
    }

    /// Android V4 listens on 30022 and also connects to the authenticated UE
    /// peer's 30022. Existing UE builds use either role, so keep both paths.
    private func ensureFrameClient(host: String) {
        guard status.running, status.peerFresh, status.peerHost == host,
              !status.frameConnected, frameClientConnection == nil else { return }
        // A localhost integration test (and Mac-hosted simulator preview) can
        // expose the phone-side listener through loopback.  Connecting the
        // active client back to our own listener creates two ends of the same
        // socket, each of which replaces the other and starts a reconnect
        // storm.  Real UE peers have a remote address; outbound-only tests can
        // explicitly disable the listener and still exercise that role.
        guard !listensForFrames || !isLoopbackHost(host) else { return }
        frameClientReconnectTask?.cancel(); frameClientReconnectTask = nil
        frameClientGeneration &+= 1
        let generation = frameClientGeneration
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: configuration.frameTCPPort)!,
            using: frameTCPParameters()
        )
        frameClientConnection = connection
        status.frameMessage = "TCP主动连接 \(host):\(configuration.frameTCPPort)…"
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.status.running,
                      self.frameClientGeneration == generation,
                      self.frameClientConnection === connection else { return }
                switch state {
                case .ready:
                    self.frameClientConnectTimeoutTask?.cancel()
                    self.frameClientConnectTimeoutTask = nil
                    if self.status.frameConnected, self.activeFrameConnectionIsInbound {
                        self.frameClientConnection = nil
                        connection.cancel()
                        return
                    }
                    self.activateFrameConnection(connection, alreadyStarted: true,
                                                 direction: "TCP主动", isInbound: false)
                case let .failed(error):
                    self.frameClientConnectTimeoutTask?.cancel()
                    self.frameClientConnectTimeoutTask = nil
                    self.frameClientConnection = nil
                    self.status.frameMessage = "TCP主动等待 UE：\(error.localizedDescription)"
                    self.scheduleFrameClientReconnect(host: host)
                case .cancelled:
                    if !self.status.frameConnected { self.frameClientConnection = nil }
                default: break
                }
            }
        }
        connection.start(queue: frameQueue)
        frameClientConnectTimeoutTask?.cancel()
        frameClientConnectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.status.running,
                  self.frameClientGeneration == generation,
                  self.frameClientConnection === connection,
                  !self.status.frameConnected else { return }
            self.frameClientConnection = nil
            connection.cancel()
            self.status.frameMessage = "TCP主动连接超时，500 ms 后重试；UDP 位姿不受影响"
            self.scheduleFrameClientReconnect(host: host)
        }
    }

    private func scheduleFrameClientReconnect(host: String) {
        guard status.running, status.peerFresh, status.peerHost == host,
              !status.frameConnected else { return }
        frameClientReconnectTask?.cancel()
        let generation = frameClientGeneration
        frameClientReconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self, self.status.running,
                  self.status.peerFresh, self.status.peerHost == host,
                  self.frameClientGeneration == generation,
                  !self.status.frameConnected else { return }
            self.frameClientReconnectTask = nil
            self.ensureFrameClient(host: host)
        }
    }

    private func activateFrameConnection(_ connection: NWConnection,
                                         alreadyStarted: Bool,
                                         direction: String,
                                         isInbound: Bool,
                                         reservedGeneration: UInt64? = nil) {
        guard status.peerFresh, let expected = status.peerHost,
              let received = endpointHost(connection.endpoint), received == expected else {
            status.frameMessage = "拒绝虚拟相机 TCP：请先完成同 IP 的 UDP session 握手"
            connection.cancel()
            return
        }
        frameClientReconnectTask?.cancel(); frameClientReconnectTask = nil
        frameClientConnectTimeoutTask?.cancel(); frameClientConnectTimeoutTask = nil
        if frameClientConnection !== connection {
            frameClientGeneration &+= 1
            frameClientConnection?.cancel()
            frameClientConnection = nil
        }
        guard let generation = reservedGeneration
            ?? frameConnectionGate.reserve(peerHost: received) else {
            connection.cancel()
            return
        }
        guard frameConnectionGate.isCurrent(generation) else {
            connection.cancel()
            return
        }
        frameConnectionGeneration = generation
        frameConnections.filter { $0 !== connection }.forEach { $0.cancel() }
        frameConnections = [connection]
        activeFrameConnectionIsInbound = isInbound
        latestVirtualFrame = nil
        latestFrameReceivedAt = nil
        virtualFrameStore.reset(generation: generation)
        status.receivedFrameCount = 0; status.rejectedFrameCount = 0
        status.measuredFrameReceiveHz = 0
        status.latestFrameAgeMilliseconds = nil
        if !alreadyStarted { connection.start(queue: frameQueue) }
        status.frameConnected = true
        status.frameMessage = "\(direction) \(received):\(configuration.frameTCPPort) 已连接，虚拟相机接收中"
        receiveFrames(connection, generation: generation, buffer: Data())
    }

    private nonisolated func receiveFrames(_ connection: NWConnection, generation: UInt64,
                                           buffer initial: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, self.frameConnectionGate.isCurrent(generation) else {
                connection.cancel()
                return
            }
            let receivedAt = DispatchTime.now().uptimeNanoseconds
            let receivedDate = Date()
            var buffer = initial
            if let data { buffer.append(data) }
            let result = self.parseFrames(&buffer)
            if !result.frames.isEmpty {
                self.virtualFrameStore.offer(result.frames, receivedAt: receivedAt,
                                             receivedDate: receivedDate,
                                             generation: generation)
            }
            if let protocolError = result.protocolError {
                Task { @MainActor in
                    guard self.isCurrentFrameConnection(connection, generation: generation) else { return }
                    self.disconnectFramePeer(
                        scheduleReconnect: true,
                        message: "TCP 图像协议错误：\(protocolError)；UDP 位姿不受影响"
                    )
                }
                return
            }
            if !complete, error == nil {
                self.receiveFrames(connection, generation: generation, buffer: buffer)
            } else {
                Task { @MainActor in
                    guard self.isCurrentFrameConnection(connection, generation: generation) else { return }
                    self.disconnectFramePeer(scheduleReconnect: true)
                }
            }
        }
    }

    private func disconnectFramePeer(scheduleReconnect: Bool = false, message: String? = nil) {
        let reconnectHost = scheduleReconnect && status.running && status.peerFresh
            ? status.peerHost : nil
        frameClientReconnectTask?.cancel(); frameClientReconnectTask = nil
        frameClientConnectTimeoutTask?.cancel(); frameClientConnectTimeoutTask = nil
        frameClientGeneration &+= 1
        frameClientConnection?.cancel(); frameClientConnection = nil
        frameConnectionGeneration = frameConnectionGate.invalidate()
        frameConnections.forEach { $0.cancel() }
        frameConnections.removeAll()
        activeFrameConnectionIsInbound = false
        status.frameConnected = false
        latestFrameReceivedAt = nil
        latestVirtualFrame = nil
        virtualFrameStore.reset(generation: frameConnectionGeneration)
        status.latestFrameAgeMilliseconds = nil
        status.frameMessage = message
            ?? (status.frameListening ? "TCP 等待 UE 图像连接" : "TCP 图像未监听")
        if let reconnectHost { scheduleFrameClientReconnect(host: reconnectHost) }
    }

    private func isCurrentFrameConnection(_ connection: NWConnection, generation: UInt64) -> Bool {
        status.running && frameConnectionGate.isCurrent(generation)
            && frameConnectionGeneration == generation
            && frameConnections.contains(where: { $0 === connection })
    }

    private nonisolated static func endpointHostNonisolated(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return String(describing: host)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private func frameTCPParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let canonical = canonicalHost(host).lowercased()
        return canonical == "127.0.0.1" || canonical == "::1" || canonical == "localhost"
    }

    private func publishVirtualFrameSnapshot(into statusSnapshot: inout Status) {
        let snapshot = virtualFrameStore.snapshot()
        latestFrameReceivedAt = snapshot.receivedAt
        statusSnapshot.receivedFrameCount = snapshot.receivedFrames
        statusSnapshot.rejectedFrameCount = snapshot.rejectedFrames
        statusSnapshot.measuredFrameReceiveHz = snapshot.measuredReceiveHz
        let now = DispatchTime.now().uptimeNanoseconds
        guard let receivedAt = snapshot.receivedAt, now >= receivedAt else {
            statusSnapshot.latestFrameAgeMilliseconds = nil
            if latestVirtualFrame != nil { latestVirtualFrame = nil }
            return
        }
        let ageMilliseconds = Double(now - receivedAt) / 1_000_000
        statusSnapshot.latestFrameAgeMilliseconds = ageMilliseconds
        guard ageMilliseconds <= Self.virtualFrameFreshMilliseconds,
              let frame = snapshot.frame else {
            if latestVirtualFrame != nil { latestVirtualFrame = nil }
            return
        }
        let isNewFrame = latestVirtualFrame?.sourceFrameID != frame.sourceFrameID
        if isNewFrame { latestVirtualFrame = frame }
        if useVirtualFrames, isNewFrame {
            virtualFrameEverReady = true
            virtualFrameUnavailableSince = nil
            virtualFrameFaultReported = false
            onVirtualFrame?(frame)
        }
    }

    private nonisolated func parseFrames(_ buffer: inout Data) -> HILFrameParseResult {
        var result = HILFrameParseResult()
        var cursor = 0
        while buffer.count - cursor >= 56 {
            let sourceFormatCode = readUInt16(buffer, cursor + 6)
            guard readUInt32(buffer, cursor) == 0x4f464652 else {
                result.protocolError = "magic 非 OFFR"
                return result
            }
            guard readUInt16(buffer, cursor + 4) == 1 else {
                result.protocolError = "不支持的帧版本"
                return result
            }
            guard [UInt16(1), UInt16(2)].contains(sourceFormatCode) else {
                result.protocolError = "不支持的图像格式"
                return result
            }
            guard readUInt32(buffer, cursor + 8) == 56 else {
                result.protocolError = "帧头长度错误"
                return result
            }
            let payloadBytes = Int(readUInt32(buffer, cursor + 12))
            guard payloadBytes > 0, payloadBytes <= 16 * 1024 * 1024 else {
                result.protocolError = "图像负载长度越界"
                return result
            }
            guard buffer.count - cursor >= 56 + payloadBytes else { break }
            let sourceFrameID = readUInt64(buffer, cursor + 16)
            let sourcePoseSequence = readUInt64(buffer, cursor + 24)
            let capturePeerMonotonicNanoseconds = readUInt64(buffer, cursor + 32)
            let width = Int(readUInt32(buffer, cursor + 40))
            let height = Int(readUInt32(buffer, cursor + 44))
            let crc = readUInt32(buffer, cursor + 52)
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: cursor + 56)
            let payloadEnd = buffer.index(payloadStart, offsetBy: payloadBytes)
            let payload = buffer.subdata(in: payloadStart..<payloadEnd)
            cursor += 56 + payloadBytes
            guard (1...8192).contains(width), (1...8192).contains(height) else {
                result.protocolError = "图像尺寸越界"
                return result
            }
            guard CRC32.checksum(payload) == crc else {
                result.protocolError = "图像 CRC32 不匹配"
                return result
            }
            result.frames.append(.init(sourceFormatCode: sourceFormatCode,
                                       sourceFrameID: sourceFrameID,
                                       sourcePoseSequence: sourcePoseSequence,
                                       capturePeerMonotonicNanoseconds: capturePeerMonotonicNanoseconds,
                                       width: width, height: height, payload: payload))
        }
        if cursor > 0 { buffer.removeFirst(cursor) }
        return result
    }

    private nonisolated func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).bigEndian }
    }
    private nonisolated func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }
    private nonisolated func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).bigEndian }
    }

    private func resetVirtualFrameSafetyTracking(enabled: Bool) {
        virtualFrameModeEnabledAt = enabled ? DispatchTime.now().uptimeNanoseconds : nil
        virtualFrameUnavailableSince = nil
        virtualFrameEverReady = enabled && virtualFrameIsFresh
        virtualFrameFaultReported = false
    }

    private func monitorVirtualFrameSafety(now: UInt64) {
        guard useVirtualFrames, status.running, !virtualFrameFaultReported else { return }
        if let receivedAt = latestFrameReceivedAt, now >= receivedAt,
           Double(now - receivedAt) / 1_000_000 <= Self.virtualFrameFreshMilliseconds {
            virtualFrameEverReady = true
            virtualFrameUnavailableSince = nil
            return
        }
        if virtualFrameEverReady {
            if virtualFrameUnavailableSince == nil { virtualFrameUnavailableSince = now }
            guard let since = virtualFrameUnavailableSince,
                  Double(now - since) / 1_000_000 >= Self.virtualFrameDropoutGraceMilliseconds else { return }
            guard shouldEnforceVirtualFrameSafety?() == true else { return }
            reportVirtualFrameFault("UE 虚拟相机异步帧中断超过 5 秒")
            return
        }
        let enabledAt = virtualFrameModeEnabledAt ?? now
        virtualFrameModeEnabledAt = enabledAt
        guard now >= enabledAt,
              Double(now - enabledAt) / 1_000_000 >= Self.virtualFrameStartupGraceMilliseconds else { return }
        guard shouldEnforceVirtualFrameSafety?() == true else { return }
        reportVirtualFrameFault("UE 虚拟相机启动后 15 秒仍无首帧")
    }

    private func reportVirtualFrameFault(_ reason: String) {
        guard !virtualFrameFaultReported else { return }
        virtualFrameFaultReported = true
        status.frameMessage = reason
        onVirtualFrameSafetyFault?(reason)
    }

    private func fail(_ message: String) { status.message = message }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xedb88320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ UInt32.max
    }
}

/// Android-compatible, outbound-only HTTP mirror used by existing UE survey tools.
/// It never accepts commands and is independent from the low-latency OFHL control link.
@MainActor
final class SurveyUeBridgeController: ObservableObject {
    nonisolated static let schema = "openfly.survey.ue.v1"

    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: endpointKey) }
    }
    @Published private(set) var enabled = false
    @Published private(set) var status = "契约：WGS84 / ENU / FRU / SI · 1 Hz"

    private let endpointKey = "openfly.ue-bridge.endpoint"
    private var lastTelemetryAt = Date.distantPast
    private var telemetryInFlight = false
    private var lastTargetSignature = ""

    init() {
        endpoint = UserDefaults.standard.string(forKey: endpointKey)
            ?? "http://192.168.1.2:30010"
    }

    func toggle() {
        enabled.toggle()
        lastTelemetryAt = .distantPast
        lastTargetSignature = ""
        status = enabled ? "遥测镜像已开启 · 只出站 · 1 Hz"
            : "契约：WGS84 / ENU / FRU / SI · 1 Hz"
    }

    func sendMission(_ mission: SurveyMission?, peerHost: String?) {
        guard let mission else { status = "发送阻止：尚无 SurveyMission"; return }
        do {
            status = "正在发送任务…"
            try post(path: "/v1/survey/mission", body: Self.encodeMission(mission),
                     peerHost: peerHost) { [weak self] ok, message in
                self?.status = ok ? "任务已发送 · \(message)" : "任务发送失败 · \(message)"
            }
        } catch { status = "任务发送失败 · \(error.localizedDescription)" }
    }

    func submit(telemetry: FlightTelemetry, simulator: FlightSimulatorStatus,
                runtime: SurveyRuntimeSnapshot, peerHost: String?) {
        guard enabled, telemetry.aircraftLocationValid,
              telemetry.aircraft.latitude.isFinite, telemetry.aircraft.longitude.isFinite,
              Date().timeIntervalSince(lastTelemetryAt) >= 1, !telemetryInFlight else { return }
        do {
            telemetryInFlight = true
            lastTelemetryAt = Date()
            try post(path: "/v1/survey/telemetry",
                     body: Self.encodeTelemetry(telemetry: telemetry, simulator: simulator,
                                                runtime: runtime), peerHost: peerHost) {
                [weak self] ok, message in
                guard let self else { return }
                self.telemetryInFlight = false
                if !ok { self.status = "遥测镜像失败 · \(message)" }
            }
            submitTargetIfChanged(runtime: runtime, peerHost: peerHost)
        } catch {
            telemetryInFlight = false
            status = "遥测镜像失败 · \(error.localizedDescription)"
        }
    }

    func postCapture(_ record: SurveyFrameCaptureRecord, peerHost: String?) {
        do {
            try post(path: "/v1/survey/capture", body: Self.encodeCapture(record),
                     peerHost: peerHost) { [weak self] ok, message in
                if !ok { self?.status = "采集镜像失败 · \(message)" }
            }
        } catch { status = "采集镜像失败 · \(error.localizedDescription)" }
    }

    private func submitTargetIfChanged(runtime: SurveyRuntimeSnapshot, peerHost: String?) {
        guard let missionID = runtime.missionID, let phase = runtime.phase,
              let target = runtime.currentTarget,
              runtime.state == .running || runtime.state == .paused else { return }
        let signature = "\(missionID)|\(runtime.state.rawValue)|\(phase.rawValue)|\(runtime.legIndex)|\(runtime.waypointIndex)"
        guard signature != lastTargetSignature else { return }
        lastTargetSignature = signature
        do {
            try post(path: "/v1/survey/target",
                     body: Self.encodeTarget(missionID: missionID, runtime: runtime,
                                             phase: phase, target: target),
                     peerHost: peerHost) { [weak self] ok, message in
                if !ok { self?.status = "目标镜像失败 · \(message)" }
            }
        } catch { status = "目标镜像失败 · \(error.localizedDescription)" }
    }

    private func post(path: String, body: Data, peerHost: String?,
                      completion: @escaping @MainActor (Bool, String) -> Void) throws {
        let base = try Self.resolvedBaseURL(configured: endpoint, peerHost: peerHost)
        let url = base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode
            let ok = error == nil && code.map { (200...299).contains($0) } == true
            let message = error?.localizedDescription ?? code.map { "HTTP \($0)" } ?? "无 HTTP 响应"
            Task { @MainActor in completion(ok, message) }
        }.resume()
    }

    static func resolvedBaseURL(configured: String, peerHost: String?) throws -> URL {
        let raw = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host != nil else {
            throw SurveyValidationError.invalid("endpoint 必须是 http:// 或 https:// 地址")
        }
        if let peerHost = peerHost?.trimmingCharacters(in: .whitespacesAndNewlines),
           !peerHost.isEmpty { parts.host = peerHost }
        if parts.port == nil { parts.port = 30_010 }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let value = parts.url else { throw SurveyValidationError.invalid("UE endpoint 无效") }
        return value
    }

    static func encodeMission(_ mission: SurveyMission) throws -> Data {
        let missionObject = try JSONSerialization.jsonObject(
            with: Data(SurveyMissionJSON.encode(mission).utf8))
        return try encodeEnvelope(type: "mission", values: ["mission": missionObject])
    }

    static func encodeTelemetry(telemetry: FlightTelemetry, simulator: FlightSimulatorStatus,
                                runtime: SurveyRuntimeSnapshot) throws -> Data {
        try encodeEnvelope(type: "telemetry", values: [
            "timestamp_epoch_ms": Int64(Date().timeIntervalSince1970 * 1_000),
            "pose": pose(telemetry),
            "dji_simulator": ["active": simulator.active, "flying": simulator.flying],
            "execution": ["state": runtime.state.rawValue,
                          "waypoint_index": runtime.waypointIndex],
        ])
    }

    static func encodeTarget(missionID: String, runtime: SurveyRuntimeSnapshot,
                             phase: SurveyExecutionPhase, target: SurveyWaypoint) throws -> Data {
        try encodeEnvelope(type: "target", values: [
            "timestamp_epoch_ms": Int64(Date().timeIntervalSince1970 * 1_000),
            "mission_id": missionID,
            "execution": ["state": runtime.state.rawValue, "phase": phase.rawValue,
                          "execution_leg_index": runtime.legIndex,
                          "waypoint_index": runtime.waypointIndex],
            "target": waypoint(target),
        ])
    }

    nonisolated static func encodeCapture(_ record: SurveyFrameCaptureRecord) throws -> Data {
        try encodeEnvelope(type: "capture", values: [
            "timestamp_epoch_ms": Int64(record.frame.capturedAt.timeIntervalSince1970 * 1_000),
            "mission_id": record.missionID, "reason": record.reason,
            "frame_id": record.frame.sourceFrameID ?? UInt64(record.frame.sequence),
            "pose_sequence": record.frame.sourcePoseSequence ?? 0,
            "frame": ["format": record.frame.sourceFormat, "width": record.frame.width,
                      "height": record.frame.height,
                      "capture_peer_monotonic_ns": record.frame.sourceCapturePeerMonotonicNanoseconds ?? 0],
            "saved_path": record.imageURL.path,
            "pose": pose(record.telemetry),
            "execution": ["execution_leg_index": record.executionLegIndex,
                          "waypoint_index": record.waypointIndex],
        ])
    }

    nonisolated private static func encodeEnvelope(type: String, values: [String: Any]) throws -> Data {
        var root: [String: Any] = [
            "schema": schema, "type": type,
            "coordinate_contract": [
                "geodetic": "WGS84", "local_world": "ENU", "vehicle_body": "FRU",
                "heading": "clockwise_from_true_north_degrees",
                "gimbal_pitch": "negative_is_down_degrees", "linear_units": "meters",
            ],
        ]
        values.forEach { root[$0.key] = $0.value }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    nonisolated private static func pose(_ telemetry: FlightTelemetry) -> [String: Any] {
        ["latitude_wgs84_deg": telemetry.aircraft.latitude,
         "longitude_wgs84_deg": telemetry.aircraft.longitude,
         "aircraft_location_valid": telemetry.aircraftLocationValid,
         "flight_state_timestamp_epoch_ms": Int64(telemetry.flightStateTimestamp.timeIntervalSince1970 * 1_000),
         "altitude_asl_m": telemetry.asl,
         "altitude_agl_m": telemetry.altitude,
         "downward_height_m": telemetry.downwardHeight,
         "downward_height_valid": telemetry.downwardHeightValid,
         "heading_cw_from_north_deg": telemetry.heading,
         "gimbal_pitch_deg": telemetry.gimbalPitch,
         "velocity_north_mps": telemetry.velocityNorth,
         "velocity_east_mps": telemetry.velocityEast,
         "velocity_up_mps": -telemetry.velocityDown,
         "ground_speed_mps": hypot(telemetry.velocityNorth, telemetry.velocityEast),
         "gps_satellite_count": telemetry.satellites,
         "gps_signal_level": telemetry.gpsSignalLevel]
    }

    private static func waypoint(_ value: SurveyWaypoint) -> [String: Any] {
        ["latitude_wgs84_deg": value.point.latitude,
         "longitude_wgs84_deg": value.point.longitude,
         "altitude_agl_m": value.point.altitudeMeters,
         "heading_cw_from_north_deg": value.headingDegrees,
         "gimbal_pitch_deg": value.gimbalPitchDegrees,
         "kind": value.kind.rawValue, "capture_action": value.captureAction.rawValue,
         "capture_view": value.captureView.rawValue, "pass_index": value.passIndex]
    }
}
