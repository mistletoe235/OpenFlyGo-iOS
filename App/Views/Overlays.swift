import SwiftUI

struct AircraftStatusOverlay: View {
    @EnvironmentObject var model: FlightViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { model.showAircraftStatus = false }
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("飞机状态").font(.title2.bold())
                        Text("DJI 产品信息由 MSDK 连接后自动识别").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("关闭") { model.showAircraftStatus = false }.buttonStyle(HUDButtonStyle()).frame(width: 72)
                }
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            statusGroup("连接与控制", rows: [
                                ("产品", model.providerName.contains("Mock") ? "M30T Simulator · Mock" : model.providerName),
                                ("MSDK", model.telemetry.sdkRegistered ? "已注册" : "未注册"),
                                ("产品识别", model.telemetry.productModel),
                                ("遥控器", model.telemetry.remoteControllerConnected ? "已连接" : "断开"),
                                ("飞机", model.telemetry.connected ? "已连接" : "未连接"),
                                ("链路说明", model.telemetry.connectionMessage),
                                ("模式", model.telemetry.mode.label),
                                ("飞行状态", model.telemetry.flying ? "飞行中" : "地面"),
                                ("VLN 闭环", model.positionClosureMode.label),
                                ("DJI 仿真", model.simulatorStatus.message),
                                ("控制权", "\(model.control.owner.rawValue) · \(model.control.reason)"),
                            ])
                            statusGroup("导航与动力", rows: [
                                ("坐标", String(format: "%.6f, %.6f", model.telemetry.aircraft.latitude, model.telemetry.aircraft.longitude)),
                                ("位置源", model.telemetry.positionSource + (model.telemetry.aircraftLocationValid ? " · 有效" : " · GPS无效")),
                                ("ALT / ASL", String(format: "%.1f m / %.1f m", model.telemetry.altitude, model.telemetry.asl)),
                                ("水平 / 垂直速度", String(format: "%.1f / %.1f m/s", model.telemetry.horizontalSpeed, model.telemetry.verticalSpeed)),
                                ("航向 / 卫星", "\(Int(model.telemetry.heading))° / \(model.telemetry.satellites)"),
                                ("GPS 信号", "\(model.telemetry.gpsSignalLabel) · Level \(model.telemetry.gpsSignalLevel)"),
                                ("返航点", model.telemetry.homeLocationSet ? "已记录" : "未记录"),
                                ("飞机电池 / 信号", "\(model.telemetry.aircraftBattery)% / \(model.telemetry.signal)%"),
                                ("剩余飞行时间", duration(model.telemetry.remainingFlightTimeSeconds)),
                                ("返航 / 降落所需时间", "\(duration(model.telemetry.timeNeededToGoHomeSeconds)) / \(duration(model.telemetry.timeNeededToLandSeconds))"),
                                ("返航 / 降落所需电量", "\(percent(model.telemetry.batteryNeededToGoHomePercent)) / \(percent(model.telemetry.batteryNeededToLandPercent))"),
                                ("安全返航最大半径", distance(model.telemetry.maxSafeFlightRadiusMeters)),
                            ])
                            statusGroup("遥控器、相机与模型", rows: remoteControllerCameraRows)
                        }
                        if !model.telemetry.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("飞行告警（\(model.telemetry.warnings.count)）").font(.headline)
                                ForEach(model.telemetry.warnings) { warning in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(warning.severity >= .warning ? .red : .orange)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(AppLocalization.string(warning.title)).font(.subheadline.bold())
                                            if let detail = warning.detail {
                                                Text(AppLocalization.string(detail)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            if let code = warning.code { Text("DJI code \(code)").font(.caption2.monospaced()).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .frame(maxHeight: 330)
            }
            .padding(18)
            .frame(maxWidth: 820)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(24)
        }
    }

    private func statusGroup(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.string(row.0)).font(.caption2).foregroundStyle(.secondary)
                    Text(AppLocalization.string(row.1)).font(.caption.monospaced()).lineLimit(2)
                }
                if row.0 != rows.last?.0 { Divider().opacity(0.35) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }

    private func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "--:--" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func percent(_ value: Int) -> String {
        value > 0 ? "\(value)%" : "--"
    }

    private func distance(_ meters: Double) -> String {
        meters > 0 ? String(format: "%.0f m", meters) : "--"
    }

    private var remoteControllerCameraRows: [(String, String)] {
        var rows: [(String, String)] = [
            (model.telemetry.rcExternalBatteryPresent ? "遥控器内置电池" : "遥控器电池", "\(model.telemetry.rcBattery)%"),
        ]
        if model.telemetry.rcExternalBatteryPresent {
            rows.append(("遥控器外置电池", "\(model.telemetry.rcExternalBattery)%"))
        }
        rows.append(contentsOf: [
            ("相机", model.camera.message),
            (model.camera.storageName,
             model.camera.captureStorageReady
                ? "正常 · 剩余 \(model.camera.photosRemaining) 张" : "不可用"),
            ("推理引擎", model.inferenceName),
            ("模型", model.modelLoaded ? "已加载" : "未加载"),
        ])
        return rows
    }
}

