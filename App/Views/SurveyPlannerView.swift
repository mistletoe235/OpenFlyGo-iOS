import MapKit

private func surveyMapCoordinate(_ wgs84: SurveyGeoPoint) -> CLLocationCoordinate2D {
    let display = ChinaMapCoordinateTransform.wgs84ToMap(wgs84)
    return .init(latitude: display.latitude, longitude: display.longitude)
}

private func surveyWGS84Point(_ mapCoordinate: CLLocationCoordinate2D) -> SurveyGeoPoint {
    ChinaMapCoordinateTransform.mapToWGS84(.init(
        latitude: mapCoordinate.latitude, longitude: mapCoordinate.longitude
    ))
}
import SwiftUI
import UniformTypeIdentifiers

enum SurveyBoundaryTapResult: Equatable {
    case added(index: Int)
    case moved(index: Int)
    case limitReached(maximum: Int)
}

enum SurveyBoundaryEditor {
    static func applyTap(_ point: SurveyGeoPoint, roi: inout [SurveyGeoPoint],
                         selectedVertexIndex: inout Int?, maximumVertices: Int = 64) -> SurveyBoundaryTapResult {
        if let index = selectedVertexIndex, roi.indices.contains(index) {
            roi[index] = point
            selectedVertexIndex = nil
            return .moved(index: index)
        }
        guard roi.count < maximumVertices else {
            selectedVertexIndex = nil
            return .limitReached(maximum: maximumVertices)
        }
        roi.append(point)
        selectedVertexIndex = nil
        return .added(index: roi.count - 1)
    }

    @discardableResult
    static func undoLastVertex(roi: inout [SurveyGeoPoint], selectedVertexIndex: inout Int?) -> Bool {
        guard !roi.isEmpty else { return false }
        roi.removeLast()
        selectedVertexIndex = nil
        return true
    }

    @discardableResult
    static func deleteSelectedVertex(roi: inout [SurveyGeoPoint],
                                     selectedVertexIndex: inout Int?) -> Int? {
        guard let index = selectedVertexIndex, roi.indices.contains(index) else { return nil }
        roi.remove(at: index)
        selectedVertexIndex = nil
        return index
    }
}

enum SurveyPlannerSafetyPolicy {
    static func editingLocked(for state: SurveyExecutionState) -> Bool {
        [.arming, .running, .paused].contains(state)
    }

    static func canTerminate(_ state: SurveyExecutionState) -> Bool {
        [.arming, .running, .paused].contains(state)
    }

    static func validateTerrainSource(enabled: Bool, hasLocalTerrain: Bool,
                                      hasDownloadedTerrain: Bool) throws {
        guard !enabled || hasLocalTerrain || hasDownloadedTerrain else {
            throw SurveyValidationError.invalid(
                "已启用仿地，但没有可用 DSM/DEM；请先下载或导入高程数据，或关闭仿地"
            )
        }
    }

    static func takeoffReference(home: SurveyGeoPoint?, aircraft: SurveyGeoPoint?,
                                 fallback: SurveyGeoPoint) -> SurveyGeoPoint {
        home ?? aircraft ?? fallback
    }
}

private enum SurveyTerrainKind: String, CaseIterable {
    case surfaceDSM
    case bareDEM
}

