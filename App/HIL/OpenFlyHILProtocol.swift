import Foundation

enum HILConnectionMode: String, Codable, CaseIterable, Identifiable {
    case lan, hotspot
    var id: String { rawValue }
    var label: String { self == .lan ? "局域网" : "手机热点直连" }
}

enum HILHotspotDiscoveryMode: String, Codable, CaseIterable, Identifiable {
    case automatic, manual
    var id: String { rawValue }
    var label: String { self == .automatic ? "自动发现" : "手动 IP" }
}

enum OpenFlyHILProtocol {
    static let magic: UInt32 = 0x4f46484c // OFHL
    static let version: UInt16 = 1
    static let headerBytes = 32
    static let maximumDatagramBytes = 1_400
    static let posePayloadBytes = 152

    enum MessageType: UInt16 { case hello = 1, pose = 2, heartbeat = 3, ping = 4, pong = 5, event = 6 }
    enum EventKind: UInt32 { case info = 0, collision = 1, stop = 2, emergency = 3 }

    struct Header: Equatable {
        var type: MessageType; var flags: UInt32; var sessionID: UInt64
        var sequence: UInt64; var payloadBytes: UInt32
    }
    struct Datagram: Equatable { var header: Header; var payload: Data }
    struct Hello: Equatable {
        var monotonicNanoseconds: UInt64; var requestedPoseHz: UInt32
        var simulatorStateHz: UInt32; var frameTCPPort: UInt32; var capabilities: UInt32
    }
    struct Pose: Equatable {
        var sampleMonotonicNanoseconds: UInt64
        var originLatitudeDegrees: Double; var originLongitudeDegrees: Double
        var eastMeters: Double; var northMeters: Double; var upMeters: Double
        var rollDegrees: Double; var pitchDegrees: Double; var headingDegreesClockwiseFromNorth: Double
        var velocityNorthMetersPerSecond: Double; var velocityEastMetersPerSecond: Double; var velocityUpMetersPerSecond: Double
        var gimbalPitchDegrees: Double
        var commandForwardMetersPerSecond: Double; var commandRightMetersPerSecond: Double
        var commandUpMetersPerSecond: Double; var commandYawRateDegreesPerSecond: Double
        var flightStateAgeMilliseconds: UInt32; var measuredSimulatorHz: Float; var stateFlags: UInt32
    }
    struct Event: Equatable {
        var peerMonotonicNanoseconds: UInt64; var kind: EventKind; var stopScore: Double
        var poseSequence: UInt64; var reason: String
    }

    static func encodeHello(sessionID: UInt64, sequence: UInt64, value: Hello) -> Data {
        payload(.hello, sessionID, sequence) { data in
            data.appendBE(value.monotonicNanoseconds); data.appendBE(value.requestedPoseHz)
            data.appendBE(value.simulatorStateHz); data.appendBE(value.frameTCPPort)
            data.appendBE(value.capabilities); data.appendBE(UInt32(0))
        }
    }

    static func encodePose(sessionID: UInt64, sequence: UInt64, value: Pose) -> Data {
        payload(.pose, sessionID, sequence) { data in
            data.appendBE(value.sampleMonotonicNanoseconds)
            [value.originLatitudeDegrees, value.originLongitudeDegrees, value.eastMeters, value.northMeters,
             value.upMeters, value.rollDegrees, value.pitchDegrees, value.headingDegreesClockwiseFromNorth,
             value.velocityNorthMetersPerSecond, value.velocityEastMetersPerSecond, value.velocityUpMetersPerSecond,
             value.gimbalPitchDegrees, value.commandForwardMetersPerSecond, value.commandRightMetersPerSecond,
             value.commandUpMetersPerSecond, value.commandYawRateDegreesPerSecond].forEach { data.appendBE($0.bitPattern) }
            data.appendBE(value.flightStateAgeMilliseconds); data.appendBE(value.measuredSimulatorHz.bitPattern)
            data.appendBE(value.stateFlags); data.appendBE(UInt32(0))
        }
    }

    static func encodePing(sessionID: UInt64, sequence: UInt64, monotonicNanoseconds: UInt64) -> Data {
        payload(.ping, sessionID, sequence) { $0.appendBE(monotonicNanoseconds) }
    }

