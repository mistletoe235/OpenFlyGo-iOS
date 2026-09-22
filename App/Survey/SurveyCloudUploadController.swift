import Foundation
import Combine

@MainActor
final class SurveyCloudUploadController: ObservableObject {
    @Published private(set) var manifest: SurveyUploadManifest?
    @Published private(set) var status = "正在读取本地上传队列…"
    @Published private(set) var ready = false
    @Published private(set) var loadFailed = false
    @Published private(set) var busy = false
    @Published private(set) var uploading = false
    @Published private(set) var intakeCount = 0
    @Published private(set) var historyImporting = false
    @Published private(set) var rejectedCount = 0
    @Published private(set) var liveEnabled = false
    @Published private(set) var paused = true
    private let store: SurveyUploadStore
    private let clientFactory: (SurveyCloudConnection) -> SurveyCloudClient
    private let tokenLoader: (URL) -> String
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var liveStartedAt = Date.distantFuture

    init(root: URL? = nil,
         clientFactory: @escaping (SurveyCloudConnection) -> SurveyCloudClient = { SurveyCloudClient(connection: $0) },
         tokenLoader: @escaping (URL) -> String = SurveyCloudTokenStore.load) {
        let directory = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenFlyGo/cloud-upload", isDirectory: true)
        self.store = SurveyUploadStore(root: directory)
        self.clientFactory = clientFactory
        self.tokenLoader = tokenLoader
        Task { [weak self] in
            guard let self else { return }
            do {
                self.manifest = try await self.store.load()
                self.status = self.manifest == nil ? "创建上传会话后，可上传航线触发帧或历史照片。" : "已恢复本地队列；请核对会话后手动继续上传。"
                self.ready = true
            } catch { self.loadFailed = true; self.status = "本地队列读取失败：\(error.localizedDescription)；未覆盖原有数据。" }
        }
    }

    deinit { worker?.cancel() }

    var canAdd: Bool { ready && !busy && manifest != nil && manifest?.finalized != true && manifest?.cancelled != true }
    var canFinalize: Bool {
        canAdd && !uploading && !liveEnabled && !historyImporting && intakeCount == 0 && manifest?.pendingCount == 0 && manifest?.jobs.isEmpty == false
    }