private struct SurveyMissionJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    private let data: Data

    init(json: String) {
        data = Data(json.utf8)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct SurveyPlannerSettingsPayload: Codable {
    var schemaVersion = 1
    var missionName: String
    var altitude: Double
    var speed: Double
    var obliqueSpeed: Double?
    var forwardOverlap: Double
    var sideOverlap: Double
    var heading: Double
    var margin: Double
    var targetSurfaceOffset: Double
    var safeTakeoffAltitude: Double
    var takeoffSpeed: Double
    var descentSpeed: Double?
    var obliqueForwardOverlap: Double
    var obliqueSideOverlap: Double
    var obliqueGimbalPitch: Double
    var timedCaptureInterval: Double
    var captureTriggerMode: String
    var startPointMode: String
    var altitudeMode: String
    var takeoffMode: String
    var collectionMode: String
    var completionAction: String
    var obliqueHeadingMode: String
    var enabledCaptureViews: [String]
    var terrainFollowingEnabled: Bool
}

private func surveyPreviewPanelFromArguments() -> Int {
    guard let value = ProcessInfo.processInfo.arguments.first(where: {
        $0.hasPrefix("--survey-ui-tab=")
    })?.split(separator: "=").last.flatMap({ Int($0) }) else { return 0 }
    // Panel 4 is the task library. Keep it launchable from the simulator QA
    // harness so its layout can be checked without driving a rotated Menu.
    return min(4, max(0, value))
}

struct SurveyPlannerView: View {
    @AppStorage(ChinaMapCalibrationMode.defaultsKey)
    private var chinaMapCalibrationRaw = ChinaMapCalibrationMode.automatic.rawValue
    @EnvironmentObject private var flight: FlightViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = SurveyMissionStore()

    @State private var roi: [SurveyGeoPoint] = []
    @State private var mission: SurveyMission?
    @State private var missionName = "校园测绘任务"
    @State private var altitude = 60.0
    @State private var speed = 3.0
    @State private var obliqueSpeed = 3.0
    @State private var forwardOverlap = 80.0
    @State private var sideOverlap = 70.0
    @State private var heading = 0.0
    @State private var margin = 0.0
    @State private var targetSurfaceOffset = 0.0
    @State private var safeTakeoffAltitude = 30.0
    @State private var takeoffSpeed = 3.0
    @State private var descentSpeed = 2.0
    @State private var requestedGoHomeHeight = 50.0
    @State private var obliqueForwardOverlap = 70.0
    @State private var obliqueSideOverlap = 60.0
    @State private var obliqueGimbalPitch = -45.0
    @State private var captureTriggerMode: SurveyCaptureTriggerMode = .distance
    @State private var timedCaptureInterval = 1.0
    @State private var startPointMode: SurveyStartPointMode = .autoNearest
    @State private var altitudeMode: SurveyAltitudeMode = .aboveTargetSurface
    @State private var takeoffMode: SurveyTakeoffMode = .manual
    @State private var collectionMode: SurveyCollectionMode = .ortho
    @State private var completionAction: SurveyCompletionAction = .returnToHome
    @State private var obliqueHeadingMode: SurveyObliqueHeadingMode = .trackRoute
    @State private var enabledCaptureViews = SurveyCaptureView.standardSurveyViews
    @State private var captureSelectionSourceMission: SurveyMission?
    @State private var activeRecaptureSourceMission: SurveyMission?
    @State private var terrainFollowingEnabled = false
    @State private var terrainKind: SurveyTerrainKind = .surfaceDSM
    @State private var terrainAlignmentConfirmed = false
    @State private var terrainDownload: GlobalTerrainDownloadResult?
    @State private var localTerrain: GeoTIFFTerrain?
    @State private var localTerrainSHA256: String?
    @State private var buildingHeightDownload: BuildingHeightDownloadResult?
    @State private var localBuildingHeight: GeoTIFFTerrain?
    @State private var localBuildingHeightSHA256: String?
    @State private var buildingHeightTemplate = UserDefaults.standard.string(forKey: "openfly.survey.building-height-template") ?? ""
    @State private var terrainProgress = AppLocalization.string("未下载地形")
    @State private var terrainDownloading = false
    @State private var selectedPanel = surveyPreviewPanelFromArguments()
    @State private var applyingMission = false
    @State private var selectedVertexIndex: Int?
    @State private var simulatorOriginPickMode = false
    @State private var mapFocusGeneration = 0
    @State private var mapShouldFrameMission = false
    @State private var message = AppLocalization.string("点击地图依次添加至少 3 个边界点")
    @State private var showingImporter = false
    @State private var showingTerrainImporter = false
    @State private var showingBuildingHeightImporter = false
    @State private var showingClearConfirmation = false
    @State private var showingTerminateConfirmation = false
    @State private var showingObliqueAnglePicker = false
    @State private var showingMoreActions = ProcessInfo.processInfo.arguments.contains("--survey-ui-more-actions")
    @State private var pendingMissionDeletion: SurveyMissionVersion?
    @State private var exportDocument: SurveyMissionJSONDocument?
    @State private var exportFilename = "openfly-survey.json"
    @State private var showingExporter = false
    @State private var satelliteMapEnabled = false
    @State private var threeDimensionalMapEnabled = false
    @State private var replay: SurveyMissionReplay?
    @State private var replayPoint: SurveyGeoPoint?
    @State private var replayTask: Task<Void, Never>?
    @State private var didRestoreSession = false

    var body: some View {
        GeometryReader { proxy in
            let panelWidth = min(max(proxy.size.width * 0.36, 304), 380)
            // The planner deliberately renders its map background edge to edge,
            // but interactive content must not sit beneath a landscape notch.
            // `leading` is zero on devices without a cutout, so those devices
            // keep the existing full-width layout without a model-name check.
            let leadingSafeInset = proxy.safeAreaInsets.leading
            ZStack(alignment: .bottomLeading) {
                HStack(spacing: 0) {
                    map(leadingSafeInset: leadingSafeInset)
                    if flight.surveyPlannerPanelVisible {
                        Divider()
                        sidePanel
                            .frame(width: panelWidth)
                    }
                }
                if flight.liveCameraPreviewReady {
                    Button {
                        HapticFeedback.impact(.light)
                        returnToCamera()
                    } label: {
                        LiveCameraThumbnail()
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("返回相机主页")
                    .padding(14)
                    .padding(.leading, leadingSafeInset)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .ignoresSafeArea()
        }
        // This view can be presented either in its own cover or inline above
        // the dark flight HUD. Keep its semantic foreground colors paired with
        // the planner's intentionally light surfaces in both cases.
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json, .plainText]) { result in
            importResult(result)
        }
        .fileImporter(isPresented: $showingTerrainImporter, allowedContentTypes: [.tiff]) { result in
            importTerrainResult(result)
        }
        .fileImporter(isPresented: $showingBuildingHeightImporter, allowedContentTypes: [.tiff]) { result in
            importBuildingHeightResult(result)
        }
        .fileExporter(isPresented: $showingExporter, document: exportDocument,
                      contentType: .json, defaultFilename: exportFilename) { result in
            exportDocument = nil
            switch result {
            case let .success(url):
                message = AppLocalization.format("已导出 %@", url.lastPathComponent)
            case let .failure(error):
                message = AppLocalization.format("导出失败：%@", error.localizedDescription)
            }
        }
        .sheet(isPresented: $showingMoreActions) {
            moreActionsSheet
        }
        .confirmationDialog("清空航线", isPresented: $showingClearConfirmation,
                            titleVisibility: .visible) {
            Button("清空区域、航线和恢复点", role: .destructive) { clearROIConfirmed() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作会终止当前预演/执行，并删除当前区域、生成航线和已保存恢复点。")
        }
        .confirmationDialog("终止当前航线任务？", isPresented: $showingTerminateConfirmation,
                            titleVisibility: .visible) {
            Button("终止任务并释放控制", role: .destructive) {
                flight.abortSurvey()
                message = flight.surveyRuntime.snapshot.message
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("飞机将立即发送零速度并释放 Virtual Stick；本次任务断点会被清除。")
        }
        .confirmationDialog("删除任务版本", isPresented: Binding(
            get: { pendingMissionDeletion != nil },
            set: { if !$0 { pendingMissionDeletion = nil } }
        ), titleVisibility: .visible) {
            if let version = pendingMissionDeletion {
                Button("删除 \(version.missionName) r\(version.revision)", role: .destructive) {
                    pendingMissionDeletion = nil
                    delete(version)
                }
            }
            Button("取消", role: .cancel) { pendingMissionDeletion = nil }
        } message: {
            Text("删除后无法恢复，当前已载入的航线不会被清空。")
        }
        .confirmationDialog("五向倾斜俯角", isPresented: $showingObliqueAnglePicker,
                            titleVisibility: .visible) {
            ForEach([-30.0, -45.0, -60.0, -75.0], id: \.self) { angle in
                Button(angle == -45 ? "-45°（推荐）" : String(format: "%.0f°", angle)) {
                    obliqueGimbalPitch = angle
                    invalidateMission()
                    message = AppLocalization.format("五向倾斜俯角已设为 %.0f°", angle)
                }
            }
            Button("取消", role: .cancel) { }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--survey-ui-preview") {
                flight.surveyPlannerPanelVisible = true
            }
            if flight.telemetry.goHomeHeightMeters > 0 {
                requestedGoHomeHeight = Double(flight.telemetry.goHomeHeightMeters)
            }
            guard !didRestoreSession else { return }
            didRestoreSession = true
            restorePlannerSettings()
            if !OpenFlyBuildFeatures.terrainFollowing {
                terrainFollowingEnabled = false
                if selectedPanel == 3 { selectedPanel = 0 }
            }
            if ProcessInfo.processInfo.arguments.contains("--survey-ui-seed"), roi.isEmpty {
                do {
                    let value = try SurveyRegressionMissionFactory.create(
                        center: mapCenter, fiveDirection: true
                    )
                    apply(value, persistActive: false)
                    message = AppLocalization.string("Simulator UI 回归任务 · NO CONTROL")
                } catch {
                    message = AppLocalization.format("Simulator UI 回归任务失败：%@",
                                                     error.localizedDescription)
                }
            } else if let live = flight.surveyRuntime.liveMissionForPresentation {
                // A map/camera switch creates a new planner view while the
                // execution controller remains alive. Display that controller's
                // mission directly; disk restore is only for a genuinely new
                // runtime after relaunch.
                apply(live, persistActive: false)
                message = flight.surveyRuntime.snapshot.message
            } else if let restored = flight.restoreSurveyCheckpoint() {
                apply(restored)
                message = AppLocalization.string("已恢复上次航测断点，保持暂停；请复检后再继续")
            } else {
                do {
                    if let active = try library.restoreActive() {
                        apply(active, persistActive: false)
                        message = AppLocalization.string("已恢复上次生成或导入的航线")
                    }
                } catch {
                    message = AppLocalization.format("当前任务恢复失败：%@", error.localizedDescription)
                }
            }
        }
        .onChange(of: plannerSettingsFingerprint) { _ in
            persistPlannerSettings()
        }
        .onChange(of: flight.simulatorStatus.active) { active in
            if !active { simulatorOriginPickMode = false }
        }
        .onDisappear { replayTask?.cancel() }
    }

    private func map(leadingSafeInset: CGFloat) -> some View {
        ZStack(alignment: .top) {
            SurveyPlanningMap(
                roi: roi,
                mission: mission,
                aircraft: replayPoint ?? validAircraftPoint,
                remoteController: validRemoteControllerPoint,
                home: validHomePoint,
                simulatorOrigin: displayedSimulatorOrigin,
                aircraftHeading: displayedAircraftHeading,
                flying: displayedAircraftFlying,
                mapType: satelliteMapEnabled ? .satellite : .standard,
                threeDimensional: threeDimensionalMapEnabled,
                focusPoints: preferredMapFocusPoints,
                selectedVertexIndex: selectedVertexIndex,
                focusToken: "\(preferredMapFocusSource)-\(mapFocusGeneration)",
                execution: mapExecutionSnapshot,
                onTap: { point in
                    if simulatorOriginPickMode {
                        simulatorOriginPickMode = false
                        message = AppLocalization.string("正在切换仿真起点…")
                        HapticFeedback.selection()
                        flight.setSimulatorOriginFromSurveyMap(.init(
                            latitude: point.latitude, longitude: point.longitude
                        )) { _, resultMessage in
                            message = resultMessage
                        }
                        return
                    }
                    guard !editingLocked else {
                        message = AppLocalization.string("航线正在执行或已暂停待续飞；请先终止航线再编辑")
                        return
                    }
                    prepareForEditing()
                    HapticFeedback.selection()
                    switch SurveyBoundaryEditor.applyTap(
                        point, roi: &roi, selectedVertexIndex: &selectedVertexIndex
                    ) {
                    case let .moved(index):
                        message = AppLocalization.format("已移动边界点 %d；请重新生成航线", index + 1)
                    case .added:
                        message = AppLocalization.format("已添加第 %d 个边界点；至少需要 3 点", roi.count)
                    case let .limitReached(maximum):
                        message = AppLocalization.format("边界点最多 %d 个", maximum)
                        return
                    }
                    updateSuggestedRouteHeading()
                    invalidateMission()
                },
                onSelectVertex: {
                    HapticFeedback.selection()
                    selectedVertexIndex = $0
                }
            )
            .id(chinaMapCalibrationRaw)
            HStack(spacing: 6) {
                if mission != nil {
                    Button("全线") {
                        focusMissionOnMap()
                        message = AppLocalization.string("已适配显示完整航线")
                    }
                    .buttonStyle(SurveyMapToolButtonStyle())
                }
                Button(satelliteMapEnabled ? "街道" : "卫星") {
                    satelliteMapEnabled.toggle()
                }
                .buttonStyle(SurveyMapToolButtonStyle())
                Button(threeDimensionalMapEnabled ? "2D" : "3D") {
                    threeDimensionalMapEnabled.toggle()
                }
                .buttonStyle(SurveyMapToolButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.leading, 10 + leadingSafeInset)
            HStack(spacing: 6) {
                Button("返回") {
                    HapticFeedback.impact(.light)
                    returnToCamera()
                }
                .buttonStyle(SurveyMapToolButtonStyle())
                .accessibilityLabel("返回相机主页")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 10)
            .padding(.trailing, 10)
            if flight.simulatorStatus.active {
                Button(simulatorOriginPickMode ? "取消设置起点" : "设置仿真起点") {
                    simulatorOriginPickMode.toggle()
                    selectedVertexIndex = nil
                    message = AppLocalization.string(simulatorOriginPickMode
                        ? "请在地图点选仿真起点；本次点击不会添加航线边界点"
                        : "已取消设置仿真起点")
                }
                .buttonStyle(SurveyMapToolButtonStyle())
                .disabled(flight.simulatorChanging)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 52)
                .padding(.trailing, 10)
            }
            Button {
                guard !flight.surveyPlannerPanelVisible else { return }
                HapticFeedback.impact(.medium)
                withAnimation(.easeInOut(duration: 0.18)) {
                    flight.surveyPlannerPanelVisible = true
                }
            } label: {
                Text("航线")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 30)
                    .background(Color(red: 0.04, green: 0.055, blue: 0.075).opacity(0.90),
                                in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.22), lineWidth: 1))
            }
                .buttonStyle(HapticPlainButtonStyle())
                .accessibilityLabel(flight.surveyPlannerPanelVisible
                                    ? "航线规划面板已展开" : "展开航线规划面板")
                .padding(.top, 4)
                .allowsHitTesting(!flight.surveyPlannerPanelVisible)
            if let mapLocationStatusText {
                Text(LocalizedStringKey(mapLocationStatusText))
                    .font(.caption2.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(mission == nil ? "尚未生成航线" : missionHeadline))
                    .font(.caption.bold())
                Text(LocalizedStringKey(statisticsText))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(message))
                    .font(.caption2)
                    .foregroundStyle(message.contains("失败") || message.contains("阻止") ? .orange : .primary)
                    .lineLimit(2)
                Divider().opacity(0.55)
                compactFlightTelemetry
                if runtimeMapStatusVisible {
                    Divider().padding(.vertical, 2)
                    HStack(spacing: 5) {
                        Circle().fill(runtimeMapStatusColor).frame(width: 7, height: 7)
                        Text(LocalizedStringKey(runtimeMapTitle)).font(.caption.bold())
                    }
                    Text(LocalizedStringKey(runtimeMapTime))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(mapExecutionSnapshot.state == .paused
                                         ? Color.orange : Color(red: 0.04, green: 0.43, blue: 0.31))
                    Text(LocalizedStringKey(runtimeMapDetail))
                        .font(.system(size: 9))
                        .foregroundStyle(mapExecutionSnapshot.state == .paused ? .orange : .secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: 310, alignment: .leading)
            .padding(10)
            .background(Color(red: 0.91, green: 0.96, blue: 1).opacity(0.96),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.25)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 52)
            .padding(.leading, 12 + leadingSafeInset)
            if let terrain = mission?.terrainPlan {
                HStack(spacing: 7) {
                    Text(String(format: "相对高 %.0f m", terrain.minimumWaypointAltitudeMeters))
                    LinearGradient(colors: [.blue, .cyan, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 110, height: 7).clipShape(Capsule())
                    Text(String(format: "%.0f m", terrain.maximumWaypointAltitudeMeters))
                }
                .font(.caption2.monospacedDigit()).padding(.horizontal, 9).frame(height: 25)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                .padding(.top, 50)
            }
            VStack {
                Spacer()
                HStack {
                    Text(chinaMapCalibrationMode == .automatic
                         ? "任务 WGS‑84 · 中国地图已校准"
                         : "任务/地图 WGS‑84 · 中国校准关闭")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                    if let homeDirectionText {
                        Text(homeDirectionText)
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .padding(.trailing, 10)
                .padding(.leading, 10 + leadingSafeInset)
            }
        }
    }

    private var compactFlightTelemetry: some View {
        HStack(spacing: 12) {
            compactTelemetryMetric(
                icon: "speedometer",
                label: "速度",
                value: flight.telemetry.connected
                    ? String(format: "%.1f", max(0, flight.telemetry.horizontalSpeed))
                    : "--",
                unit: "m/s"
            )
            compactTelemetryMetric(
                icon: "arrow.up.and.down",
                label: "高度",
                value: flight.telemetry.connected
                    ? String(format: "%.1f", flight.telemetry.altitude)
                    : "--",
                unit: "m"
            )
            compactTelemetryMetric(
                icon: surveySignalIcon,
                label: "信号",
                value: flight.telemetry.remoteControllerConnected && flight.telemetry.signal > 0
                    ? "\(flight.telemetry.signal)"
                    : "--",
                unit: "%"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func compactTelemetryMetric(icon: String, label: LocalizedStringKey,
                                        value: String, unit: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 11)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(unit)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var surveySignalIcon: String {
        let signal = flight.telemetry.signal
        if !flight.telemetry.remoteControllerConnected || signal <= 0 { return "wifi.slash" }
        if signal <= 33 { return "wifi.exclamationmark" }
        return "wifi"
    }

    private var chinaMapCalibrationMode: ChinaMapCalibrationMode {
        ChinaMapCalibrationMode(rawValue: chinaMapCalibrationRaw) ?? .automatic
    }

    private var sidePanel: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()
            if selectedPanel != 4 { panelTabs }
            Group { selectedPanel == 4 ? AnyView(libraryPanel) : AnyView(parameterPanel) }
            if selectedPanel != 4 { actionDock }
        }
        .background(Color(red: 0.969, green: 0.973, blue: 0.98))
        .shadow(color: .black.opacity(0.18), radius: 12, x: -4)
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(selectedPanel == 4 ? "任务库" : "区域航线"))
                    .font(.title3.bold())
                TextField("任务名称", text: $missionName)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(selectedPanel == 4 || editingLocked)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showingMoreActions = true
            } label: {
                Image(systemName: "ellipsis").font(.headline)
            }
            .accessibilityLabel("更多航线操作")
            .buttonStyle(SurveyPanelButtonStyle(filled: false))
            .frame(width: 42)
            Button {
                HapticFeedback.impact(.light)
                withAnimation(.easeInOut(duration: 0.18)) {
                    flight.surveyPlannerPanelVisible = false
                }
            } label: {
                Image(systemName: "chevron.right").font(.headline)
            }
            .accessibilityLabel("收起航线规划面板")
            .buttonStyle(SurveyPanelButtonStyle(filled: false))
            .frame(width: 36)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.white)
    }

    private func returnToCamera() {
        flight.returnToCameraFromSurvey()
        // The production planner is embedded in ContentView and is removed by
        // `mapFullscreen = false`; dismissing that root environment can make
        // the whole scene inactive. Only the explicit QA full-screen cover
        // needs SwiftUI's presentation dismiss action.
        if ProcessInfo.processInfo.arguments.contains("--survey-ui-preview") {
            dismiss()
        }
    }

    private var moreActionsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("任务与文件")
                            .font(.headline)
                        Text("任务库是本机 App 内的历史记录；导出 JSON 才会保存到“文件”App，可用于分享或换设备导入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 8) {
                        moreActionButton(
                            "保存当前航线到任务库",
                            subtitle: "生成航线时也会自动保存；再次保存会新增 r1、r2…历史版本",
                            systemImage: "tray.and.arrow.down",
                            disabled: mission == nil
                        ) {
                            saveMission()
                            showingMoreActions = false
                        }
                        moreActionButton(
                            "打开任务库",
                            subtitle: "载入、导出或删除本机保存的历史版本",
                            systemImage: "tray.full",
                            disabled: editingLocked
                        ) {
                            selectedPanel = 4
                            showingMoreActions = false
                        }
                        moreActionButton(
                            "导入 JSON 文件",
                            subtitle: "从“文件”App 载入其他设备或之前导出的航线",
                            systemImage: "square.and.arrow.down",
                            disabled: editingLocked
                        ) {
                            presentAfterClosingMoreActions { showingImporter = true }
                        }
                        moreActionButton(
                            "导出当前航线为 JSON",
                            subtitle: "保存到“文件”App，之后可以分享或重新导入",
                            systemImage: "square.and.arrow.up",
                            disabled: mission == nil
                        ) {
                            guard let mission else { return }
                            presentAfterClosingMoreActions {
                                do {
                                    beginMissionExport(json: try SurveyMissionJSON.encode(mission),
                                                       suggestedFilename: mission.name)
                                } catch {
                                    message = AppLocalization.format("导出失败：%@", error.localizedDescription)
                                }
                            }
                        }
                    }

                    Text("地图与检查")
                        .font(.headline)
                    VStack(spacing: 8) {
                        moreActionButton(
                            threeDimensionalMapEnabled ? "切回 2D 地图" : "切换为 3D 地图",
                            subtitle: "只改变地图预览视角，不改变航线高度",
                            systemImage: threeDimensionalMapEnabled ? "map" : "view.3d"
                        ) {
                            threeDimensionalMapEnabled.toggle()
                        }
                        moreActionButton(
                            "真机准备度审计",
                            subtitle: "只检查当前状态，不会解锁或启动飞行",
                            systemImage: "checklist"
                        ) {
                            runReadinessAudit()
                            showingMoreActions = false
                        }
                        moreActionButton(
                            "云台诊断：俯视 -90°",
                            subtitle: "移动真实云台，请先确认周围安全",
                            systemImage: "camera.metering.center.weighted"
                        ) {
                            runGimbalDiagnostic(-90)
                            showingMoreActions = false
                        }
                        moreActionButton(
                            "云台诊断：倾斜 -45°",
                            subtitle: "移动真实云台，请先确认周围安全",
                            systemImage: "camera.metering.partial"
                        ) {
                            runGimbalDiagnostic(-45)
                            showingMoreActions = false
                        }
                        moreActionButton(
                            "停止航线预演",
                            subtitle: "仅停止地图预演，不会发送飞行控制",
                            systemImage: "stop.circle",
                            disabled: replay == nil
                        ) {
                            stopReplay(message: AppLocalization.string("预演已停止 · NO CONTROL"))
                            showingMoreActions = false
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle("更多航线操作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showingMoreActions = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func moreActionButton(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)
    }

    private func presentAfterClosingMoreActions(_ action: @escaping () -> Void) {
        showingMoreActions = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: action)
    }

    private var panelTabs: some View {
        HStack(spacing: 5) {
            panelTab("区域", index: 0)
            panelTab("飞行", index: 1)
            panelTab("影像", index: 2)
            if OpenFlyBuildFeatures.terrainFollowing {
                panelTab(terrainFollowingEnabled ? "仿地·开" : "仿地设置", index: 3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.white)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func panelTab(_ title: LocalizedStringKey, index: Int) -> some View {
        Button {
            HapticFeedback.selection()
            selectedPanel = index
        } label: {
            Text(title).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
        }
        .buttonStyle(SurveyPanelButtonStyle(tint: selectedPanel == index ? .blue : nil,
                                            filled: selectedPanel != index))
        .frame(height: 34)
    }

    private var parameterPanel: some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch selectedPanel {
                    case 1: flightParameterPanel
                    case 2: captureParameterPanel
                    case 3 where OpenFlyBuildFeatures.terrainFollowing: terrainParameterPanel
                    default: areaParameterPanel
                    }
                }
                .disabled(editingLocked)
                if let mission {
                    SurveyRuntimePanel(runtime: flight.surveyRuntime, mission: mission)
                } else if flight.surveyRuntime.snapshot.recoverableMissionName != nil {
                    Button("恢复上次航测断点") {
                        if let restored = flight.restoreSurveyCheckpoint() {
                            apply(restored)
                            message = AppLocalization.string("已恢复断点，保持暂停；请复检后再继续")
                        } else {
                            message = flight.surveyRuntime.snapshot.message
                        }
                    }
                    .buttonStyle(SurveyPanelButtonStyle(tint: .orange))
                    .padding(.top, 10)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder private var areaParameterPanel: some View {
        sectionTitle("规划区域")
        statusCard("在地图上依次点选至少 3 个边界点；点击已有顶点可选中并调整。", emphasized: true)
        sectionTitle("设备与采集方式")
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("DJI 飞行器").font(.subheadline.bold())
                Text(resolvedCamera.displayName).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(LocalizedStringKey(resolvedCamera.verifiedProfile ? "自动识别" : "固定相机"))
                .font(.caption.bold()).foregroundStyle(.blue)
        }
        .surveyField()
    }

    @ViewBuilder private var flightParameterPanel: some View {
        sectionTitle("飞行参数")
        compactNumberRow("飞行高度", value: $altitude, suffix: "m", decimals: 0)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("地面分辨率 GSD").font(.subheadline)
                Text("与飞行高度实时联动").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("2.25", value: gsdBinding,
                      format: .number.precision(.fractionLength(2)))
                .multilineTextAlignment(.trailing)
                .font(.subheadline.monospacedDigit())
                .textFieldStyle(.plain)
                .frame(width: 64)
            Text("cm/px").font(.caption2).foregroundStyle(.secondary)
        }.surveyField()
        compactNumberRow("目标面相对起飞点", value: $targetSurfaceOffset, suffix: "m", decimals: 0)
        compactNumberRow("安全起飞高度", value: $safeTakeoffAltitude, suffix: "m", decimals: 0)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("返航高度").font(.subheadline)
                Text(flight.telemetry.goHomeHeightMeters > 0
                     ? "飞控当前：\(flight.telemetry.goHomeHeightMeters) m" : "飞控当前：--")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("50", value: $requestedGoHomeHeight,
                      format: .number.precision(.fractionLength(0)))
                .multilineTextAlignment(.trailing)
                .font(.subheadline.monospacedDigit())
                .textFieldStyle(.plain)
                .frame(width: 56)
            Text("m").font(.caption).foregroundStyle(.secondary)
            Button("写入") { writeGoHomeHeight() }
                .buttonStyle(SurveyPanelButtonStyle(filled: false))
                .frame(width: 54)
        }.surveyField()
        compactPicker("起飞方式", selection: $takeoffMode) {
            Text("手动起飞（默认）").tag(SurveyTakeoffMode.manual)
            Text("任务自动起飞（仅仿真）").tag(SurveyTakeoffMode.autoSimulatorOnly)
        }
        compactPicker("高度模式", selection: $altitudeMode) {
            Text("目标面上方").tag(SurveyAltitudeMode.aboveTargetSurface)
            Text("相对起飞点").tag(SurveyAltitudeMode.relativeToTakeoff)
        }
        compactPicker("航线起点", selection: $startPointMode) {
            Text("自动就近").tag(SurveyStartPointMode.autoNearest)
            Text("角点 1").tag(SurveyStartPointMode.firstRouteStart)
            Text("角点 2").tag(SurveyStartPointMode.routeCorner2)
            Text("角点 3").tag(SurveyStartPointMode.routeCorner3)
            Text("角点 4").tag(SurveyStartPointMode.routeCorner4)
        }
        compactNumberRow("航线方向", value: $heading, suffix: "°", decimals: 0)
        compactPicker("倾斜机头策略", selection: $obliqueHeadingMode) {
            Text("机头沿航迹（不倒飞）").tag(SurveyObliqueHeadingMode.trackRoute)
            Text("固定观察方向（可倒/侧飞）").tag(SurveyObliqueHeadingMode.fixedCaptureDirection)
        }
        compactPicker("任务完成后", selection: $completionAction) {
            Text("返航").tag(SurveyCompletionAction.returnToHome)
            Text("悬停").tag(SurveyCompletionAction.hover)
            Text("返回航线起点").tag(SurveyCompletionAction.returnToRouteStart)
        }
        compactNumberRow("上升速度", value: $takeoffSpeed, suffix: "m/s", decimals: 1)
        compactNumberRow("下降速度", value: $descentSpeed, suffix: "m/s", decimals: 1)
        compactNumberRow("飞行速度", value: $speed, suffix: "m/s", decimals: 1)
        if collectionMode == .obliqueFiveDirection || mission?.activeMapping != nil {
            compactNumberRow("倾斜速度", value: $obliqueSpeed, suffix: "m/s", decimals: 1)
        }
        Text(cameraSpeedLimitText).font(.caption2).foregroundStyle(.secondary).surveyField()
        compactNumberRow("倾斜前向重叠率", value: $obliqueForwardOverlap, suffix: "%", decimals: 0)
        compactNumberRow("倾斜旁向重叠率", value: $obliqueSideOverlap, suffix: "%", decimals: 0)
    }

    @ViewBuilder private var captureParameterPanel: some View {
        sectionTitle("影像覆盖")
        compactPicker("拍照触发", selection: $captureTriggerMode) {
            Text("等距离拍照").tag(SurveyCaptureTriggerMode.distance)
            Text("定时拍照").tag(SurveyCaptureTriggerMode.time)
        }
        if captureTriggerMode == .time {
            compactNumberRow("定时拍照间隔", value: $timedCaptureInterval, suffix: "s", decimals: 1)
        }
        compactNumberRow("前向重叠率", value: $forwardOverlap, suffix: "%", decimals: 0)
        compactNumberRow("旁向重叠率", value: $sideOverlap, suffix: "%", decimals: 0)
        compactNumberRow("边界外扩", value: $margin, suffix: "m", decimals: 0)
        compactNumberRow("倾斜采集俯角", value: $obliqueGimbalPitch, suffix: "°", decimals: 0)
    }

    @ViewBuilder private var terrainParameterPanel: some View {
        sectionTitle("相对地面高")
        Toggle("启用仿地飞行（关闭 = 普通定高）", isOn: $terrainFollowingEnabled)
            .surveyField()
            .onChange(of: terrainFollowingEnabled) { enabled in
                guard !applyingMission else { return }
                prepareForEditing()
                invalidateMission()
                message = enabled
                    ? (terrainDownload == nil && localTerrain == nil
                       ? "已选择仿地；请下载/导入高程数据后重新生成航线"
                       : "已启用仿地；高程数据保留，重新生成航线后生效")
                    : "已切回普通定高；高程数据仍保留，但不会参与航线生成"
            }
        Text("1 下载/导入高程 → 2 核对数据与坐标 → 3 点“应用到航线”。")
            .font(.caption2).foregroundStyle(.secondary)
        HStack(spacing: 5) {
            Button("导入表面 DSM") { showingTerrainImporter = true }
                .buttonStyle(SurveyPanelButtonStyle(filled: false))
            Button(terrainDownloading ? "下载中…" : "下载裸地 DEM") { downloadGlobalTerrain() }
                .buttonStyle(SurveyPanelButtonStyle(filled: false))
                .disabled(terrainDownloading || roi.count < 3)
            Button(buildingHeightTemplate.isEmpty ? "建筑高度文件" : "下载建筑高度") {
                if buildingHeightTemplate.isEmpty { showingBuildingHeightImporter = true }
                else { downloadBuildingHeight() }
            }
                .buttonStyle(SurveyPanelButtonStyle(filled: false))
        }
        .padding(.top, 6)
        compactPicker("高程数据类型", selection: $terrainKind) {
            Text("DSM（含建筑/树冠）").tag(SurveyTerrainKind.surfaceDSM)
            Text("DEM/DTM（仅裸地）").tag(SurveyTerrainKind.bareDEM)
        }
        Text(terrainProgress).font(.caption2).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).surveyField()
        Toggle("已核对：表面 DSM 为近期数据，建筑位置与规划区对齐",
               isOn: $terrainAlignmentConfirmed)
            .font(.caption2)
            .surveyField()
            .disabled(terrainKind == .bareDEM)
        Button {
            applyTerrainToMission()
        } label: {
            Label("应用到航线", systemImage: "point.3.connected.trianglepath.dotted")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SurveyPanelButtonStyle(tint: .blue))
        .disabled(!canApplyTerrainToMission)
        Text(terrainApplyHint)
            .font(.caption2)
            .foregroundColor(canApplyTerrainToMission ? .blue : .secondary)
        Text("真机仿地必须核验近期表面 DSM 与建筑位置；未核验数据只允许预演/仿真。")
            .font(.system(size: 9)).foregroundStyle(.orange)
    }

    private var libraryPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Button("返回航线") { selectedPanel = 0 }
                    .buttonStyle(SurveyPanelButtonStyle(filled: false))
                Button("导入 JSON") { showingImporter = true }
                    .buttonStyle(SurveyPanelButtonStyle(filled: false))
                    .disabled(editingLocked)
                Spacer()
                Text("最多保留 \(SurveyMissionLibrary.maxVersions) 个版本")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = library.persistenceError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if library.versions.isEmpty {
                Spacer(); Text("尚无已保存任务").foregroundStyle(.secondary); Spacer()
            } else {
                List {
                    ForEach(library.versions, id: \.versionID) { version in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(version.missionName).font(.subheadline.bold()).lineLimit(1)
                                Spacer(); Text("r\(version.revision)").font(.caption.monospacedDigit())
                            }
                            Text(Date(timeIntervalSince1970: Double(version.savedAtEpochMillis) / 1_000),
                                 style: .date)
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                Button("载入") { load(version) }
                                    .buttonStyle(.bordered)
                                    .disabled(editingLocked)
                                Button {
                                    beginMissionExport(
                                        json: version.missionJSON,
                                        suggestedFilename: "\(version.missionName)-r\(version.revision)"
                                    )
                                } label: {
                                    Label("导出", systemImage: "square.and.arrow.up")
                                }.buttonStyle(.bordered)
                                Spacer()
                                Button(role: .destructive) { pendingMissionDeletion = version } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                                .disabled(editingLocked)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.white)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(red: 0.969, green: 0.973, blue: 0.98))
    }

    private var actionDock: some View {
        VStack(spacing: 5) {
            if selectedPanel == 0 {
                HStack(spacing: 5) {
                    dockButton("定位飞机") {
                        mapShouldFrameMission = false
                        mapFocusGeneration += 1
                        message = preferredMapFocusMessage
                    }
                    dockButton("撤销", enabled: !roi.isEmpty && !editingLocked) { undoLastVertex() }
                    dockButton("删除选中点", enabled: selectedVertexIndex != nil && !editingLocked) { deleteSelectedVertex() }
                    dockButton("清空", enabled: (!roi.isEmpty || mission != nil) && !editingLocked) {
                        showingClearConfirmation = true
                    }
                }
            }
            if selectedPanel == 2 {
                VStack(alignment: .leading, spacing: 3) {
                    if mission?.activeMapping != nil {
                        Text("主动补缺分组（修改后需重新安全预检）")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                dockButton("全选", enabled: !editingLocked,
                                           tint: activeRecaptureSelectedGroupIDs.count == activeRecaptureGroups.count ? .blue : nil) {
                                    applyActiveRecaptureGroups(Set(activeRecaptureGroups.map(\.groupID)))
                                }
                                ForEach(activeRecaptureGroups) { group in
                                    dockButton("\(group.order). \(group.label) · \(group.suggestedSurveyPhotos)张",
                                               enabled: !editingLocked,
                                               tint: activeRecaptureSelectedGroupIDs.contains(group.groupID) ? .orange : nil) {
                                        toggleActiveRecaptureGroup(group.groupID)
                                    }
                                }
                            }
                        }
                    } else {
                    Text("执行航带（颜色与地图航线一致，点选后立即更新任务）")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(SurveyCaptureView.allCases.filter { $0 != .localOblique }, id: \.self) { view in
                            HStack(spacing: 3) {
                                Circle().fill(SurveyRoutePalette.color(for: view))
                                    .frame(width: 7, height: 7)
                                Text(shortCaptureViewTitle(view)).font(.system(size: 8))
                            }
                        }
                    }
                    HStack(spacing: 3) {
                        ForEach(SurveyCaptureView.allCases.filter { $0 != .localOblique }, id: \.self) { view in
                            dockButton(shortCaptureViewTitle(view),
                                       enabled: !editingLocked,
                                       tint: enabledCaptureViews.contains(view)
                                           ? SurveyRoutePalette.color(for: view) : nil) {
                                toggleCaptureView(view)
                            }
                        }
                    }
                    }
                }
            }
            if selectedPanel != 0 && selectedPanel != 4 && mission?.activeMapping == nil {
                HStack(spacing: 5) {
                    dockButton("生成正射航线", enabled: roi.count >= 3 && !editingLocked, tint: .blue) {
                        collectionMode = .ortho
                        generateMission()
                    }
                    dockButton(collectionMode == .obliqueFiveDirection
                               ? "生成所选 \(enabledCaptureViews.count) 组" : "生成五向倾斜",
                               enabled: roi.count >= 3 && !editingLocked,
                               tint: Color(red: 0.37, green: 0.42, blue: 0.48)) {
                        collectionMode = .obliqueFiveDirection
                        generateMission()
                    }
                    dockButton(String(format: "俯角 %.0f°", obliqueGimbalPitch),
                               enabled: roi.count >= 3 && !editingLocked) {
                        showingObliqueAnglePicker = true
                    }
                }
            }
            HStack(spacing: 5) {
                dockButton(replay == nil ? "预演" : "停止预演",
                           enabled: mission != nil && !editingLocked) {
                    toggleReplay()
                }
                dockButton("安全预检", enabled: mission != nil) {
                    if let mission { _ = flight.preflightSurvey(mission); message = flight.surveyRuntime.snapshot.message }
                }
                dockButton(runtimePrimaryActionTitle,
                           enabled: mission != nil, tint: .blue) {
                    guard let mission else { return }
                    switch flight.surveyRuntime.snapshot.state {
                    case .paused: flight.resumeSurvey()
                    case .arming, .running: flight.pauseSurvey()
                    default: flight.startSurveySimulator(mission)
                    }
                    message = flight.surveyRuntime.snapshot.message
                }
                if runtimeCanStop {
                    dockButton("终止任务", tint: .red) {
                        showingTerminateConfirmation = true
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white)
        .overlay(alignment: .top) { Divider() }
    }

    private func dockButton(_ title: String, enabled: Bool = true, tint: Color? = nil,
                            action: @escaping () -> Void) -> some View {
        Button {
            HapticFeedback.impact(.light)
            action()
        } label: {
            Text(LocalizedStringKey(title)).lineLimit(1).minimumScaleFactor(0.72).frame(maxWidth: .infinity)
        }
        .buttonStyle(SurveyPanelButtonStyle(tint: tint))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.42)
    }

    private func toggleCaptureView(_ view: SurveyCaptureView) {
        if enabledCaptureViews.contains(view) {
            guard enabledCaptureViews.count > 1 else {
                message = AppLocalization.string("至少保留 1 组航线")
                return
            }
            enabledCaptureViews.remove(view)
        } else {
            enabledCaptureViews.insert(view)
        }
        if let current = mission,
           current.constraints.collectionMode == .obliqueFiveDirection {
            if captureSelectionSourceMission == nil
                || !(captureSelectionSourceMission?.constraints.enabledCaptureViews
                    .isSuperset(of: enabledCaptureViews) ?? false) {
                captureSelectionSourceMission = current
            }
            do {
                guard let source = captureSelectionSourceMission else { return }
                mission = try SurveyMissionCaptureViewFilter.select(
                    source, enabledViews: enabledCaptureViews
                )
                message = AppLocalization.format("已生成所选 %d 组航线", enabledCaptureViews.count)
                if let mission {
                    do {
                        try library.persistActive(mission)
                        let saved = try library.save(mission)
                        message += " · 已自动保存 r\(saved.revision)"
                    } catch {
                        message += " · 保存失败：\(error.localizedDescription)"
                    }
                }
                return
            } catch {
                message = AppLocalization.format("无法应用所选航带：%@", error.localizedDescription)
                return
            }
        }
        message = AppLocalization.format("五向执行组：%d 组；点击“生成五向倾斜”应用",
                                         enabledCaptureViews.count)
    }

    private var activeRecaptureGroups: [ActiveRecaptureMissionGroup] {
        guard let source = activeRecaptureSourceMission ?? mission else { return [] }
        return ActiveRecaptureMissionGroupCatalog.groups(for: source)
    }

    private var activeRecaptureSelectedGroupIDs: Set<String> {
        guard let source = activeRecaptureSourceMission ?? mission, let mission else { return [] }
        return ActiveRecaptureMissionGroupCatalog.selectedGroupIDs(source: source, selected: mission)
    }

    private func toggleActiveRecaptureGroup(_ groupID: String) {
        var selection = activeRecaptureSelectedGroupIDs
        if selection.contains(groupID) {
            guard selection.count > 1 else {
                message = AppLocalization.string("至少保留 1 个补缺组")
                return
            }
            selection.remove(groupID)
        } else {
            selection.insert(groupID)
        }
        applyActiveRecaptureGroups(selection)
    }

    private func applyActiveRecaptureGroups(_ selection: Set<String>) {
        guard !editingLocked, let current = mission,
              let source = activeRecaptureSourceMission ?? current.activeMapping.map({ _ in current }) else {
            message = AppLocalization.string("当前不是可编辑的主动补缺任务")
            return
        }
        do {
            let filtered = try ActiveRecaptureMissionRegionFilter.selectGroups(
                source, selectedGroupIDs: selection
            )
            activeRecaptureSourceMission = source
            apply(filtered, persistActive: false)
            try library.persistActive(filtered)
            let saved = try library.save(filtered)
            message = AppLocalization.format("已选择 %d/%d 个补缺组 · 已保存 r%d · 请重新安全预检",
                                             selection.count, activeRecaptureGroups.count,
                                             saved.revision)
        } catch {
            message = AppLocalization.format("补缺分组应用失败：%@", error.localizedDescription)
        }
    }

    private func activeRecaptureSourceContains(_ selected: SurveyMission) -> Bool {
        guard let source = activeRecaptureSourceMission,
              let sourceMetadata = source.activeMapping,
              let selectedMetadata = selected.activeMapping else { return false }
        return Set(selectedMetadata.regions.map(\.regionID))
            .isSubset(of: Set(sourceMetadata.regions.map(\.regionID)))
    }

    private func toggleReplay() {
        if replay != nil {
            stopReplay(message: AppLocalization.string("预演已停止 · NO CONTROL"))
            return
        }
        guard let mission else { return }
        do {
            let value = try SurveyMissionReplay(mission: mission)
            replay = value
            _ = value.start()
            message = AppLocalization.string("只读预演运行中 · NO CONTROL")
            replayTask = Task { @MainActor in
                while !Task.isCancelled, let active = replay {
                    let snapshot = active.advance()
                    replayPoint = snapshot.point
                    message = AppLocalization.format("只读预演 %.0f%% · 航带 %d · NO CONTROL",
                                                     snapshot.progress * 100,
                                                     snapshot.passIndex + 1)
                    if snapshot.state == .completed {
                        replay = nil; replayPoint = nil; replayTask = nil
                        message = AppLocalization.string("只读预演完成 · NO CONTROL")
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        } catch { message = AppLocalization.format("预演失败：%@", error.localizedDescription) }
    }

    private func stopReplay(message newMessage: String?) {
        replayTask?.cancel()
        replayTask = nil
        replay = nil
        replayPoint = nil
        if let newMessage { message = newMessage }
    }

    private func runGimbalDiagnostic(_ degrees: Double) {
        guard !runtimeCanPauseOrResume else {
            message = AppLocalization.string("请先终止航线，再执行云台诊断")
            return
        }
        guard flight.telemetry.connected else {
            message = AppLocalization.string("云台诊断失败：飞机未连接")
            return
        }
        flight.setSurveyGimbalPitch(degrees)
        message = AppLocalization.format("已发送云台 %.0f°；请核对实际俯角", degrees)
    }

    private func writeGoHomeHeight() {
        let rounded = requestedGoHomeHeight.rounded()
        guard requestedGoHomeHeight.isFinite,
              abs(rounded - requestedGoHomeHeight) < 0.001 else {
            message = AppLocalization.string("返航高度写入失败：请输入整数")
            return
        }
        let meters = Int(rounded)
        guard (20...500).contains(meters) else {
            message = AppLocalization.string("返航高度写入失败：必须在 20–500 m")
            return
        }
        guard flight.telemetry.connected else {
            message = AppLocalization.string("返航高度写入失败：飞控未连接")
            return
        }
        guard !flight.telemetry.flying else {
            message = AppLocalization.string("返航高度写入失败：请在地面设置")
            return
        }
        let missionMaximum = mission?.waypoints.map(\.point.altitudeMeters).max()
        if let missionMaximum, Double(meters) + 0.5 < missionMaximum {
            message = AppLocalization.format("返航高度写入失败：不得低于任务最高高度 %.0f m",
                                             missionMaximum)
            return
        }
        message = AppLocalization.format("正在写入返航高度 %d m…", meters)
        Task { @MainActor in
            do {
                try await flight.setSurveyGoHomeHeight(meters)
                requestedGoHomeHeight = Double(meters)
                message = AppLocalization.format("返航高度已写入：%d m", meters)
            } catch {
                message = AppLocalization.format("返航高度写入失败：%@", error.localizedDescription)
            }
        }
    }

    private func runReadinessAudit() {
        let telemetry = flight.telemetry
        let report = SurveyRealFlightReadiness.evaluate(
            mission: mission,
            telemetry: .init(
                connected: telemetry.connected,
                flightStateFresh: abs(telemetry.flightStateTimestamp.timeIntervalSinceNow) <= 1.5,
                flying: telemetry.flying,
                simulatorActive: telemetry.simulatorActive,
                batteryPercent: telemetry.aircraftBattery,
                rcBatteryPercent: telemetry.rcBattery,
                rcSignalPercent: telemetry.signal,
                satelliteCount: telemetry.satellites,
                gpsSignalUsable: (3...5).contains(telemetry.gpsSignalLevel),
                homeLocationValid: telemetry.homeLocationSet,
                latitude: telemetry.aircraft.latitude,
                longitude: telemetry.aircraft.longitude,
                goHomeHeightMeters: telemetry.goHomeHeightMeters,
                maxFlightHeightMeters: telemetry.maxFlightHeightMeters,
                maxFlightRadiusMeters: telemetry.maxFlightRadiusMeters,
                maxFlightRadiusEnabled: telemetry.maxFlightRadiusEnabled
            ),
            evidence: .init(simulatorRegressionPassed: false, failsafeRegressionPassed: false,
                            fruBenchDirectionVerified: false, cameraCalibrated: false,
                            operatingAreaReviewed: false)
        )
        message = report.readyForReview
            ? "真机准备度审计通过（仅报告，不会解锁）"
            : "真机准备度阻止：" + report.blocks.map(\.rawValue).sorted().joined(separator: " · ")
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.top, 13)
            .padding(.bottom, 6)
    }

    private func statusCard(_ text: LocalizedStringKey, emphasized: Bool) -> some View {
        Text(text)
            .font(emphasized ? .caption : .caption2)
            .foregroundStyle(emphasized ? Color(red: 0.22, green: 0.33, blue: 0.43) : .secondary)
            .frame(maxWidth: .infinity, minHeight: emphasized ? 48 : 40, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(emphasized ? Color(red: 0.91, green: 0.96, blue: 1) : .white,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(emphasized ? Color.blue.opacity(0.24) : Color.black.opacity(0.08)))
            .padding(.bottom, 6)
    }

    private func compactPicker<Selection: Hashable, Content: View>(
        _ title: LocalizedStringKey, selection: Binding<Selection>, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Picker(selection: selection, content: content, label: { Text(title) }).pickerStyle(.menu).tint(.blue)
        }
        .surveyField()
        .onChange(of: selection.wrappedValue) { _ in
            if !applyingMission { invalidateMission() }
        }
    }

    private func compactNumberRow(_ title: LocalizedStringKey, value: Binding<Double>, suffix: String,
                                  decimals: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline)
            Spacer()
            TextField("0", value: value,
                      format: .number.precision(.fractionLength(decimals...decimals)))
                .multilineTextAlignment(.trailing)
                .font(.subheadline.monospacedDigit())
                .textFieldStyle(.plain)
                .frame(width: 76)
                .onChange(of: value.wrappedValue) { _ in
                    if !applyingMission { invalidateMission() }
                }
            Text(suffix).font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
        }
        .surveyField()
    }

    private var statisticsText: String {
        guard let mission else {
            return AppLocalization.string("统计：生成航线后显示照片、存储和架次估算")
        }
        return AppLocalization.format("统计：%d 张照片 · %.0f m · 约 %.1f min",
                                      mission.estimatedPhotoCount, mission.estimatedPathMeters,
                                      mission.estimatedFlightSeconds / 60)
    }

    private var missionHeadline: String {
        guard let mission else { return "尚未生成航线" }
        let mode: String
        switch mission.constraints.collectionMode {
        case .ortho: mode = AppLocalization.string("正射")
        case .crosshatchNadir: mode = AppLocalization.string("交叉正射")
        case .obliqueFiveDirection:
            mode = AppLocalization.format("五向倾斜 · %d组", mission.constraints.enabledCaptureViews.count)
        }
        return AppLocalization.format("%@ · GSD %.2f cm/px · 航点高 %.1f m",
                                      mode, estimatedGSDCentimeters,
                                      mission.constraints.effectiveFlightAltitudeMeters)
    }

    private var estimatedGSDCentimeters: Double {
        var value = SurveyConstraints()
        value.altitudeMetersAgl = altitude
        value.forwardOverlap = forwardOverlap / 100
        value.sideOverlap = sideOverlap / 100
        return SurveyCoveragePlanner.coverage(camera: resolvedCamera.profile,
                                              constraints: value).groundSampleDistanceCentimeters
    }

    private var cameraSpeedLimitText: String {
        var value = SurveyConstraints()
        value.altitudeMetersAgl = altitude
        value.forwardOverlap = forwardOverlap / 100
        value.speedMetersPerSecond = speed
        value.obliqueSpeedMetersPerSecond = obliqueSpeed
        value.collectionMode = collectionMode
        value.captureTriggerMode = captureTriggerMode
        value.timedCaptureIntervalSeconds = timedCaptureInterval
        guard let limit = try? SurveyCoveragePlanner.speedLimit(camera: resolvedCamera.profile,
                                                                 constraints: value) else {
            return AppLocalization.string("航测硬上限 10.0 m/s；正在计算相机上限")
        }
        return AppLocalization.format("航测硬上限 10.0 m/s · 相机有效上限 %.1f m/s",
                                      limit.effectiveMaximumMetersPerSecond)
    }

    private var runtimeCanPauseOrResume: Bool {
        SurveyPlannerSafetyPolicy.editingLocked(for: flight.surveyRuntime.snapshot.state)
    }

    private var runtimeCanStop: Bool {
        SurveyPlannerSafetyPolicy.canTerminate(flight.surveyRuntime.snapshot.state)
    }

    private var editingLocked: Bool {
        SurveyPlannerSafetyPolicy.editingLocked(for: flight.surveyRuntime.snapshot.state)
    }

    private var runtimePauseTitle: String {
        flight.surveyRuntime.snapshot.state == .paused ? "继续" : "暂停"
    }

    private var runtimePrimaryActionTitle: String {
        switch flight.surveyRuntime.snapshot.state {
        case .paused: return "继续"
        case .arming, .running: return "暂停"
        default: return "执行"
        }
    }

    private func toggleRuntimePause() {
        HapticFeedback.impact(.medium)
        if flight.surveyRuntime.snapshot.state == .paused { flight.resumeSurvey() }
        else { flight.pauseSurvey() }
    }

    private func undoLastVertex() {
        guard !roi.isEmpty else { return }
        prepareForEditing()
        SurveyBoundaryEditor.undoLastVertex(
            roi: &roi, selectedVertexIndex: &selectedVertexIndex
        )
        updateSuggestedRouteHeading()
        invalidateMission()
        message = AppLocalization.string("已撤销最后一个边界点")
    }

    private func deleteSelectedVertex() {
        guard let index = selectedVertexIndex, roi.indices.contains(index) else { return }
        prepareForEditing()
        SurveyBoundaryEditor.deleteSelectedVertex(
            roi: &roi, selectedVertexIndex: &selectedVertexIndex
        )
        updateSuggestedRouteHeading()
        invalidateMission()
        message = AppLocalization.format("已删除边界点 %d", index + 1)
    }

    private func clearROIConfirmed() {
        prepareForEditing()
        roi.removeAll()
        selectedVertexIndex = nil
        invalidateMission()
        message = AppLocalization.string("已清空；点击地图依次添加规划区边界点")
    }

    private func prepareForEditing() {
        stopReplay(message: nil)
        if runtimeCanPauseOrResume { flight.abortSurvey() }
    }

    private func invalidateMission() {
        mission = nil
        library.clearActive()
    }

    private var plannerSettingsFingerprint: String {
        [missionName, altitude.description, speed.description, obliqueSpeed.description,
         forwardOverlap.description,
         sideOverlap.description, heading.description, margin.description,
         targetSurfaceOffset.description, safeTakeoffAltitude.description,
         takeoffSpeed.description, descentSpeed.description, obliqueForwardOverlap.description,
         obliqueSideOverlap.description, obliqueGimbalPitch.description,
         timedCaptureInterval.description, captureTriggerMode.rawValue,
         startPointMode.rawValue, altitudeMode.rawValue, takeoffMode.rawValue,
         collectionMode.rawValue, completionAction.rawValue, obliqueHeadingMode.rawValue,
         enabledCaptureViews.map(\.rawValue).sorted().joined(separator: ","),
         terrainFollowingEnabled.description].joined(separator: "|")
    }

    private func persistPlannerSettings() {
        let payload = SurveyPlannerSettingsPayload(
            missionName: missionName, altitude: altitude, speed: speed,
            obliqueSpeed: obliqueSpeed,
            forwardOverlap: forwardOverlap, sideOverlap: sideOverlap, heading: heading,
            margin: margin, targetSurfaceOffset: targetSurfaceOffset,
            safeTakeoffAltitude: safeTakeoffAltitude, takeoffSpeed: takeoffSpeed,
            descentSpeed: descentSpeed,
            obliqueForwardOverlap: obliqueForwardOverlap,
            obliqueSideOverlap: obliqueSideOverlap,
            obliqueGimbalPitch: obliqueGimbalPitch,
            timedCaptureInterval: timedCaptureInterval,
            captureTriggerMode: captureTriggerMode.rawValue,
            startPointMode: startPointMode.rawValue, altitudeMode: altitudeMode.rawValue,
            takeoffMode: takeoffMode.rawValue, collectionMode: collectionMode.rawValue,
            completionAction: completionAction.rawValue,
            obliqueHeadingMode: obliqueHeadingMode.rawValue,
            enabledCaptureViews: enabledCaptureViews.map(\.rawValue).sorted(),
            terrainFollowingEnabled: terrainFollowingEnabled
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: "openfly.survey.planner-settings.v1")
    }

    private func restorePlannerSettings() {
        guard let data = UserDefaults.standard.data(forKey: "openfly.survey.planner-settings.v1"),
              let value = try? JSONDecoder().decode(SurveyPlannerSettingsPayload.self, from: data),
              value.schemaVersion == 1 else { return }
        missionName = value.missionName
        altitude = value.altitude; speed = value.speed
        obliqueSpeed = value.obliqueSpeed ?? value.speed
        forwardOverlap = value.forwardOverlap; sideOverlap = value.sideOverlap
        heading = value.heading; margin = value.margin
        targetSurfaceOffset = value.targetSurfaceOffset
        safeTakeoffAltitude = value.safeTakeoffAltitude; takeoffSpeed = value.takeoffSpeed
        descentSpeed = value.descentSpeed ?? 2
        obliqueForwardOverlap = value.obliqueForwardOverlap
        obliqueSideOverlap = value.obliqueSideOverlap
        obliqueGimbalPitch = value.obliqueGimbalPitch
        timedCaptureInterval = value.timedCaptureInterval
        if let decoded = SurveyCaptureTriggerMode(rawValue: value.captureTriggerMode) { captureTriggerMode = decoded }
        if let decoded = SurveyStartPointMode(rawValue: value.startPointMode) { startPointMode = decoded }
        if let decoded = SurveyAltitudeMode(rawValue: value.altitudeMode) { altitudeMode = decoded }
        if let decoded = SurveyTakeoffMode(rawValue: value.takeoffMode) { takeoffMode = decoded }
        if let decoded = SurveyCollectionMode(rawValue: value.collectionMode) { collectionMode = decoded }
        if let decoded = SurveyCompletionAction(rawValue: value.completionAction) { completionAction = decoded }
        if let decoded = SurveyObliqueHeadingMode(rawValue: value.obliqueHeadingMode) { obliqueHeadingMode = decoded }
        let views = Set(value.enabledCaptureViews.compactMap(SurveyCaptureView.init(rawValue:)))
        if !views.isEmpty { enabledCaptureViews = views }
        terrainFollowingEnabled = OpenFlyBuildFeatures.terrainFollowing
            && value.terrainFollowingEnabled
    }

    private func updateSuggestedRouteHeading() {
        guard roi.count >= 3,
              let suggestion = try? SurveyPlanner.suggestedRouteHeading(roi) else { return }
        heading = suggestion
    }

    private func missionSummary(_ value: SurveyMission) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("航线摘要").font(.subheadline.bold())
            Text("\((try? value.surveyPasses().count) ?? 0) 条测线 · \(value.estimatedPhotoCount) 张照片")
            Text(String(format: "%.0f m · 约 %.1f min", value.estimatedPathMeters,
                        value.estimatedFlightSeconds / 60))
            if let speedLimit = try? SurveyCoveragePlanner.speedLimit(
                camera: value.cameraProfile, constraints: value.constraints
            ), speedLimit.cameraLimited {
                Text(String(format: "相机节拍限速 %.1f m/s", speedLimit.effectiveMaximumMetersPerSecond))
                    .foregroundStyle(speedLimit.exceeded ? .red : .orange)
            }
            Text("执行环境自动选择：DJI Simulator 激活时走仿真；否则仅允许真机手动起飞、稳定悬停后执行。")
                .font(.caption2).foregroundStyle(.orange)
        }
        .font(.caption.monospacedDigit())
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.08)))
        .padding(.top, 10)
    }

    private var validAircraftPoint: SurveyGeoPoint? {
        let point = flight.telemetry.aircraft
        // The provider clears location validity at a real product/session
        // boundary. Do not additionally hide a still-valid aircraft marker
        // because the coarse connection flag flickered for one UI update.
        if flight.telemetry.aircraftLocationValid,
           validCoordinate(point.latitude, point.longitude) {
            return .init(latitude: point.latitude, longitude: point.longitude,
                         altitudeMeters: max(0, flight.telemetry.altitude))
        }
        return SurveySimulatorMapProjection.point(from: flight.simulatorStatus)
    }

    private var displayedAircraftHeading: Double {
        !flight.telemetry.aircraftLocationValid
            && flight.simulatorStatus.active && flight.simulatorStatus.stateReceived
            ? flight.simulatorStatus.yawDegrees : flight.telemetry.heading
    }

    private var displayedAircraftFlying: Bool {
        flight.simulatorStatus.active ? flight.simulatorStatus.flying : flight.telemetry.flying
    }

    private var runtimeMapStatusVisible: Bool {
        let state = mapExecutionSnapshot.state
        return state == .arming || state == .running || state == .paused
    }

    private var runtimeMapTitle: String {
        let snapshot = mapExecutionSnapshot
        let state = AppLocalization.string(snapshot.state == .paused ? "航线暂停" : "航线执行")
        let phase: String
        switch snapshot.phase {
        case .safeClimb: phase = AppLocalization.string("安全爬升")
        case .transitToStart: phase = AppLocalization.string("飞向起始点")
        case .recoveryToPause: phase = AppLocalization.string("返回暂停点")
        case .survey: phase = AppLocalization.string("航测采集")
        case .returnHome: phase = AppLocalization.string("返回 Home")
        case .returnToStart: phase = AppLocalization.string("返回航线起点")
        case nil: phase = AppLocalization.string("准备控制")
        }
        return AppLocalization.format("%@ · %@ · %d/%d", state, phase,
                                      min(snapshot.legIndex + 1, max(1, snapshot.legCount)),
                                      max(1, snapshot.legCount))
    }

    private var runtimeMapTime: String {
        let snapshot = mapExecutionSnapshot
        let section = AppLocalization.string(snapshot.phase == .survey ? "当前航带" : "当前阶段")
        return AppLocalization.format("%@ %@  ·  整体 %@", section,
                                      mapDuration(snapshot.currentSectionRemainingSeconds),
                                      mapDuration(snapshot.totalRemainingSeconds))
    }

    private var runtimeMapDetail: String {
        let snapshot = mapExecutionSnapshot
        if snapshot.state == .paused {
            return AppLocalization.format("暂停原因：%@", AppLocalization.string(snapshot.message))
        }
        return AppLocalization.format("实时 %.1f m/s · 垂直 %+.1f m/s · 已拍 %d · 已计入转弯",
                                      flight.telemetry.horizontalSpeed,
                                      flight.telemetry.verticalSpeed, snapshot.photoCount)
    }

    private var runtimeMapStatusColor: Color {
        switch mapExecutionSnapshot.state {
        case .running: return .green
        case .arming, .paused: return .orange
        case .aborted: return .red
        default: return .secondary
        }
    }

    private func mapDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let value = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var validRemoteControllerPoint: SurveyGeoPoint? {
        let point = flight.telemetry.remoteController
        let source = flight.telemetry.remoteControllerLocationSource
        guard !source.contains("等待"), !source.contains("默认"),
              validCoordinate(point.latitude, point.longitude) else { return nil }
        return .init(latitude: point.latitude, longitude: point.longitude)
    }

    private var validHomePoint: SurveyGeoPoint? {
        let point = flight.telemetry.home
        guard flight.telemetry.connected, flight.telemetry.homeLocationSet,
              validCoordinate(point.latitude, point.longitude) else { return nil }
        return .init(latitude: point.latitude, longitude: point.longitude)
    }

    private var displayedSimulatorOrigin: SurveyGeoPoint? {
        guard flight.simulatorStatus.active, let point = flight.savedSimulatorOrigin,
              validCoordinate(point.latitude, point.longitude) else { return nil }
        return .init(latitude: point.latitude, longitude: point.longitude)
    }

    private var mapCenter: SurveyGeoPoint {
        validAircraftPoint ?? validRemoteControllerPoint
            ?? mission?.roi.first ?? roi.first
            ?? .init(
                latitude: OpenFlyDemoLocation.shanghaiCityCenterLatitude,
                longitude: OpenFlyDemoLocation.shanghaiCityCenterLongitude
            )
    }

    /// Simulator-only visual harness for checking the active-leg overlay
    /// without ever arming Virtual Stick or mutating the production runtime.
    private var mapExecutionSnapshot: SurveyRuntimeSnapshot {
        let live = flight.surveyRuntime.snapshot
        guard live.state == .idle,
              ProcessInfo.processInfo.arguments.contains("--survey-ui-execution-preview"),
              let mission, !mission.waypoints.isEmpty else { return live }
        let index = min(max(1, mission.waypoints.count / 3), mission.waypoints.count - 1)
        var preview = live
        preview.state = .running
        preview.phase = .survey
        preview.legIndex = index
        preview.legCount = mission.waypoints.count
        preview.waypointIndex = index
        preview.currentTarget = mission.waypoints[index]
        preview.currentSectionRemainingSeconds = 42
        preview.totalRemainingSeconds = 210
        preview.message = "Simulator 执行高亮预览 · NO CONTROL"
        return preview
    }

    private var surveyTakeoffReference: SurveyGeoPoint {
        SurveyPlannerSafetyPolicy.takeoffReference(
            home: validHomePoint, aircraft: validAircraftPoint, fallback: mapCenter
        )
    }

    private var preferredMapFocusSource: String {
        if mapShouldFrameMission, mission != nil { return "MISSION" }
        if validAircraftPoint != nil { return "AIRCRAFT" }
        if validRemoteControllerPoint != nil {
            return flight.telemetry.remoteControllerLocationSource == "遥控器 GPS" ? "REMOTE_CONTROLLER" : "PHONE"
        }
        if mission != nil { return "MISSION" }
        if !roi.isEmpty { return "ROI" }
        return "DEFAULT"
    }

    private var preferredMapFocusPoints: [SurveyGeoPoint] {
        if mapShouldFrameMission, let mission {
            return mission.roi + mission.waypoints.map(\.point)
        }
        if let value = validAircraftPoint { return [value] }
        if let value = validRemoteControllerPoint { return [value] }
        if let mission { return mission.roi }
        if !roi.isEmpty { return roi }
        return [.init(
            latitude: OpenFlyDemoLocation.shanghaiCityCenterLatitude,
            longitude: OpenFlyDemoLocation.shanghaiCityCenterLongitude
        )]
    }

    private var preferredMapFocusMessage: String {
        switch preferredMapFocusSource {
        case "AIRCRAFT": return AppLocalization.string("已定位到飞机")
        case "REMOTE_CONTROLLER": return AppLocalization.string("飞机位置不可用，已定位到遥控器")
        case "PHONE": return AppLocalization.string("飞机/遥控器 GPS 不可用，已定位到 iPhone")
        case "MISSION": return AppLocalization.string("无实时定位，已显示当前航线")
        case "ROI": return AppLocalization.string("无实时定位，已显示规划区域")
        default: return AppLocalization.string("等待飞机、遥控器或 iPhone 定位")
        }
    }

    private var mapLocationStatusText: String? {
        if validAircraftPoint != nil { return nil }
        if validRemoteControllerPoint != nil {
            return preferredMapFocusSource == "PHONE"
                ? AppLocalization.string("iPhone 定位\n等待飞机/遥控器 GPS") : nil
        }
        return AppLocalization.string("等待飞机/遥控器定位")
    }

    private var homeDirectionText: String? {
        guard flight.telemetry.flying, let aircraft = validAircraftPoint, let home = validHomePoint else { return nil }
        let north = (home.latitude - aircraft.latitude) * 111_132
        let east = (home.longitude - aircraft.longitude) * 111_320
            * cos((home.latitude + aircraft.latitude) / 2 * .pi / 180)
        let bearingValue = atan2(east, north) * 180 / .pi
        let bearing = bearingValue < 0 ? bearingValue + 360 : bearingValue
        let arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
        let arrow = arrows[Int(((bearing + 22.5) / 45).rounded(.down)) % arrows.count]
        return String(format: "H %@ %.0f m", arrow, hypot(north, east))
    }

    private func validCoordinate(_ latitude: Double, _ longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude)
            && (-180...180).contains(longitude)
            && (abs(latitude) > 1e-9 || abs(longitude) > 1e-9)
    }

    private func createRegressionArea() {
        do {
            let value = try SurveyRegressionMissionFactory.create(
                center: mapCenter, fiveDirection: collectionMode == .obliqueFiveDirection
            )
            roi = value.roi
            selectedVertexIndex = nil
            heading = value.constraints.routeHeadingDegrees
            invalidateMission()
            message = AppLocalization.string("已生成当前位置附近 50×40m 回归区域")
        } catch {
            message = AppLocalization.format("回归区域生成失败：%@", error.localizedDescription)
        }
    }

    private func generateMission() {
        do {
            if !OpenFlyBuildFeatures.terrainFollowing {
                terrainFollowingEnabled = false
            }
            try SurveyPlannerSafetyPolicy.validateTerrainSource(
                enabled: terrainFollowingEnabled,
                hasLocalTerrain: localTerrain != nil && localTerrainSHA256 != nil,
                hasDownloadedTerrain: terrainDownload != nil
            )
            if terrainFollowingEnabled, terrainKind == .surfaceDSM,
               !terrainAlignmentConfirmed {
                throw SurveyValidationError.invalid("请先在地图高程图层核对建筑物和坐标对齐，再勾选 DSM 确认")
            }
            let terrainTakeoffReference: SurveyTerrainTakeoffReference? = {
                let capturedAt = Int64(Date().timeIntervalSince1970 * 1_000)
                if let home = validHomePoint {
                    return .init(point: home, source: .homeLocation, capturedAtEpochMillis: capturedAt)
                }
                if let aircraft = validAircraftPoint {
                    return .init(point: aircraft, source: .aircraftLocation, capturedAtEpochMillis: capturedAt)
                }
                return nil
            }()
            if terrainFollowingEnabled, terrainTakeoffReference == nil {
                throw SurveyValidationError.invalid("仿地航线必须先取得真实 Home 或飞机 GPS；不能用 ROI/遥控器位置代替起飞高程基准")
            }
            let takeoffReference = terrainTakeoffReference?.point ?? surveyTakeoffReference
            let sourceKind: SurveyTerrainSourceKind = terrainKind == .bareDEM ? .bareEarth : .surfaceDSM
            var constraints = try SurveyParameterPolicy.createConstraints(
                altitudeMetersAgl: altitude, routeHeadingDegrees: heading,
                forwardOverlapPercent: forwardOverlap, sideOverlapPercent: sideOverlap,
                speedMetersPerSecond: speed,
                obliqueSpeedMetersPerSecond: obliqueSpeed,
                gimbalPitchDegrees: collectionMode == .obliqueFiveDirection ? obliqueGimbalPitch : -90,
                boundaryMarginMeters: margin,
                obliqueFiveDirection: collectionMode == .obliqueFiveDirection,
                targetSurfaceToTakeoffMeters: targetSurfaceOffset,
                safeTakeoffAltitudeMeters: safeTakeoffAltitude,
                takeoffSpeedMetersPerSecond: takeoffSpeed,
                descentSpeedMetersPerSecond: descentSpeed,
                obliqueForwardOverlapPercent: obliqueForwardOverlap,
                obliqueSideOverlapPercent: obliqueSideOverlap,
                altitudeMode: altitudeMode,
                startPointMode: startPointMode,
                completionAction: completionAction,
                captureTriggerMode: captureTriggerMode,
                timedCaptureIntervalSeconds: timedCaptureInterval,
                takeoffMode: takeoffMode,
                enabledCaptureViews: enabledCaptureViews,
                obliqueHeadingMode: obliqueHeadingMode
            )
            constraints.collectionMode = collectionMode
            constraints.crosshatch = collectionMode == .crosshatchNadir
            constraints.completionAction = completionAction
            constraints.obliqueHeadingMode = obliqueHeadingMode
            constraints.enabledCaptureViews = enabledCaptureViews
            let value = try SurveyPlanner.plan(
                name: missionName.trimmingCharacters(in: .whitespacesAndNewlines),
                roi: roi, camera: resolvedCamera.profile, constraints: constraints,
                takeoffPoint: takeoffReference
            )
            if terrainFollowingEnabled, let localTerrain, let localTerrainSHA256 {
                mission = try SurveyTerrainPlanner.apply(to: value, terrain: localTerrain,
                    takeoffPoint: takeoffReference, sourceSHA256: localTerrainSHA256,
                    takeoffReference: terrainTakeoffReference, sourceKind: sourceKind).mission
                message = AppLocalization.string("本地 DSM 仿地航线已生成；首次仍需仿真和人工核验")
            } else if terrainFollowingEnabled, let terrainDownload {
                let height: (any TerrainElevationSource)? = buildingHeightDownload?.terrain ?? localBuildingHeight
                if let height {
                    let surface = try CompositeSurfaceElevationSource(terrain: terrainDownload.terrain,
                                                                       heightAboveGround: height)
                    let heightHash = buildingHeightDownload?.sha256 ?? localBuildingHeightSHA256 ?? ""
                    let combinedHash = SurveyTerrainPlanner.sha256(Data("\(terrainDownload.sha256):\(heightHash)".utf8))
                    mission = try SurveyTerrainPlanner.apply(to: value, terrain: surface,
                        takeoffPoint: takeoffReference, sourceSHA256: combinedHash,
                        takeoffReference: terrainTakeoffReference, sourceKind: .surfaceDSM,
                        bareEarthBaseSHA256: terrainDownload.sha256).mission
                    message = AppLocalization.string("全球地形 + 建筑高度仿地航线已生成；仅允许预览/仿真")
                } else {
                    mission = try SurveyTerrainPlanner.apply(to: value, terrain: terrainDownload.terrain,
                        takeoffPoint: takeoffReference, sourceSHA256: terrainDownload.sha256,
                        takeoffReference: terrainTakeoffReference, sourceKind: sourceKind).mission
                    message = AppLocalization.string("全球地形仿地航线已生成；仅允许预览/仿真")
                }
            } else {
                mission = value
                message = AppLocalization.string("普通航线已生成，尚未发送到飞机")
            }
            activeRecaptureSourceMission = nil
            captureSelectionSourceMission = mission?.constraints.collectionMode == .obliqueFiveDirection
                ? mission : nil
            if let mission {
                do {
                    try library.persistActive(mission)
                    let saved = try library.save(mission)
                    message += AppLocalization.format(" · 已自动保存 r%d", saved.revision)
                } catch {
                    message += AppLocalization.format(" · 保存失败：%@", error.localizedDescription)
                }
                focusMissionOnMap()
            }
        } catch { message = AppLocalization.format("生成失败：%@", error.localizedDescription) }
    }

    private func saveMission() {
        guard let mission else { return }
        do {
            let saved = try library.save(mission)
            message = AppLocalization.format("已保存 %@ r%d", saved.missionName, saved.revision)
        } catch { message = AppLocalization.format("保存失败：%@", error.localizedDescription) }
    }

    private func beginMissionExport(json: String, suggestedFilename: String) {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = suggestedFilename
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "openfly-survey" : cleaned
        exportFilename = base.lowercased().hasSuffix(".json") ? base : "\(base).json"
        exportDocument = SurveyMissionJSONDocument(json: json)
        showingExporter = true
    }

    private func load(_ version: SurveyMissionVersion) {
        guard !editingLocked else {
            message = AppLocalization.string("航线正在执行或已暂停待续飞；请先终止航线再载入任务")
            return
        }
        do {
            let value = try version.mission()
            stopReplay(message: nil)
            apply(value)
            selectedPanel = 0
            message = AppLocalization.format("已载入 %@ r%d", version.missionName, version.revision)
        } catch { message = AppLocalization.format("载入失败：%@", error.localizedDescription) }
    }

    private func delete(_ version: SurveyMissionVersion) {
        do {
            try library.delete(versionID: version.versionID)
            message = AppLocalization.string("已删除任务版本")
        } catch { message = AppLocalization.format("删除失败：%@", error.localizedDescription) }
    }

    private func importResult(_ result: Result<URL, Error>) {
        guard !editingLocked else {
            message = AppLocalization.string("航线正在执行或已暂停待续飞；请先终止航线再导入任务")
            return
        }
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let raw = try String(contentsOf: url, encoding: .utf8)
            let value = try library.importMissionJSON(raw)
            if value.activeMapping != nil { _ = try ActiveRecaptureMissionValidator.validate(value) }
            stopReplay(message: nil)
            apply(value)
            selectedPanel = 0
            message = AppLocalization.string("任务已校验、导入并保存")
        } catch { message = AppLocalization.format("导入失败：%@", error.localizedDescription) }
    }

    private func apply(_ value: SurveyMission, persistActive: Bool = true) {
        guard OpenFlyBuildFeatures.terrainFollowing || value.terrainPlan == nil else {
            message = AppLocalization.string("当前发布版本未启用仿地飞行，不能载入带 terrainPlan 的任务")
            return
        }
        applyingMission = true
        mission = value; roi = value.roi; missionName = value.name
        focusMissionOnMap()
        selectedVertexIndex = nil
        altitude = value.constraints.altitudeMetersAgl
        speed = value.constraints.speedMetersPerSecond
        obliqueSpeed = value.constraints.obliqueSpeedMetersPerSecond
        forwardOverlap = value.constraints.forwardOverlap * 100
        sideOverlap = value.constraints.sideOverlap * 100
        heading = value.constraints.routeHeadingDegrees
        margin = value.constraints.boundaryMarginMeters
        targetSurfaceOffset = value.constraints.targetSurfaceToTakeoffMeters
        safeTakeoffAltitude = value.constraints.safeTakeoffAltitudeMeters
        takeoffSpeed = value.constraints.takeoffSpeedMetersPerSecond
        descentSpeed = value.constraints.descentSpeedMetersPerSecond
        obliqueForwardOverlap = value.constraints.obliqueForwardOverlap * 100
        obliqueSideOverlap = value.constraints.obliqueSideOverlap * 100
        obliqueGimbalPitch = value.constraints.obliqueGimbalPitchDegrees
        captureTriggerMode = value.constraints.captureTriggerMode
        timedCaptureInterval = value.constraints.timedCaptureIntervalSeconds
        startPointMode = value.constraints.startPointMode
        altitudeMode = value.constraints.altitudeMode
        takeoffMode = value.constraints.takeoffMode
        collectionMode = value.constraints.collectionMode
        completionAction = value.constraints.completionAction
        obliqueHeadingMode = value.constraints.obliqueHeadingMode
        enabledCaptureViews = value.constraints.enabledCaptureViews
        captureSelectionSourceMission = value.activeMapping == nil
            && value.constraints.collectionMode == .obliqueFiveDirection
            ? value : nil
        if value.activeMapping == nil {
            activeRecaptureSourceMission = nil
        } else if activeRecaptureSourceMission == nil || !activeRecaptureSourceContains(value) {
            activeRecaptureSourceMission = value
        }
        terrainFollowingEnabled = value.terrainPlan != nil
        if persistActive {
            do { try library.persistActive(value) }
            catch { message = AppLocalization.format("当前任务保存失败：%@", error.localizedDescription) }
        }
        // SwiftUI delivers the field onChange callbacks during the following
        // render pass. Keep invalidation suppressed until that pass completes;
        // otherwise loading/importing a valid mission immediately clears it.
        DispatchQueue.main.async { applyingMission = false }
    }

    private func focusMissionOnMap() {
        mapShouldFrameMission = true
        mapFocusGeneration &+= 1
    }

    private func downloadGlobalTerrain() {
        terrainDownloading = true
        terrainProgress = AppLocalization.string("准备下载全球地形…")
        let area = roi
        Task {
            do {
                let downloader = try GlobalTerrainDownloader()
                let result = try await downloader.download(roi: area) { completed, total in
                    await MainActor.run {
                        terrainProgress = AppLocalization.format("地形瓦片 %d/%d", completed, total)
                    }
                }
                await MainActor.run {
                    terrainDownload = result; localTerrain = nil; localTerrainSHA256 = nil
                    terrainKind = hasBuildingHeightSource ? .surfaceDSM : .bareDEM
                    terrainAlignmentConfirmed = false; terrainFollowingEnabled = false
                    terrainDownloading = false
                    terrainProgress = AppLocalization.format(
                        "裸地 DEM 已就绪：下载 %d，缓存 %d；请核对后点“应用到航线”",
                        result.downloadedTiles, result.cachedTiles
                    )
                }
            } catch {
                await MainActor.run {
                    terrainDownloading = false
                    terrainProgress = AppLocalization.format("下载失败：%@", error.localizedDescription)
                }
            }
        }
    }

    private func applyTerrainToMission() {
        guard roi.count >= 3 else {
            message = AppLocalization.string("请先在地图上添加至少 3 个边界点")
            return
        }
        guard hasApplicableTerrainSource else {
            message = AppLocalization.string(terrainKind == .surfaceDSM
                ? "表面 DSM 需要导入 DSM，或同时准备裸地 DEM 与建筑高度"
                : "请先下载裸地 DEM")
            return
        }
        guard terrainKind == .bareDEM || terrainAlignmentConfirmed else {
            message = AppLocalization.string("请先核对表面 DSM 与规划区坐标，并勾选对齐确认")
            return
        }
        applyingMission = true
        terrainFollowingEnabled = true
        generateMission()
        DispatchQueue.main.async { applyingMission = false }
    }

    private func downloadBuildingHeight() {
        terrainDownloading = true
        terrainProgress = AppLocalization.string("准备下载建筑高度…")
        let area = roi, template = buildingHeightTemplate
        UserDefaults.standard.set(template, forKey: "openfly.survey.building-height-template")
        Task {
            do {
                let downloader = try GlobalBuildingHeightDownloader()
                let result = try await downloader.download(roi: area, template: template) { completed, total in
                    await MainActor.run {
                        terrainProgress = AppLocalization.format("建筑高度分块 %d/%d", completed, total)
                    }
                }
                await MainActor.run {
                    buildingHeightDownload = result; localBuildingHeight = nil; localBuildingHeightSHA256 = nil
                    terrainKind = .surfaceDSM; terrainAlignmentConfirmed = false
                    terrainFollowingEnabled = false; terrainDownloading = false
                    terrainProgress = AppLocalization.format(
                        "建筑高度已就绪：下载 %d，缓存 %d；请核对后点“应用到航线”",
                        result.downloadedTiles, result.cachedTiles
                    )
                }
            } catch {
                await MainActor.run {
                    terrainDownloading = false
                    terrainProgress = AppLocalization.format("建筑高度下载失败：%@",
                                                             error.localizedDescription)
                }
            }
        }
    }

    private func importTerrainResult(_ result: Result<URL, Error>) {
        do {
            let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let terrain = try GeoTIFFTerrain.read(data, displayName: url.lastPathComponent)
            _ = try roi.map { try terrain.elevationMeters(latitude: $0.latitude, longitude: $0.longitude) }
            localTerrain = terrain; localTerrainSHA256 = SurveyTerrainPlanner.sha256(data); terrainDownload = nil
            terrainKind = .surfaceDSM; terrainAlignmentConfirmed = false
            terrainFollowingEnabled = false
            terrainProgress = AppLocalization.format(
                "已导入 %@ · EPSG:%d · %d×%d；请核对后点“应用到航线”",
                url.lastPathComponent, terrain.info.epsg, terrain.info.width, terrain.info.height
            )
        } catch {
            localTerrain = nil; localTerrainSHA256 = nil
            terrainProgress = AppLocalization.format("DSM 导入失败：%@", error.localizedDescription)
        }
    }

    private func importBuildingHeightResult(_ result: Result<URL, Error>) {
        do {
            let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let terrain = try GeoTIFFTerrain.read(data, displayName: url.lastPathComponent)
            let values = try roi.map { try terrain.elevationMeters(latitude: $0.latitude, longitude: $0.longitude) }
            guard values.allSatisfy({ $0 >= 0 }) else { throw SurveyValidationError.invalid("建筑相对高度不能为负数") }
            localBuildingHeight = terrain; localBuildingHeightSHA256 = SurveyTerrainPlanner.sha256(data)
            buildingHeightDownload = nil; terrainFollowingEnabled = false
            terrainKind = .surfaceDSM; terrainAlignmentConfirmed = false
            terrainProgress = AppLocalization.format(
                "已导入建筑相对高度 %@；请先下载裸地 DEM，再点“应用到航线”",
                url.lastPathComponent
            )
        } catch {
            localBuildingHeight = nil; localBuildingHeightSHA256 = nil
            terrainProgress = AppLocalization.format("建筑高度导入失败：%@",
                                                     error.localizedDescription)
        }
    }

    private var hasBuildingHeightSource: Bool {
        buildingHeightDownload != nil
            || (localBuildingHeight != nil && localBuildingHeightSHA256 != nil)
    }

    private var hasApplicableTerrainSource: Bool {
        switch terrainKind {
        case .surfaceDSM:
            return (localTerrain != nil && localTerrainSHA256 != nil)
                || (terrainDownload != nil && hasBuildingHeightSource)
        case .bareDEM:
            return terrainDownload != nil
        }
    }

    private var canApplyTerrainToMission: Bool {
        !editingLocked && !terrainDownloading && roi.count >= 3
            && hasApplicableTerrainSource
            && (terrainKind == .bareDEM || terrainAlignmentConfirmed)
    }

    private var terrainApplyHint: String {
        if terrainDownloading { return AppLocalization.string("等待高程数据准备完成") }
        if roi.count < 3 { return AppLocalization.string("请先在地图上添加至少 3 个边界点") }
        if !hasApplicableTerrainSource {
            return AppLocalization.string(terrainKind == .surfaceDSM
                ? "请导入表面 DSM，或准备裸地 DEM + 建筑高度"
                : "请先下载裸地 DEM")
        }
        if terrainKind == .surfaceDSM && !terrainAlignmentConfirmed {
            return AppLocalization.string("核对图层后勾选上方的 DSM 对齐确认")
        }
        return AppLocalization.string("数据已就绪；点击后会启用仿地并重新生成航线")
    }

    private var resolvedCamera: SurveyCameraProfileCatalog.Resolution {
        SurveyCameraProfileCatalog.resolve(flight.telemetry.productModel,
                                           flight.telemetry.cameraModel)
    }

    private var gsdBinding: Binding<Double> {
        .init(get: { estimatedGSDCentimeters }, set: { value in
            guard let converted = try? SurveyCoveragePlanner.altitudeForGroundSampleDistance(
                camera: resolvedCamera.profile,
                groundSampleDistanceCentimeters: value
            ), converted.isFinite else {
                message = AppLocalization.string("GSD 必须为有效正数")
                return
            }
            altitude = converted
            invalidateMission()
            message = AppLocalization.format("GSD %.2f cm/px → 飞行高度 %.1f m", value, converted)
        })
    }

    private func captureViewBinding(_ view: SurveyCaptureView) -> Binding<Bool> {
        .init(get: { enabledCaptureViews.contains(view) }, set: { enabled in
            if enabled { enabledCaptureViews.insert(view) }
            else if enabledCaptureViews.count > 1 { enabledCaptureViews.remove(view) }
            invalidateMission()
        })
    }

    private func captureViewTitle(_ view: SurveyCaptureView) -> String {
        switch view {
        case .nadir: return "正射"
        case .forwardOblique: return "前倾"
        case .backwardOblique: return "后倾"
        case .leftOblique: return "左倾"
        case .rightOblique: return "右倾"
        case .localOblique: return "局部倾斜"
        }
    }

    private func shortCaptureViewTitle(_ view: SurveyCaptureView) -> String {
        switch view {
        case .nadir: return "1 俯"
        case .forwardOblique: return "2 前"
        case .backwardOblique: return "3 后"
        case .leftOblique: return "4 左"
        case .rightOblique: return "5 右"
        case .localOblique: return "局部"
        }
    }
}