struct SimulationTools: View {
    @EnvironmentObject var model: FlightViewModel
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture { model.showSimulationTools = false }
            VStack(spacing: 10) {
                HStack {
                    Text("Mac Simulator 测试工具").font(.headline)
                    Spacer()
                    Button("×") { model.showSimulationTools = false }
                        .font(.title2).buttonStyle(HapticPlainButtonStyle())
                }
                Text("这些操作只驱动 MockFlightProvider，不连接真实 DJI 飞机。")
                    .font(.caption).foregroundStyle(.orange)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    tool("模拟起飞", model.takeOff)
                    tool("人工摇杆接管", model.simulateManualTakeover)
                    tool(model.telemetry.connected ? "模拟断联" : "恢复连接", model.simulateDisconnect)
                    tool("切换遥测过期", model.simulateStale)
                    tool("切换相机故障", model.simulateCameraError)
                    tool("导出快照", model.exportSnapshot)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider：\(model.providerName)")
                    Text("Inference：\(model.inferenceName)")
                    Text("失联动作：返航（Mock 配置）")
                    if let url = model.snapshotURL { Text(url.lastPathComponent).foregroundStyle(.green) }
                }.font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18).frame(width: 520).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    private func tool(_ title: String, _ action: @escaping () -> Void) -> some View { Button(title, action: action).buttonStyle(HUDButtonStyle()) }
}

struct GalleryOverlay: View {
    @EnvironmentObject var model: FlightViewModel
    @State private var filter: MediaFilter = .all
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    private enum MediaFilter: String, CaseIterable, Identifiable {
        case all = "全部", photo = "照片", video = "视频"
        var id: String { rawValue }
    }

    private var shownItems: [AircraftMediaItem] {
        model.mediaItems.filter { item in
            switch filter {
            case .all: return true
            case .photo: return !item.isVideo
            case .video: return item.isVideo
            }
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            VStack(spacing: 10) {
                HStack {
                    Text("飞机相册").font(.title2.bold())
                    Picker("媒体分类", selection: $filter) {
                        ForEach(MediaFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    Spacer()
                    Button(model.galleryLoading ? "读取中" : "刷新") { model.refreshGallery() }
                        .buttonStyle(HUDButtonStyle(tint: .blue)).frame(width: 80)
                        .disabled(model.galleryLoading)
                    Button("关闭") { model.closeGallery() }
                        .buttonStyle(HUDButtonStyle()).frame(width: 80)
                }
                HStack(spacing: 8) {
                    if model.galleryLoading { ProgressView().tint(.white) }
                    Text(model.galleryStatus).font(.caption)
                        .foregroundStyle(model.galleryStatus.contains("失败") ? .red : .secondary)
                    Spacer()
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(shownItems) { item in
                            mediaCell(item)
                                .onAppear { model.fetchMediaThumbnail(id: item.id) }
                        }
                    }
                }
                if !model.mediaItems.isEmpty, shownItems.isEmpty {
                    Text("该分类下没有媒体文件").font(.caption).foregroundStyle(.secondary)
                }
                Text("打开相册会让 DJI 相机暂时进入回放/媒体下载模式；关闭后自动恢复拍照和图传。")
                    .font(.caption).foregroundStyle(.orange)
            }.padding(20)
        }
    }

    @ViewBuilder
    private func mediaCell(_ item: AircraftMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail = item.thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(colors: [.blue.opacity(0.5), .green.opacity(0.35)], startPoint: .top, endPoint: .bottom))
                            .overlay(Image(systemName: item.isVideo ? "video.fill" : "photo").font(.title2))
                    }
                }
                .frame(height: 92).clipped()
                if item.isVideo {
                    Text("▶ \(duration(item.durationSeconds))")
                        .font(.caption2.monospacedDigit()).padding(4)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(4)
                }
            }
            Text(item.fileName).font(.caption2.bold()).lineLimit(1)
            Text("\(item.storageName) · \(size(item.fileSizeBytes)) · \(item.timeCreated)")
                .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(6).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private func size(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
