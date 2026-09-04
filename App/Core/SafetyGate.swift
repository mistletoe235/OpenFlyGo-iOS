import Foundation

struct SafetyDecision: Equatable {
    var command: VelocityCommand
    var eligible: Bool
    var reason: String
}

struct SafetyGate {
    // Eligibility uses the same app-wide ceiling as the user-facing VLN
    // limiter. The selected limit is enforced by RelativePositionClosedLoop.
    var maxHorizontalSpeed = 4.0
    var maxVerticalSpeed = 1.0
    var maxYawRate = 45.0
    var minimumConfidence = 0.35
    var maximumTelemetryAge = 1.5
    var maximumFrameAge = 2.5

    func evaluate(
        action: RelativeAction?, telemetry: FlightTelemetry,
        emergencyStopped: Bool,
        stopThreshold: Double = UAVFlowPolicyContract.defaultStopThreshold,
        now: Date = Date()
    ) -> SafetyDecision {
        guard telemetry.connected else { return blocked("飞行器连接丢失") }
        guard !emergencyStopped else { return blocked("急停已锁定") }
        guard now.timeIntervalSince(telemetry.timestamp) <= maximumTelemetryAge else { return blocked("遥测已过期") }
        guard now.timeIntervalSince(telemetry.frameTimestamp) <= maximumFrameAge else { return blocked("图像帧已过期") }
        guard let action else { return blocked("没有模型指令") }
        guard !UAVFlowPolicyContract.shouldStop(action.stopScore, threshold: stopThreshold) else {
            return blocked(
                "模型请求停止 stop=\(String(format: "%.2f", action.stopScore)) "
                    + ">= \(String(format: "%.2f", stopThreshold))"
            )
        }
        guard action.confidence >= minimumConfidence else { return blocked("置信度低于安全阈值") }

        let command = VelocityCommand(
            forward: clamp(action.forwardMeters * 0.8, -maxHorizontalSpeed, maxHorizontalSpeed),
            right: clamp(action.rightMeters * 0.8, -maxHorizontalSpeed, maxHorizontalSpeed),
            up: clamp(action.upMeters * 0.7, -maxVerticalSpeed, maxVerticalSpeed),
            yawRate: clamp(action.yawDegrees * 0.9, -maxYawRate, maxYawRate)
        )
        return SafetyDecision(command: command, eligible: true, reason: "安全门通过")
    }

    func blocked(_ reason: String) -> SafetyDecision {
        SafetyDecision(command: .zero, eligible: false, reason: reason)
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