private struct SurveyFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minHeight: 43)
            .padding(.horizontal, 11)
            .background(.white, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.07)))
            .padding(.bottom, 2)
    }
}

private extension View {
    func surveyField() -> some View { modifier(SurveyFieldModifier()) }
}

private struct SurveyPanelButtonStyle: ButtonStyle {
    var tint: Color?
    var filled: Bool

    init(tint: Color? = nil, filled: Bool = true) {
        self.tint = tint
        self.filled = filled
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint == nil ? Color.primary : Color.white)
            .frame(maxWidth: .infinity, minHeight: 34)
            .padding(.horizontal, 5)
            .background(tint ?? (filled ? Color.white : Color(red: 0.965, green: 0.97, blue: 0.977)),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(tint == nil ? Color.black.opacity(0.12) : Color.black.opacity(0.06)))
            .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.1),
                    radius: configuration.isPressed ? 1 : 2, y: 1)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
    }
}

private struct SurveyRuntimePanel: View {
    @ObservedObject var runtime: SurveyRuntimeController
    var mission: SurveyMission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("航线执行状态").font(.subheadline.bold())
                Spacer()
                Text(LocalizedStringKey(runtime.snapshot.state.rawValue))
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(stateColor)
            }
            Text(AppLocalization.string(runtime.snapshot.message))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let seconds = runtime.snapshot.lowBatteryReturnSeconds {
                HStack {
                    Text("低电量：\(seconds) 秒后自动返航")
                        .font(.caption2.bold()).foregroundStyle(.red)
                    Spacer()
                    Button("立即返航") { runtime.issueLowBatteryReturnNow() }
                        .buttonStyle(.borderedProminent).tint(.red)
                }
            }
            if runtime.snapshot.legCount > 0 {
                Text(AppLocalization.format("段 %d/%d · h %.2fm · v %+.2fm · 已拍 %d",
                                            runtime.snapshot.legIndex + 1,
                                            runtime.snapshot.legCount,
                                            runtime.snapshot.horizontalErrorMeters,
                                            runtime.snapshot.verticalErrorMeters,
                                            runtime.snapshot.photoCount))
                    .font(.caption2.monospacedDigit())
                Text("本段剩余 \(duration(runtime.snapshot.currentSectionRemainingSeconds)) · 全部剩余 \(duration(runtime.snapshot.totalRemainingSeconds))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("操作统一放在底部：预演 / 安全预检 / 执行。Simulator 激活时执行仿真；否则要求真机手动起飞并稳定悬停。人工介入会自动暂停、归零、释放控制并保存断点。")
                .font(.system(size: 9)).foregroundStyle(.orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.08)))
        .padding(.top, 8)
    }

    private var stateColor: Color {
        switch runtime.snapshot.state {
        case .running: return .green
        case .arming, .paused: return .orange
        case .aborted: return .red
        default: return .secondary
        }
    }

    private func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "--:--" }
        let value = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct SurveyPlanningMap: UIViewRepresentable {
    var roi: [SurveyGeoPoint]
    var mission: SurveyMission?
    var aircraft: SurveyGeoPoint?
    var remoteController: SurveyGeoPoint?
    var home: SurveyGeoPoint?
    var simulatorOrigin: SurveyGeoPoint?
    var aircraftHeading: Double
    var flying: Bool
    var mapType: MKMapType
    var threeDimensional: Bool
    var focusPoints: [SurveyGeoPoint]
    var selectedVertexIndex: Int?
    var focusToken: String
    var execution: SurveyRuntimeSnapshot
    var onTap: (SurveyGeoPoint) -> Void
    var onSelectVertex: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.showsCompass = false
        view.pointOfInterestFilter = .excludingAll
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateRemoteControllerCourse(remoteController)
        if context.coordinator.lastMapType != mapType {
            context.coordinator.lastMapType = mapType
            view.mapType = mapType
        }
        // Mission and ROI overlays are static while telemetry is updating.
        // Rebuilding every line on every 25 Hz runtime/UI tick caused visible
        // flashing, temporary missing route sections while zooming, and large
        // unnecessary CPU/GPU load. Only rebuild when the actual plan changes.
        if context.coordinator.lastROI != roi || context.coordinator.lastMission != mission {
            view.removeOverlays(context.coordinator.staticOverlays)
            var overlays: [MKOverlay] = []
            if let mission,
               let coverage = try? SurveyPlanner.groundCoverage(mission),
               coverage.boundary.count >= 3 {
                let coordinates = coverage.boundary.map {
                    surveyMapCoordinate($0)
                }
                overlays.append(SurveyCoveragePolygon(
                    coordinates: coordinates, count: coordinates.count
                ))
            }
            if let mission,
               let target = try? SurveyPlanner.targetArea(mission),
               target.boundary.count >= 3 {
                let coordinates = target.boundary.map {
                    surveyMapCoordinate($0)
                }
                overlays.append(SurveyTargetPolygon(
                    coordinates: coordinates, count: coordinates.count
                ))
            }
            if roi.count >= 3 {
                let coordinates = roi.map {
                    surveyMapCoordinate($0)
                }
                overlays.append(SurveyROIPolygon(coordinates: coordinates, count: coordinates.count))
            }
            if let mission, mission.waypoints.count >= 2,
               let passes = try? mission.surveyPasses() {
                let terrain = mission.terrainPlan
                let altitudeSpan = terrain.map {
                    max(0.001, $0.maximumWaypointAltitudeMeters - $0.minimumWaypointAltitudeMeters)
                }
                var previousEnd: SurveyWaypoint?
                for pass in passes {
                    if let previousEnd {
                        var transit = [previousEnd, pass.start].map {
                            surveyMapCoordinate($0.point)
                        }
                        overlays.append(SurveyRoutePolyline(
                            coordinates: &transit, count: 2,
                            captureView: nil, style: .transit
                        ))
                    }
                    let captureView = pass.start.captureView
                    if let terrain, let altitudeSpan {
                        for (start, end) in zip(pass.waypoints, pass.waypoints.dropFirst()) {
                            var coordinates = [start, end].map {
                                surveyMapCoordinate($0.point)
                            }
                            overlays.append(SurveyRoutePolyline(
                                coordinates: &coordinates, count: 2,
                                captureView: captureView, style: .captureView
                            ))
                            let fraction = ((start.point.altitudeMeters + end.point.altitudeMeters) / 2
                                            - terrain.minimumWaypointAltitudeMeters) / altitudeSpan
                            overlays.append(SurveyRoutePolyline(
                                coordinates: &coordinates, count: 2,
                                captureView: captureView, style: .altitude,
                                altitudeFraction: fraction
                            ))
                        }
                    } else {
                        let coordinates = pass.waypoints.map {
                            surveyMapCoordinate($0.point)
                        }
                        overlays.append(SurveyRoutePolyline(
                            coordinates: coordinates, count: coordinates.count,
                            captureView: captureView, style: .captureView
                        ))
                    }
                    previousEnd = pass.end
                }
            }
            context.coordinator.staticOverlays = overlays
            context.coordinator.lastROI = roi
            context.coordinator.lastMission = mission
            view.addOverlays(overlays)
        }
        context.coordinator.syncHomeDirection(
            aircraft: flying ? aircraft : nil, home: flying ? home : nil, in: view
        )
        context.coordinator.syncActiveRoute(mission: mission, execution: execution, in: view)
        context.coordinator.syncExecutionOverlay(
            aircraft: aircraft, execution: execution, in: view
        )
        var annotationValues: [(key: String, point: SurveyGeoPoint, title: String,
                                kind: SurveyMapAnnotation.Kind, vertexIndex: Int?, heading: Double?)] = []
        for (index, point) in roi.enumerated() {
            annotationValues.append(("boundary-\(index)", point, "边界 \(index + 1)",
                                     .boundary, index, nil))
        }
        if let mission, let first = mission.waypoints.first {
            annotationValues.append((
                "route-start", first.point,
                mission.constraints.startPointMode == .autoNearest ? "航线起点 · 自动最近" : "航线起点 · 固定首点",
                .routeStart, nil, first.headingDegrees
            ))
        }
        if let aircraft {
            annotationValues.append(("aircraft", aircraft, "飞机", .aircraft, nil, aircraftHeading))
        }
        if let remoteController {
            let course = context.coordinator.remoteControllerCourse
            annotationValues.append((
                "remote-controller", remoteController,
                course == nil ? "遥控器 · 静止时无可靠朝向"
                    : String(format: "遥控器 · 移动方向 %.0f°", course!),
                .remoteController, nil, course
            ))
        }
        if let home {
            annotationValues.append(("home", home, "返航点 Home", .home, nil, nil))
        }
        if let simulatorOrigin {
            annotationValues.append((
                "simulator-origin", simulatorOrigin, "仿真起点", .simulatorOrigin, nil, nil
            ))
        }
        if Self.executionIsVisible(execution), let target = execution.currentTarget {
            let paused = execution.state == .paused
            annotationValues.append((
                "execution-target", target.point,
                paused ? "航线暂停 · 恢复目标" : "当前执行段 \(execution.legIndex + 1)/\(max(1, execution.legCount))",
                .executionTarget, nil, target.headingDegrees
            ))
        }
        context.coordinator.syncAnnotations(annotationValues, in: view)

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            let coordinates = focusPoints.map(surveyMapCoordinate)
            if coordinates.count == 1 {
                view.setRegion(.init(center: coordinates[0], latitudinalMeters: 300,
                                     longitudinalMeters: 300), animated: true)
            } else {
                let shape = MKPolyline(coordinates: coordinates, count: coordinates.count)
                view.setVisibleMapRect(shape.boundingMapRect,
                                       edgePadding: .init(top: 80, left: 80, bottom: 80, right: 80),
                                       animated: false)
            }
        }
        if context.coordinator.lastThreeDimensional != threeDimensional {
            context.coordinator.lastThreeDimensional = threeDimensional
            let camera = view.camera.copy() as! MKMapCamera
            camera.pitch = threeDimensional ? 55 : 0
            view.setCamera(camera, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: SurveyPlanningMap
        var lastFocusToken = ""
        var lastMapType: MKMapType?
        var lastThreeDimensional = false
        var lastROI: [SurveyGeoPoint] = []
        var lastMission: SurveyMission?
        var staticOverlays: [MKOverlay] = []
        var homeDirectionOverlay: HomeDirectionPolyline?
        var lastHomeAircraft: SurveyGeoPoint?
        var lastHomePoint: SurveyGeoPoint?
        var executionOverlay: SurveyExecutionOverlay?
        var activeRouteOverlay: SurveyActiveRoutePolyline?
        var lastActiveRouteSignature = ""
        var lastExecutionLegIndex = -1
        var lastExecutionState: SurveyExecutionState?
        var lastExecutionAircraft: SurveyGeoPoint?
        var lastExecutionTarget: SurveyGeoPoint?
        var lastRemoteControllerPoint: SurveyGeoPoint?
        var remoteControllerCourse: Double?
        private var annotationsByKey: [String: SurveyMapAnnotation] = [:]
        private var annotationStyleSignatures: [String: String] = [:]
        init(parent: SurveyPlanningMap) { self.parent = parent }

        func syncHomeDirection(aircraft: SurveyGeoPoint?, home: SurveyGeoPoint?, in mapView: MKMapView) {
            guard let aircraft, let home else {
                if let existing = homeDirectionOverlay { mapView.removeOverlay(existing) }
                homeDirectionOverlay = nil; lastHomeAircraft = nil; lastHomePoint = nil
                return
            }
            let moved = lastHomeAircraft.map { Self.distanceMeters($0, aircraft) >= 0.5 } ?? true
            guard moved || lastHomePoint != home || homeDirectionOverlay == nil else { return }
            if let existing = homeDirectionOverlay { mapView.removeOverlay(existing) }
            var coordinates = [aircraft, home].map {
                surveyMapCoordinate($0)
            }
            let overlay = HomeDirectionPolyline(coordinates: &coordinates, count: 2)
            homeDirectionOverlay = overlay
            lastHomeAircraft = aircraft; lastHomePoint = home
            mapView.addOverlay(overlay)
        }

        func syncExecutionOverlay(aircraft: SurveyGeoPoint?, execution: SurveyRuntimeSnapshot,
                                  in mapView: MKMapView) {
            let target = execution.currentTarget?.point
            let visible = SurveyPlanningMap.executionIsVisible(execution)
            guard visible, let aircraft, let target else {
                if let existing = executionOverlay { mapView.removeOverlay(existing) }
                executionOverlay = nil
                lastExecutionLegIndex = -1; lastExecutionState = nil
                lastExecutionAircraft = nil; lastExecutionTarget = nil
                return
            }
            let moved = lastExecutionAircraft.map { Self.distanceMeters($0, aircraft) >= 0.15 } ?? true
            let changed = execution.legIndex != lastExecutionLegIndex
                || execution.state != lastExecutionState || lastExecutionTarget != target
            guard moved || changed || executionOverlay == nil else { return }
            let overlay: SurveyExecutionOverlay
            if let existing = executionOverlay {
                overlay = existing
                overlay.update(start: aircraft, end: target,
                               paused: execution.state == .paused)
                if let renderer = mapView.renderer(for: overlay) as? SurveyExecutionOverlayRenderer {
                    renderer.refresh()
                }
            } else {
                overlay = SurveyExecutionOverlay(
                    start: aircraft, end: target, paused: execution.state == .paused,
                    coverage: [aircraft, target] + (parent.mission?.waypoints.map(\.point) ?? [])
                        + parent.roi + [parent.home].compactMap { $0 }
                )
                executionOverlay = overlay
                mapView.addOverlay(overlay)
            }
            lastExecutionLegIndex = execution.legIndex
            lastExecutionState = execution.state
            lastExecutionAircraft = aircraft
            lastExecutionTarget = target
        }

        func syncActiveRoute(mission: SurveyMission?, execution: SurveyRuntimeSnapshot,
                             in mapView: MKMapView) {
            guard SurveyPlanningMap.executionIsVisible(execution), let mission,
                  mission.waypoints.indices.contains(execution.waypointIndex) else {
                if let existing = activeRouteOverlay { mapView.removeOverlay(existing) }
                activeRouteOverlay = nil
                lastActiveRouteSignature = ""
                return
            }
            let waypoint = mission.waypoints[execution.waypointIndex]
            let points: [SurveyGeoPoint]
            if mission.activeMapping != nil,
               let passes = try? mission.surveyPasses(),
               let pass = passes.first(where: {
                   execution.waypointIndex >= $0.firstWaypointIndex
                       && execution.waypointIndex <= $0.lastWaypointIndex
               }) {
                points = pass.waypoints.map(\.point)
            } else {
                points = mission.waypoints
                    .filter { $0.captureView == waypoint.captureView }
                    .map(\.point)
            }
            guard points.count >= 2 else {
                if let existing = activeRouteOverlay { mapView.removeOverlay(existing) }
                activeRouteOverlay = nil
                lastActiveRouteSignature = ""
                return
            }
            let paused = execution.state == .paused
            let signature = "\(mission.id)|\(execution.waypointIndex)|\(paused)|\(points.count)"
            guard signature != lastActiveRouteSignature else { return }
            if let existing = activeRouteOverlay { mapView.removeOverlay(existing) }
            let coordinates = points.map {
                surveyMapCoordinate($0)
            }
            let overlay = SurveyActiveRoutePolyline(
                coordinates: coordinates, count: coordinates.count, paused: paused
            )
            activeRouteOverlay = overlay
            lastActiveRouteSignature = signature
            mapView.addOverlay(overlay)
        }

        private static func distanceMeters(_ lhs: SurveyGeoPoint, _ rhs: SurveyGeoPoint) -> Double {
            let north = (rhs.latitude - lhs.latitude) * 111_132
            let east = (rhs.longitude - lhs.longitude) * 111_320
                * cos((lhs.latitude + rhs.latitude) * .pi / 360)
            return hypot(north, east)
        }

        func syncAnnotations(
            _ values: [(key: String, point: SurveyGeoPoint, title: String,
                        kind: SurveyMapAnnotation.Kind, vertexIndex: Int?, heading: Double?)],
            in mapView: MKMapView
        ) {
            let desiredKeys = Set(values.map(\.key))
            for key in annotationsByKey.keys where !desiredKeys.contains(key) {
                if let annotation = annotationsByKey.removeValue(forKey: key) {
                    mapView.removeAnnotation(annotation)
                }
                annotationStyleSignatures.removeValue(forKey: key)
            }
            for value in values {
                let annotation: SurveyMapAnnotation
                if let existing = annotationsByKey[value.key],
                   existing.kind == value.kind,
                   existing.vertexIndex == value.vertexIndex {
                    existing.update(point: value.point, title: value.title, heading: value.heading)
                    annotation = existing
                } else {
                    if let existing = annotationsByKey.removeValue(forKey: value.key) {
                        mapView.removeAnnotation(existing)
                    }
                    annotation = SurveyMapAnnotation(
                        point: value.point, title: value.title, kind: value.kind,
                        vertexIndex: value.vertexIndex, heading: value.heading
                    )
                    annotationsByKey[value.key] = annotation
                    mapView.addAnnotation(annotation)
                }
                let selected = value.kind == .boundary
                    && value.vertexIndex == parent.selectedVertexIndex
                let paused = value.kind == .executionTarget
                    && parent.execution.state == .paused
                let styleSignature = "\(value.kind.rawValue)|\(value.heading ?? -999)|\(selected)|\(paused)"
                if annotationStyleSignatures[value.key] != styleSignature,
                   let annotationView = mapView.view(for: annotation) {
                    configure(annotationView, for: annotation)
                }
                annotationStyleSignatures[value.key] = styleSignature
            }
        }

        func updateRemoteControllerCourse(_ point: SurveyGeoPoint?) {
            guard let point else {
                lastRemoteControllerPoint = nil
                remoteControllerCourse = nil
                return
            }
            guard let previous = lastRemoteControllerPoint else {
                lastRemoteControllerPoint = point
                return
            }
            let north = (point.latitude - previous.latitude) * 111_132
            let east = (point.longitude - previous.longitude) * 111_320
                * cos((point.latitude + previous.latitude) / 2 * .pi / 180)
            // Accumulate sub-metre location samples instead of replacing the
            // anchor every callback; otherwise a walking RC never reaches the
            // 1 m course threshold at normal GPS update rates.
            guard hypot(north, east) >= 1 else { return }
            let value = atan2(east, north) * 180 / .pi
            remoteControllerCourse = value < 0 ? value + 360 : value
            lastRemoteControllerPoint = point
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let map = recognizer.view as? MKMapView else { return }
            let coordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            parent.onTap(surveyWGS84Point(coordinate))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView = touch.view
            while let view = touchedView {
                if view is MKAnnotationView { return false }
                touchedView = view.superview
            }
            return true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? SurveyCoveragePolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = UIColor.systemGreen.withAlphaComponent(0.13)
                renderer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.70)
                renderer.lineWidth = 3
                return renderer
            }
            if let polygon = overlay as? SurveyTargetPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.07)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 3
                return renderer
            }
            if let polygon = overlay as? SurveyROIPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.fillColor = UIColor.systemCyan.withAlphaComponent(0.16)
                renderer.strokeColor = .systemCyan
                renderer.lineWidth = 2
                return renderer
            }
            if let route = overlay as? SurveyRoutePolyline {
                let renderer = MKPolylineRenderer(polyline: route)
                switch route.style {
                case .captureView:
                    renderer.strokeColor = route.captureView.map(SurveyRoutePalette.uiColor) ?? .systemGray
                    renderer.lineWidth = route.captureView == .nadir ? 4.5 : 3.5
                case .altitude:
                    renderer.strokeColor = route.altitudeFraction.map(Self.altitudeColor) ?? .white
                    renderer.lineWidth = 2
                case .transit:
                    renderer.strokeColor = UIColor.systemGray.withAlphaComponent(0.8)
                    renderer.lineWidth = 1.5
                    renderer.lineDashPattern = [5, 4]
                }
                return renderer
            }
            if let line = overlay as? HomeDirectionPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = .systemOrange
                renderer.lineWidth = 2
                renderer.lineDashPattern = [5, 4]
                return renderer
            }
            if let line = overlay as? SurveyActiveRoutePolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = line.paused ? .systemOrange : .systemCyan
                renderer.lineWidth = 3
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let line = overlay as? SurveyExecutionOverlay {
                return SurveyExecutionOverlayRenderer(overlay: line)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private static func altitudeColor(_ fraction: Double) -> UIColor {
            let value = min(1, max(0, fraction))
            return UIColor(hue: CGFloat((1 - value) * 0.66), saturation: 0.88, brightness: 0.96, alpha: 1)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let item = annotation as? SurveyMapAnnotation else { return nil }
            let identifier = "survey-\(item.kind.rawValue)"
            if item.kind == .aircraft {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: item, reuseIdentifier: identifier)
                view.annotation = item
                configure(view, for: item)
                return view
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: item, reuseIdentifier: identifier)
            view.annotation = item
            configure(view, for: item)
            return view
        }

        private func configure(_ annotationView: MKAnnotationView, for item: SurveyMapAnnotation) {
            if item.kind == .aircraft {
                annotationView.image = Self.aircraftMarkerImage
                annotationView.centerOffset = .zero
                annotationView.canShowCallout = true
                annotationView.displayPriority = .required
                annotationView.zPriority = .max
                annotationView.transform = CGAffineTransform(
                    rotationAngle: (item.heading ?? 0) * .pi / 180
                )
                return
            }
            guard let view = annotationView as? MKMarkerAnnotationView else { return }
            // Keep the route readable at normal zoom. Details remain available
            // through the standard callout after tapping a marker.
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            view.canShowCallout = true
            view.glyphImage = nil
            view.glyphText = nil
            switch item.kind {
            case .aircraft:
                break
            case .remoteController:
                view.markerTintColor = .systemGreen
                view.glyphImage = UIImage(systemName: item.heading == nil ? "iphone" : "location.north.fill")
            case .home:
                view.markerTintColor = .systemOrange
                view.glyphText = "H"
            case .simulatorOrigin:
                view.markerTintColor = .systemPurple
                view.glyphImage = UIImage(systemName: "scope")
            case .routeStart:
                view.markerTintColor = .systemGreen
                view.glyphText = "S"
            case .executionTarget:
                view.markerTintColor = parent.execution.state == .paused ? .systemOrange : .systemCyan
                view.glyphText = parent.execution.state == .paused ? "Ⅱ" : "▶"
            case .boundary where item.vertexIndex == parent.selectedVertexIndex:
                view.markerTintColor = .systemOrange
                view.glyphImage = UIImage(systemName: "circle.fill")
            case .boundary:
                view.markerTintColor = .systemCyan
                view.glyphImage = UIImage(systemName: "circle.fill")
            }
            if let heading = item.heading {
                view.transform = CGAffineTransform(rotationAngle: heading * .pi / 180)
            } else {
                view.transform = .identity
            }
        }

        private static let aircraftMarkerImage = AircraftMapMarkerImage.djiStyle

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let item = view.annotation as? SurveyMapAnnotation,
                  item.kind == .boundary, let index = item.vertexIndex else { return }
            parent.onSelectVertex(index)
        }
    }

    private static func executionIsVisible(_ execution: SurveyRuntimeSnapshot) -> Bool {
        execution.state == .arming || execution.state == .running || execution.state == .paused
    }
}

