import Foundation

enum ControlMode: String, CaseIterable {
    case manual = "人工控制"
    case vlnStandby = "VLN 待命"
    case vlnExecuting = "VLN 执行"
    case surveyArming = "航测待命"
    case surveyExecuting = "航测执行"
    case surveyPaused = "航测暂停"
    case holding = "悬停"
    case returningHome = "自动返航"
    case landing = "自动降落"
    case failsafe = "急停/失联保护"
}

enum ControlOwner: String { case remote = "遥控器", vln = "VLN", survey = "航测", autopilot = "飞控", none = "无" }

struct ControlSnapshot: Equatable {
    var mode: ControlMode
    var owner: ControlOwner
    var reason: String
}

struct FlightControlSupervisor {
    func resolve(
        telemetry: FlightTelemetry,
        emergencyStopped: Bool,
        vlnArmed: Bool,
        commandFresh: Bool,
        commandExecuting: Bool,
        manualTakeover: Bool,
        surveyState: SurveyExecutionState = .idle
    ) -> ControlSnapshot {
        if !telemetry.connected { return .init(mode: .failsafe, owner: .none, reason: "飞行器连接丢失") }
        if emergencyStopped { return .init(mode: .failsafe, owner: .none, reason: "本地急停已锁定") }
        if manualTakeover { return .init(mode: .manual, owner: .remote, reason: "检测到人工摇杆，VLN 已释放") }
        if telemetry.mode == .landing { return .init(mode: .landing, owner: .autopilot, reason: "飞控执行自动降落") }
        if telemetry.mode == .returningHome { return .init(mode: .returningHome, owner: .autopilot, reason: "飞控执行自动返航") }
        if surveyState == .running { return .init(mode: .surveyExecuting, owner: .survey, reason: "航测状态机持有 Virtual Stick") }
        if surveyState == .arming { return .init(mode: .surveyArming, owner: .survey, reason: "航测正在申请 Virtual Stick") }
        if surveyState == .paused { return .init(mode: .surveyPaused, owner: .remote, reason: "航测断点已保存，Virtual Stick 已释放") }
        if !vlnArmed { return .init(mode: .manual, owner: .remote, reason: "VLN 控制未启用") }
        if commandExecuting && commandFresh { return .init(mode: .vlnExecuting, owner: .vln, reason: "模型指令正在执行") }
        if commandFresh { return .init(mode: .vlnStandby, owner: .vln, reason: "控制已就绪") }
        return .init(mode: .holding, owner: .vln, reason: "指令过期，持续零速度")
    }
}
