import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct SurveyCloudUploadSection: View {
    @ObservedObject var upload: SurveyCloudUploadController
    let endpoint: String
    let token: String
    let editingLocked: Bool
    let suggestedCamera: SurveyCameraProfile?
    let viewResult: (String, String) -> Void
    @State private var name = "iOS 航测采集"
    @State private var horizontalFOV = ""
    @State private var takeoffASL = ""
    @State private var interval = "2"
    @State private var continuousRecapture = false
    @State private var replacementToken = ""
    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var confirmFinalize = false
    @State private var confirmClear = false
    @State private var confirmCancel = false
    @State private var loadingPhotos = false
    @State private var selectedSessionID: String?

    var body: some View {
        Section("从本机采集与上传") {
            if let manifest = upload.manifest {
                Text("绑定服务：\(manifest.endpoint)").font(.caption).textSelection(.enabled)
                Text("上传会话：\(manifest.sessionID)").font(.caption).textSelection(.enabled)
                Text("已传 \(manifest.jobs.count - manifest.pendingCount) / \(manifest.jobs.count) · 待传 \(manifest.pendingCount) · 拒绝 \(upload.rejectedCount)")
                Text("水平 FOV \(manifest.configuration.horizontalFOV, specifier: "%.2f")° · 起飞点海拔 \(manifest.configuration.takeoffASL.map { String(format: "%.2f m", $0) } ?? "未提供：不导出航线")")
                    .font(.caption)
                if !manifest.finalized && !manifest.cancelled {
                    Toggle("航线拍照后实时上传图传帧", isOn: Binding(get: { upload.liveEnabled }, set: upload.setLive))
                        .disabled(!upload.canAdd || upload.historyImporting || upload.intakeCount > 0).accessibilityIdentifier("survey.cloud.upload.live")
                    Text("不是机载 SD 卡原片，也不是持续录屏；关闭页面仍会采集。仿真数据不会混入实拍会话。进入后台会暂停，重开后需手动继续。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("从文件选择历史照片") { selectedSessionID = manifest.sessionID; showFiles = true }
                        Button("从相册选择") { selectedSessionID = manifest.sessionID; showPhotos = true }
                    }.disabled(!upload.canAdd || upload.liveEnabled || upload.intakeCount > 0 || upload.historyImporting || loadingPhotos || editingLocked)
                    Text("每批最多 100 张 JPEG/PNG，保留原图 GPS/海拔；HEIC 或缺少定位的照片会拒绝，不用当前飞机位置代填。请先关闭实时采集；任务执行/暂停期间不批量导入历史图片。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("继续 / 重试上传") { upload.resume() }
                            .disabled(!upload.canAdd || upload.uploading)
                        Button("暂停上传与实时采集") { upload.pause() }
                            .disabled(upload.busy)
                    }
                    Button("结束上传并提交重建") { confirmFinalize = true }
                        .disabled(!upload.canFinalize || loadingPhotos)
                        .accessibilityIdentifier("survey.cloud.upload.finalize")
                }
                HStack {
                    Button("刷新上传会话") { Task { await upload.refresh() } }
                        .disabled(upload.busy || upload.uploading || upload.intakeCount > 0)
                    Button("查看本会话点云 / 航线") { viewResult(manifest.endpoint, manifest.sessionID) }
                }
                if manifest.finalized && !manifest.cancelled {
                    Button("重试服务端重建") { Task { await upload.retryReconstruction() } }.disabled(upload.busy)
                }
                DisclosureGroup("访问码与会话管理") {
                    SecureField("更新此上传服务的访问码", text: $replacementToken)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存更新的访问码") { upload.updateToken(replacementToken); replacementToken = "" }
                        .disabled(upload.busy || upload.uploading || replacementToken.isEmpty)
                    Button("取消服务器任务", role: .destructive) { confirmCancel = true }
                        .disabled(upload.busy || upload.uploading || upload.intakeCount > 0 || upload.historyImporting || loadingPhotos || manifest.cancelled)
                    Button("清理本地上传记录", role: .destructive) { confirmClear = true }
                        .disabled(upload.busy || upload.uploading || upload.liveEnabled || upload.intakeCount > 0 || upload.historyImporting || loadingPhotos)
                }
            } else {
                if upload.loadFailed {
                    Button("清理无法恢复的本地上传记录", role: .destructive) { confirmClear = true }
                }
                Text("使用上方服务根地址和访问码创建新会话，不会修改已有会话 ID 对应的远端任务。")
                    .font(.caption)
                TextField("会话名称", text: $name)
                TextField("实际水平视场角（度）", text: $horizontalFOV).keyboardType(.decimalPad)
                TextField("起飞点海拔 ASL（米，可留空）", text: $takeoffASL).keyboardType(.numbersAndPunctuation)
                TextField("最短拍照间隔（秒）", text: $interval).keyboardType(.decimalPad)
                Toggle("连续补拍（实验）", isOn: $continuousRecapture)
                    .accessibilityIdentifier("survey.cloud.upload.continuous")
                Text("开启后请求 schema 14：符合条件的中间拍照点连续通过，转弯和边界仍可停拍。需保持 App 前台及遥控连接；默认使用停点拍照。")
                    .font(.caption).foregroundStyle(.orange)
                Text("留空起飞海拔仍可重建/看点云，但不导出航线。水平 FOV 必须对应上传图像，不要把相对飞行高度当作海拔；不同相机/起飞基准应另建会话。")
                    .font(.caption).foregroundStyle(.orange)
                Button("创建上传会话") {
                    guard let fov = Double(horizontalFOV), let cadence = Double(interval),
                          takeoffASL.isEmpty || Double(takeoffASL)?.isFinite == true else {
                        upload.report(SurveyCloudError.invalid("请检查视场角、拍照间隔和起飞点海拔")); return
                    }
                    let configuration = SurveyUploadConfiguration(name: name, horizontalFOV: fov,
                        takeoffASL: Double(takeoffASL), minimumInterval: cadence,
                        recaptureFlightMode: continuousRecapture ? .continuousExperimental : .stopAndCapture)
                    Task { await upload.create(endpoint: endpoint, token: token, configuration: configuration) }
                }.disabled(!upload.ready || upload.busy || endpoint.isEmpty || token.isEmpty)
                    .accessibilityIdentifier("survey.cloud.upload.create")
            }
            if upload.busy || upload.uploading || upload.intakeCount > 0 || loadingPhotos { ProgressView() }
            Text(upload.status).font(.callout).textSelection(.enabled)
        }
        .onAppear {
            if horizontalFOV.isEmpty, let suggestedCamera {
                horizontalFOV = String(format: "%.4f", suggestedCamera.horizontalFieldOfViewDegrees)
                interval = String(suggestedCamera.minimumCaptureIntervalSeconds)
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.jpeg, .png], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let sessionID = selectedSessionID
                Task { await upload.importFiles(urls, expectedSessionID: sessionID ?? "invalid") }
            case .failure(let error): upload.report(error)
            }
        }
        .sheet(isPresented: $showPhotos) {
            SurveyHistoryPhotoPicker { results in
                showPhotos = false
                guard !results.isEmpty, selectedSessionID == upload.manifest?.sessionID,
                      let sessionID = upload.beginPhotoImport() else { return }
                loadingPhotos = true
                Task {
                    defer { loadingPhotos = false; upload.finishPhotoImport() }
                    for result in results {
                        do {
                            let file = try await SurveyHistoryPhotoPicker.copyFile(result.itemProvider)
                            await upload.importFiles([file], expectedSessionID: sessionID)
                            try? FileManager.default.removeItem(at: file)
                        } catch { upload.report(error) }
                    }
                }
            }
        }
        .confirmationDialog("结束上传并提交重建？", isPresented: $confirmFinalize, titleVisibility: .visible) {
            Button("提交重建") { Task { await upload.finalize() } }
        } message: { Text("只能在所有已入队图片上传后提交。被拒绝的图片不在队列中；提交后不能追加，也不会自动执行云端航线。") }
        .confirmationDialog("清理本地上传记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清理本地队列", role: .destructive) { Task { await upload.clearLocal() } }
        } message: { Text("会删除本地待传副本，服务器数据不受影响。请先保存会话 ID；未上传的副本清理后无法恢复。") }
        .confirmationDialog("取消服务器任务？", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("取消服务器任务", role: .destructive) { Task { await upload.cancelRemote() } }
        } message: { Text("只操作当前绑定上传会话，不操作只读浏览器中的其他会话。") }
    }
}

struct SurveyHistoryPhotoPicker: UIViewControllerRepresentable {
    let completion: ([PHPickerResult]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 100
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([PHPickerResult]) -> Void
        init(completion: @escaping ([PHPickerResult]) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) { completion(results) }
    }
    static func copyFile(_ provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) ?? UTType.image.identifier) { source, error in
                guard let source else {
                    continuation.resume(throwing: error ?? SurveyCloudError.invalid("无法读取原始照片")); return
                }
                do {
                    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard (128...SurveyUploadImage.maximumBytes).contains(size) else {
                        throw SurveyCloudError.invalid("相册原图超过上传大小上限")
                    }
                    let destination = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).\(source.pathExtension)")
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