enum SurveyRoutePalette {
    static func argb(for view: SurveyCaptureView) -> UInt32 {
        switch view {
        case .nadir: return 0xFFFFB547
        case .forwardOblique: return 0xFFFF6B6B
        case .backwardOblique: return 0xFFB77BFF
        case .leftOblique: return 0xFF55D69E
        case .rightOblique: return 0xFF55BDEB
        case .localOblique: return 0xFFFF9F43
        }
    }

    static func uiColor(for view: SurveyCaptureView) -> UIColor {
        let value = argb(for: view)
        return UIColor(red: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255,
                       alpha: CGFloat((value >> 24) & 0xff) / 255)
    }

    static func color(for view: SurveyCaptureView) -> Color { Color(uiColor: uiColor(for: view)) }
}

private final class SurveyRoutePolyline: MKPolyline {
    enum Style { case captureView, altitude, transit }
    var captureView: SurveyCaptureView?
    var style: Style = .captureView
    var altitudeFraction: Double?

    convenience init(coordinates: UnsafePointer<CLLocationCoordinate2D>, count: Int,
                     captureView: SurveyCaptureView?, style: Style,
                     altitudeFraction: Double? = nil) {
        self.init(coordinates: coordinates, count: count)
        self.captureView = captureView
        self.style = style
        self.altitudeFraction = altitudeFraction
    }
}