    static func encodeHeartbeat(sessionID: UInt64, sequence: UInt64, monotonicNanoseconds: UInt64,
                                lastReceivedSequence: UInt64, stateFlags: UInt32 = 0) -> Data {
        payload(.heartbeat, sessionID, sequence) {
            $0.appendBE(monotonicNanoseconds); $0.appendBE(lastReceivedSequence)
            $0.appendBE(stateFlags); $0.appendBE(UInt32(0))
        }
    }

    static func encodePong(sessionID: UInt64, sequence: UInt64, echoed: UInt64, peer: UInt64) -> Data {
        payload(.pong, sessionID, sequence) { $0.appendBE(echoed); $0.appendBE(peer) }
    }

    static func decode(_ data: Data) throws -> Datagram {
        guard data.count >= headerBytes, data.count <= maximumDatagramBytes else { throw error("invalid datagram length") }
        var reader = HILDataReader(data)
        guard try reader.uint32() == magic else { throw error("invalid HIL magic") }
        guard try reader.uint16() == version else { throw error("unsupported HIL version") }
        guard let type = MessageType(rawValue: try reader.uint16()) else { throw error("invalid HIL type") }
        let header = Header(type: type, flags: try reader.uint32(), sessionID: try reader.uint64(),
                            sequence: try reader.uint64(), payloadBytes: try reader.uint32())
        guard Int(header.payloadBytes) == reader.remaining else { throw error("invalid HIL payload length") }
        return .init(header: header, payload: try reader.data(count: reader.remaining))
    }

    static func decodeEvent(_ payload: Data) throws -> Event {
        var reader = HILDataReader(payload)
        guard payload.count >= 32 else { throw error("invalid event payload") }
        let peer = try reader.uint64()
        guard let kind = EventKind(rawValue: try reader.uint32()) else { throw error("invalid event kind") }
        let score = Double(bitPattern: try reader.uint64())
        guard !score.isInfinite else { throw error("invalid event stop score") }
        let sequence = try reader.uint64(); let length = Int(try reader.uint32())
        guard length <= 512, length == reader.remaining,
              let reason = String(data: try reader.data(count: length), encoding: .utf8) else {
            throw error("invalid event reason")
        }
        return .init(peerMonotonicNanoseconds: peer, kind: kind, stopScore: score,
                     poseSequence: sequence, reason: reason)
    }

    private static func payload(_ type: MessageType, _ sessionID: UInt64, _ sequence: UInt64,
                                writer: (inout Data) -> Void) -> Data {
        var body = Data(); writer(&body)
        precondition(headerBytes + body.count <= maximumDatagramBytes)
        var data = Data(); data.appendBE(magic); data.appendBE(version); data.appendBE(type.rawValue)
        data.appendBE(UInt32(0)); data.appendBE(sessionID); data.appendBE(sequence)
        data.appendBE(UInt32(body.count)); data.append(body)
        return data
    }

    private static func error(_ message: String) -> SurveyValidationError { .invalid(message) }
}

final class HILLinkWatchdog {
    private let timeoutNanoseconds: UInt64
    private var lastReceive: UInt64?
    private var staleReported = false
    init(timeoutNanoseconds: UInt64) { precondition(timeoutNanoseconds > 0); self.timeoutNanoseconds = timeoutNanoseconds }
    func onReceive(now: UInt64) { lastReceive = now; staleReported = false }
    func isFresh(now: UInt64) -> Bool { guard let lastReceive else { return false }; return now <= lastReceive || now - lastReceive <= timeoutNanoseconds }
    func pollStaleTransition(now: UInt64) -> Bool {
        guard lastReceive != nil, !isFresh(now: now), !staleReported else { return false }
        staleReported = true; return true
    }
    func reset() { lastReceive = nil; staleReported = false }
}

private struct HILDataReader {
    let data: Data; var offset = 0
    init(_ data: Data) { self.data = data }
    var remaining: Int { data.count - offset }
    mutating func data(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw SurveyValidationError.invalid("truncated HIL data") }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    mutating func uint16() throws -> UInt16 { try integer() }
    mutating func uint32() throws -> UInt32 { try integer() }
    mutating func uint64() throws -> UInt64 { try integer() }
    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        let bytes = try data(count: MemoryLayout<T>.size)
        return bytes.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
