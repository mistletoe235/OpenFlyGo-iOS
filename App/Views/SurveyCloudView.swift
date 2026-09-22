import SwiftUI
import SceneKit

@MainActor
final class SurveyCloudViewModel: ObservableObject {
    @Published private(set) var result: SurveyCloudResult?
    @Published private(set) var scene: SCNScene?
    @Published private(set) var pointCount = ""
    @Published private(set) var missionRaw: String?
    @Published private(set) var missionSummary = ""
    @Published private(set) var status = "填写服务根地址、访问码和已有会话 ID，读取云端结果。不会创建或运行远端任务。"
    @Published private(set) var busy = false
    private var client: SurveyCloudClient?
    private var task: Task<Void, Never>?
    private var generation = 0

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        busy = false
        client = nil
        result = nil
        scene = nil
        missionRaw = nil
        missionSummary = ""
        pointCount = ""
        status = "连接参数已更新，请重新连接。"
    }

    func connect(endpoint: String, sessionID: String, token: String) {
        reset()
        do {
            let connection = try SurveyCloudConnection(endpoint: endpoint, sessionID: sessionID, token: token)
            let client = SurveyCloudClient(connection: connection)
            perform("正在连接并读取会话结果…") { [weak self] in
                let result = try await client.result()
                try Task.checkCancellation()
                try SurveyCloudTokenStore.save(connection.token, endpoint: connection.endpoint)
                self?.client = client
                self?.result = result
                self?.status = "已连接 · \(result.phase ?? "unknown")\n\(result.message ?? "")\n\(result.error ?? result.missionError ?? "")"
            }
        } catch { status = error.localizedDescription }
    }

    func loadPointCloud() {
        guard let client, let result else { return }
        scene = nil
        perform("正在下载点云（上限32 MiB）…") { [weak self] in
            let cloud = try await client.pointCloud(result)
            try Task.checkCancellation()
            self?.scene = SurveyCloudPLY.scene(cloud)
            self?.pointCount = "显示 \(cloud.positions.count) / \(cloud.sourceCount) 点 · 拖动旋转，双指缩放"
            self?.status = "点云已加载；这是云端重建结果，不是实时避障地图。"
        }
    }

    func loadMission() {
        guard let client, let result else { return }
        missionRaw = nil
        perform("正在下载并校验云端航线…") { [weak self] in
            let raw = try await client.mission(result)
            try Task.checkCancellation()
            let mission = try SurveyCloudClient.validateMission(raw)
            self?.missionRaw = raw
            self?.missionSummary = "\(mission.name) · \(mission.waypoints.count) 个航点 · \(mission.estimatedPhotoCount) 张计划照片"
            self?.status = "航线格式和补拍合同校验通过。请导入地图预览，并重新执行飞行前检查。"
        }
    }

    func report(_ error: Error) { status = error.localizedDescription }

    private func perform(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        status = message
        let current = generation
        task = Task { [weak self] in
            do { try await action() }
            catch {
                guard !Task.isCancelled, self?.generation == current else { return }
                self?.status = "操作失败：\(error.localizedDescription)"
            }
            guard self?.generation == current else { return }
            self?.busy = false
        }
    }
}

struct SurveyCloudView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("openfly.survey.cloud.endpoint") private var endpoint = ""
    @AppStorage("openfly.survey.cloud.session") private var sessionID = ""
    @State private var token = ""
    @StateObject private var model = SurveyCloudViewModel()
    @State private var showingUpload = false
    @ObservedObject var upload: SurveyCloudUploadController
    var suggestedCamera: SurveyCameraProfile?
    let editingLocked: Bool
    let importMission: (String) throws -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("显示本机采集 / 上传功能", isOn: $showingUpload)
                        .accessibilityIdentifier("survey.cloud.upload.mode")
                    Text("已有会话浏览仍是只读。新建、上传、提交或取消只在本机上传区域显式操作。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("远程重建服务") {
                    TextField("服务根地址，例如 https://server.example", text: $endpoint)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("survey.cloud.endpoint")
                        .disabled(model.busy)
                    SecureField("访问码（Bearer token）", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("survey.cloud.token").disabled(model.busy)
                    TextField("已有会话 ID", text: $sessionID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("survey.cloud.session").disabled(model.busy)
                    if endpoint.lowercased().hasPrefix("http://") {
                        Text("当前使用 HTTP：访问码和数据会明文传输，请仅在可信网络/VPN中使用；建议服务器配置 HTTPS。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button(model.result == nil ? "连接并读取结果" : "刷新云端结果") {
                        model.connect(endpoint: endpoint, sessionID: sessionID, token: token)
                    }.disabled(model.busy).accessibilityIdentifier("survey.cloud.connect")
                    Text("访问码仅存本机钥匙串，不会写入航线文件。服务器需要提供与 Android 一致的 /api/sessions/{id}/result 接口，不是 SSH 地址。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if showingUpload {
                    SurveyCloudUploadSection(upload: upload, endpoint: endpoint, token: token,
                        editingLocked: editingLocked, suggestedCamera: suggestedCamera) { address, identifier in
                        endpoint = address
                        sessionID = identifier
                        showingUpload = false
                        model.reset()
                        restoreToken()
                    }
                }
                Section("结果与预览") {
                    if model.busy { ProgressView() }
                    Text(model.status).font(.callout).textSelection(.enabled)
                    if let result = model.result {
                        Text("会话：\(result.sessionID)").font(.caption)
                        Button("下载并查看点云") { model.loadPointCloud() }
                            .disabled(model.busy || result.pointCloud?.url?.isEmpty != false)
                            .accessibilityIdentifier("survey.cloud.pointcloud")
                        Button("下载云端航线") { model.loadMission() }
                            .disabled(model.busy || result.relativeHeightTest || result.mission?.url?.isEmpty != false)
                            .accessibilityIdentifier("survey.cloud.mission")
                        Text(result.relativeHeightTest ? "相对高度测试结果：禁止直接导入飞行航线。" :
                             result.mission?.safeToExecute == true ? "服务器声明可执行，但仍必须完成本机预检；不会自动执行。" :
                             "服务器未声明航线可安全执行（safe_to_execute≠true）。只下载、校验和导入预览，不代表实飞许可。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let scene = model.scene {
                        SceneView(scene: scene, options: [.allowsCameraControl])
                            .frame(height: 300).accessibilityIdentifier("survey.cloud.pointcloud.scene")
                        Text(model.pointCount).font(.caption)
                    }
                    if let raw = model.missionRaw {
                        Text(model.missionSummary)
                        Button("导入任务库并在地图预览") {
                            do { try importMission(raw); dismiss() }
                            catch { model.report(error) }
                        }.disabled(model.busy || editingLocked).accessibilityIdentifier("survey.cloud.import")
                        if editingLocked { Text("航线正在执行或暂停待续飞；请先终止任务再导入。") }
                    }
                }
            }
            .navigationTitle("云端点云与航线")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear { restoreToken() }
        .onChange(of: endpoint) { _ in model.reset(); restoreToken() }
        .onChange(of: sessionID) { _ in model.reset() }
        .onChange(of: token) { _ in model.reset() }
        .onDisappear { model.reset() }
    }

    private func restoreToken() {
        guard let connection = try? SurveyCloudConnection(endpoint: endpoint, sessionID: "lookup", token: "") else {
            token = ""; return
        }
        token = SurveyCloudTokenStore.load(endpoint: connection.endpoint)
    }
}