private final class HomeDirectionPolyline: MKPolyline { }
private final class SurveyActiveRoutePolyline: MKPolyline {
    var paused = false
    convenience init(coordinates: UnsafePointer<CLLocationCoordinate2D>, count: Int,
                     paused: Bool) {
        self.init(coordinates: coordinates, count: count)
        self.paused = paused
    }
}
private final class SurveyCoveragePolygon: MKPolygon { }
private final class SurveyTargetPolygon: MKPolygon { }
private final class SurveyROIPolygon: MKPolygon { }
private final class SurveyExecutionOverlay: NSObject, MKOverlay {
    private(set) var start: CLLocationCoordinate2D
    private(set) var end: CLLocationCoordinate2D
    private(set) var paused: Bool
    let boundingMapRect: MKMapRect

    init(start: SurveyGeoPoint, end: SurveyGeoPoint, paused: Bool,
         coverage: [SurveyGeoPoint]) {
        self.start = surveyMapCoordinate(start)
        self.end = surveyMapCoordinate(end)
        self.paused = paused
        let coordinates = coverage.map {
            surveyMapCoordinate($0)
        }
        let shape = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let latitude = coverage.first?.latitude ?? start.latitude
        let padding = max(1, MKMapPointsPerMeterAtLatitude(latitude) * 5_000)
        boundingMapRect = shape.boundingMapRect.insetBy(dx: -padding, dy: -padding)
    }

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: (start.latitude + end.latitude) / 2,
              longitude: (start.longitude + end.longitude) / 2)
    }

    func update(start: SurveyGeoPoint, end: SurveyGeoPoint, paused: Bool) {
        self.start = surveyMapCoordinate(start)
        self.end = surveyMapCoordinate(end)
        self.paused = paused
    }
}