    func create(endpoint: String, token: String, configuration: SurveyUploadConfiguration) async {
        guard ready, !busy, manifest == nil else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try configuration.payload()
            let address = try SurveyCloudConnection(endpoint: endpoint, sessionID: "create", token: token)
            guard !address.token.isEmpty else { throw SurveyCloudError.invalid("请填写工作站访问码") }
            try SurveyCloudTokenStore.save(address.token, endpoint: address.endpoint)
            status = "正在创建上传会话…"
            let session = try await clientFactory(address).createUploadSession(configuration)
            let value = SurveyUploadManifest(endpoint: address.endpoint.absoluteString, sessionID: session.id, configuration: configuration)
            do { try await store.begin(value) }
            catch {
                status = "远端会话 \(session.id) 已创建，但本地保存失败；请保留此 ID，勿重复创建。"
                return
            }
            manifest = value
            paused = false
            rejectedCount = 0
            status = "会话已创建：\(session.id)。可开启实时采集或选择历史照片；不会自动提交重建。"
        } catch { report(error) }
    }

    func setLive(_ enabled: Bool) {
        guard !enabled || (canAdd && !historyImporting && intakeCount == 0) else { return }
        liveEnabled = enabled
        liveStartedAt = enabled ? Date() : .distantFuture
        status = enabled ? "实时采集已开启：只上传本次开关开启后的航线拍照后新图传帧，不是机载原片。" : "实时采集已关闭；已入队的图片仍保留。"
    }

    func accept(_ record: SurveyFrameCaptureRecord, view: SurveyCaptureView) {
        guard liveEnabled, canAdd, let sessionID = manifest?.sessionID else { return }
        guard record.frame.capturedAt >= liveStartedAt else { return }
        guard intakeCount < 2 else { rejectedCount += 1; status = "本地写入繁忙，未入队的原始记录仍在会话日志目录。"; return }
        do {
            let headers = try SurveyUploadImage.liveHeaders(record, view: view)
            let url = record.imageURL
            let identifier = "live:\(record.missionID):\(url.lastPathComponent)"
            intakeCount += 1
            Task { [weak self] in
                guard let self else { return }
                defer { self.intakeCount -= 1 }
                do {
                    self.adopt(try await self.store.enqueue(file: url, headers: headers, sessionID: sessionID, sourceID: identifier))
                    self.startWorker()
                } catch { self.rejectedCount += 1; self.report(error) }
            }
        } catch { rejectedCount += 1; report(error) }
    }

    func beginPhotoImport() -> String? {
        guard canAdd, !liveEnabled, !historyImporting, intakeCount == 0, let sessionID = manifest?.sessionID else { return nil }
        historyImporting = true
        return sessionID
    }

    func finishPhotoImport() { historyImporting = false }

    func importFiles(_ urls: [URL], expectedSessionID: String? = nil) async {
        guard !liveEnabled else { status = "请先关闭实时采集，再导入历史照片。"; return }
        guard canAdd, let sessionID = manifest?.sessionID, intakeCount == 0 else { return }
        guard expectedSessionID == nil || expectedSessionID == sessionID,
              !historyImporting || expectedSessionID == sessionID else { return }
        intakeCount += 1
        defer { intakeCount -= 1 }
        var accepted = 0
        var lastFailure: String?
        for url in urls.prefix(100) {
            guard manifest?.sessionID == sessionID, manifest?.finalized != true, !Task.isCancelled else { break }
            let access = url.startAccessingSecurityScopedResource()
            do {
                adopt(try await store.enqueue(file: url, headers: nil, sessionID: sessionID, sourceID: UUID().uuidString))
                accepted += 1
            } catch { rejectedCount += 1; lastFailure = error.localizedDescription }
            if access { url.stopAccessingSecurityScopedResource() }
            startWorker()
        }
        status = "本批已入队 \(accepted) 张；累计拒绝 \(rejectedCount) 张。\(lastFailure.map { "最近原因：\($0)" } ?? "")"
    }

    func pause() {
        paused = true
        liveEnabled = false
        worker?.cancel()
        status = "上传已暂停，待传图片已落盘；不会取消服务器任务。"
    }

    func resume() {
        guard canAdd else { return }
        paused = false
        startWorker()
    }

    func updateToken(_ token: String) {
        guard !busy, !uploading, let manifest else { return }
        do {
            let connection = try SurveyCloudConnection(endpoint: manifest.endpoint, sessionID: manifest.sessionID, token: token)
            guard !connection.token.isEmpty else { throw SurveyCloudError.invalid("访问码不能为空") }
            try SurveyCloudTokenStore.save(connection.token, endpoint: connection.endpoint)
            status = "访问码已更新，请手动继续上传。"
        } catch { report(error) }
    }

    func finalize() async {
        guard canFinalize, let current = manifest else { status = "请关闭实时采集，并等待所有图片成功上传后再提交。"; return }
        busy = true
        defer { busy = false }
        do {
            let remote = try await client(current).uploadSession(current.sessionID)
            guard remote.cancelled != true else { throw SurveyCloudError.invalid("远端会话已取消") }
            if remote.sealed != true { _ = try await client(current).uploadSession(current.sessionID, action: "finalize") }
            manifest = try await store.markClosed(sessionID: current.sessionID)
            paused = true
            status = "已提交重建。可用下方按钮读取结果；任务不会自动执行，提交后不能追加图片。"
        } catch { report(error) }
    }

    func refresh() async {
        guard !busy, !uploading, !historyImporting, intakeCount == 0, let current = manifest else { return }
        busy = true
        defer { busy = false }
        do {
            let session = try await client(current).uploadSession(current.sessionID)
            if session.sealed == true || session.cancelled == true {
                liveEnabled = false
                paused = true
                manifest = try await store.markClosed(sessionID: current.sessionID, cancelled: session.cancelled == true)
            }
            status = "远端 \(session.phase ?? "unknown") · 已接收 \(session.imageCount ?? 0) 张"
        } catch { report(error) }
    }

    func retryReconstruction() async {
        guard !busy, !uploading, intakeCount == 0, let current = manifest,
              current.finalized, !current.cancelled else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await client(current).uploadSession(current.sessionID, action: "retry")
            status = "已请求重新处理已提交的会话，请刷新结果。"
        } catch { report(error) }
    }

    func cancelRemote() async {
        guard !busy, !uploading, !historyImporting, intakeCount == 0, let current = manifest else { return }
        busy = true
        liveEnabled = false
        paused = true
        defer { busy = false }
        do {
            _ = try await client(current).uploadSession(current.sessionID, action: "cancel")
            manifest = try await store.markClosed(sessionID: current.sessionID, cancelled: true)
            status = "远端任务已取消，本地待传文件仍保留。"
        } catch { report(error) }
    }

    func clearLocal() async {
        guard !busy, !uploading, !liveEnabled, !historyImporting, intakeCount == 0 else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.clear()
            manifest = nil
            ready = true
            loadFailed = false
            paused = true
            rejectedCount = 0
            status = "已清理本地队列；服务器数据没有删除。"
        } catch { report(error) }
    }

    func report(_ error: Error) { status = error.localizedDescription }

    private func adopt(_ value: SurveyUploadManifest) {
        guard manifest?.sessionID == value.sessionID, value.revision >= (manifest?.revision ?? 0) else { return }
        manifest = value
    }

    private func client(_ manifest: SurveyUploadManifest) throws -> SurveyCloudClient {
        let address = try SurveyCloudConnection(endpoint: manifest.endpoint, sessionID: manifest.sessionID, token: "")
        let connection = try SurveyCloudConnection(endpoint: manifest.endpoint, sessionID: manifest.sessionID, token: tokenLoader(address.endpoint))
        guard !connection.token.isEmpty else { throw SurveyCloudError.invalid("当前服务访问码缺失，请更新后重试") }
        return clientFactory(connection)
    }

    private func startWorker() {
        guard !paused, !uploading, !busy, let current = manifest, !current.finalized, !current.cancelled,
              current.pendingCount > 0 else { return }
        uploading = true
        let currentGeneration = generation
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == currentGeneration {
                    self.uploading = false
                    self.worker = nil
                    if !self.paused { self.startWorker() }
                }
            }
            do {
                let transport = try self.client(current)
                let remote = try await transport.uploadSession(current.sessionID)
                try Task.checkCancellation()
                if remote.sealed == true || remote.cancelled == true {
                    self.manifest = try await self.store.markClosed(sessionID: current.sessionID, cancelled: remote.cancelled == true)
                    self.liveEnabled = false
                    throw SurveyCloudError.invalid("远端会话已提交或取消，不能继续上传；本地图片仍保留")
                }
                while let job = self.manifest?.jobs.first(where: { !$0.uploaded }), self.generation == currentGeneration {
                    try Task.checkCancellation()
                    let bytes = try await self.store.data(for: job, sessionID: current.sessionID)
                    var attempt = 0
                    while true {
                        do {
                            try await transport.uploadImage(sessionID: current.sessionID, job: job, bytes: bytes)
                            break
                        } catch {
                            try Task.checkCancellation()
                            guard attempt < 2, Self.retryable(error) else { throw error }
                            attempt += 1
                            self.status = "网络暂时失败，正在重试第 \(job.sequence + 1) 张（\(attempt)/2）…"
                            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                        }
                    }
                    try Task.checkCancellation()
                    self.adopt(try await self.store.acknowledge(job, sessionID: current.sessionID))
                    self.status = "已上传 \(self.manifest!.jobs.count - self.manifest!.pendingCount)/\(self.manifest!.jobs.count) 张"
                }
            } catch {
                guard self.generation == currentGeneration, !Task.isCancelled else { return }
                self.paused = true
                self.report(error)
            }
        }
    }

    private static func retryable(_ error: Error) -> Bool {
        if case SurveyCloudError.http(let status) = error { return status == 408 || status == 429 || (500...599).contains(status) }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }
}