private final class SurveyExecutionOverlayRenderer: MKOverlayPathRenderer {
    private var executionOverlay: SurveyExecutionOverlay { overlay as! SurveyExecutionOverlay }

    override init(overlay: any MKOverlay) {
        super.init(overlay: overlay)
        lineWidth = 3
        lineCap = .round
        lineJoin = .round
        refreshColor()
    }

    override func createPath() {
        let path = CGMutablePath()
        path.move(to: point(for: MKMapPoint(executionOverlay.start)))
        path.addLine(to: point(for: MKMapPoint(executionOverlay.end)))
        self.path = path
    }

    func refresh() {
        refreshColor()
        invalidatePath()
        setNeedsDisplay()
    }

    private func refreshColor() {
        strokeColor = executionOverlay.paused ? .systemOrange : .systemCyan
    }
}

private final class SurveyMapAnnotation: NSObject, MKAnnotation {
    enum Kind: String {
        case boundary, routeStart, aircraft, remoteController, home, simulatorOrigin, executionTarget
    }
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    let kind: Kind
    let vertexIndex: Int?
    private(set) var heading: Double?
    init(point: SurveyGeoPoint, title: String, kind: Kind, vertexIndex: Int?, heading: Double?) {
        coordinate = surveyMapCoordinate(point)
        self.title = title; self.kind = kind; self.vertexIndex = vertexIndex; self.heading = heading
    }

    func update(point: SurveyGeoPoint, title: String, heading: Double?) {
        let nextCoordinate = surveyMapCoordinate(point)
        if abs(nextCoordinate.latitude - coordinate.latitude) > 1e-9
            || abs(nextCoordinate.longitude - coordinate.longitude) > 1e-9 {
            coordinate = nextCoordinate
        }
        if self.title != title { self.title = title }
        self.heading = heading
    }
}

private struct SurveyMapToolButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.bold())
            .foregroundStyle(.primary)
            .frame(minWidth: 46, minHeight: 34)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black.opacity(0.12)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
