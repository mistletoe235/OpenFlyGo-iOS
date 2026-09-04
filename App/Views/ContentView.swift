import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: FlightViewModel
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @State private var showWarnings = false
    @State private var showSurveyPlannerQA = ProcessInfo.processInfo.arguments.contains("--survey-ui-preview")
    @State private var surveyPhotoFeedback: Bool?
    @State private var surveyPhotoFeedbackTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let physicalBottomGap = max(8, geometry.safeAreaInsets.bottom * 0.55)
            let bottomPadding = physicalBottomGap - geometry.safeAreaInsets.bottom
            ZStack(alignment: .topLeading) {
#if targetEnvironment(simulator)
                MockVideoView(
                    heading: model.telemetry.heading,
                    flying: model.telemetry.flying,
                    enduranceBarVisible: model.telemetry.connected
                )
                .ignoresSafeArea()
#else
#if canImport(DJISDK)
                DJILiveVideoView().ignoresSafeArea()
#else
                Color.black.ignoresSafeArea()
#endif
#endif

                VStack(spacing: 0) {
                    TopStatusBar(showWarnings: $showWarnings)
                    Spacer()
                }

                HStack {
                    Spacer()
                    ControlStatePanel()
                    Spacer()
                }
                .padding(.top, model.telemetry.connected ? 66 : 62)

                if model.showMoreControls {
                    MoreControlPanel()
                    .transition(.opacity)
                    .zIndex(4)
                } else {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            CameraRail().frame(width: 64)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.trailing, 10)
                }

                if !model.mapFullscreen {
                    NavigationHUD()
                        .frame(width: 360, height: 112)
                        .position(x: 190, y: geometry.size.height - 46 - bottomPadding)

                    LongPressTakeoffControl()
                        .frame(width: 76, height: 92)
                        .position(x: 52, y: min(max(geometry.size.height * 0.53, 195), geometry.size.height - 142))
                }

                if model.showLogs {
                    ModelMonitor()
                        .frame(width: 210, height: 132)
                        .position(x: 117, y: 120)
                }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        if OpenFlyBuildFeatures.vlnInference { VLNPanel() }
                    }
                }
                .padding(.trailing, 12)
                .padding(.bottom, bottomPadding)

#if targetEnvironment(simulator)
                if model.showSimulationTools { SimulationTools().zIndex(5) }
#endif
                if showWarnings {
                    WarningListOverlay(isPresented: $showWarnings).zIndex(7)
                }
                if model.showAircraftStatus { AircraftStatusOverlay().zIndex(5) }
                if model.galleryVisible { GalleryOverlay().zIndex(6) }
                if let alert = model.alert {
                    ActionConfirmationOverlay(alert: alert) { model.alert = nil }.zIndex(10)
                }
                if let banner = model.transientBanner {
                    VStack {
                        TransientBannerView(banner: banner)
                            .padding(.top, 46)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(30)
                }

                if model.showDJIAccountStartupPrompt {
                    DJIAccountLoginPrompt().zIndex(90)
                }

                if !languageSettings.selectionCompleted {
                    LanguageSelectionView(firstLaunch: true,
                                          initialLanguage: languageSettings.language)
                        .environmentObject(languageSettings)
                        .zIndex(100)
                }

                if model.mapFullscreen {
                    SurveyPlannerView()
                        .environmentObject(model)
                        .transition(.opacity)
                        .zIndex(40)
                }

                if let success = surveyPhotoFeedback {
                    SurveyPhotoCaptureFeedback(success: success)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .zIndex(80)
                }
            }
        }
        .fullScreenCover(isPresented: $showSurveyPlannerQA) {
            SurveyPlannerView().environmentObject(model)
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--map-ui-preview") {
                model.mapFullscreen = true
            }
        }
        .onChange(of: model.surveyRuntime.snapshot.photoFeedbackSequence) { sequence in
            guard sequence > 0 else { return }
            showSurveyPhotoFeedback(success: model.surveyRuntime.snapshot.photoFeedbackSucceeded)
        }
        .onDisappear {
            surveyPhotoFeedbackTask?.cancel()
        }
    }

    private func showSurveyPhotoFeedback(success: Bool) {
        surveyPhotoFeedbackTask?.cancel()
        withAnimation(.easeOut(duration: 0.08)) { surveyPhotoFeedback = success }
        surveyPhotoFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: success ? 340_000_000 : 1_280_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) { surveyPhotoFeedback = nil }
        }
    }
}

private struct SurveyPhotoCaptureFeedback: View {
    let success: Bool

    var body: some View {
        ZStack {
            Color.white.opacity(success ? 0.08 : 0)
                .ignoresSafeArea()
            Label(success ? "已拍摄" : "拍摄失败",
                  systemImage: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(success ? Color.white : Color(red: 1, green: 0.54, blue: 0.50))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minWidth: 118)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.16)))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
    }
}

private struct TopStatusBar: View {
    @EnvironmentObject var model: FlightViewModel
    @Binding var showWarnings: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showWarnings = false
                model.showAircraftStatus = true
            } label: {
                HStack(spacing: 6) {
                    DroneHUDIcon()
                        .frame(width: 19, height: 19)
                        .foregroundStyle(statusColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("飞机").font(.caption2.bold())
                        Text(statusText).font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(statusColor)
                    }
                }
            }
            .buttonStyle(HapticPlainButtonStyle())
            FlightModeStrip()
            Spacer(minLength: 2)
            centerStatus.frame(maxWidth: 250)
            Spacer(minLength: 2)
            iconMetric("antenna.radiowaves.left.and.right", value: "\(model.telemetry.satellites)", label: "GPS")
            signalMetric
            aircraftBatteryMetric
            RemoteBatteryBadge(
                percent: model.telemetry.rcBattery,
                label: model.telemetry.rcExternalBatteryPresent ? "内" : nil
            )
            if model.telemetry.rcExternalBatteryPresent {
                RemoteBatteryBadge(percent: model.telemetry.rcExternalBattery, label: "外")
            }
            Button {
                showWarnings = false
                withAnimation(.easeInOut(duration: 0.18)) { model.showMoreControls.toggle() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 34, height: 32)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(HapticPlainButtonStyle())
            .accessibilityLabel("更多控制")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(Color(red: 0.04, green: 0.055, blue: 0.075).opacity(0.76), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.10), lineWidth: 0.7))
        .overlay(alignment: .bottom) {
            if model.telemetry.connected {
                FlightEnduranceBar()
                    .frame(height: 14)
                    .padding(.horizontal, 10)
                    .offset(y: 7)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private func iconMetric(_ icon: String, value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: -1) {
                Text(label).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                Text(value).font(.caption2.monospacedDigit().bold())
            }
        }
        .foregroundStyle(.white.opacity(0.88))
    }

    private var signalMetric: some View {
        HStack(spacing: 4) {
            SignalBars(percent: model.telemetry.signal).frame(width: 18, height: 15)
            Text(model.telemetry.signal > 0 ? "\(model.telemetry.signal)" : "--")
                .font(.caption2.monospacedDigit().bold())
        }
        .foregroundStyle(.white.opacity(0.88))
        .accessibilityLabel("遥控链路信号 \(model.telemetry.signal)%")
    }

    private var aircraftBatteryMetric: some View {
        AircraftBatteryRing(percent: model.telemetry.aircraftBattery)
            .frame(width: 27, height: 27)
        .accessibilityLabel("飞机电量 \(model.telemetry.aircraftBattery)%，剩余飞行时间 \(remainingTimeText)")
    }

    private var remainingTimeText: String {
        let seconds = model.telemetry.remainingFlightTimeSeconds
        guard seconds > 0 else { return "--:--" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @ViewBuilder
    private var centerStatus: some View {
        if let warning = model.telemetry.highestPriorityWarning {
            Button { showWarnings.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(AppLocalization.string(warning.title)).lineLimit(1)
                    if model.telemetry.warnings.count > 1 {
                        Text("+\(model.telemetry.warnings.count - 1)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                .font(.subheadline.bold())
                .foregroundStyle(warning.severity >= .warning ? Color.red : Color.orange)
            }
            .buttonStyle(HapticPlainButtonStyle())
        } else {
            Group {
                if let phase = model.simulatorPhaseLabel {
                    Text(LocalizedStringKey(phase))
                } else {
                    Text(LocalizedStringKey(model.telemetry.mode.label))
                        + Text(" · ")
                        + Text(LocalizedStringKey(model.telemetry.flying ? "飞行中" : "地面"))
                }
            }
            .font(.headline).foregroundStyle(model.telemetry.connected ? .mint : .red)
        }
    }

    private var statusText: String {
        if model.telemetry.connected {
            if let warning = model.telemetry.highestPriorityWarning {
                return warning.severity == .notice ? "CONNECTED · NOTICE" : "CONNECTED · CAUTION"
            }
            return "CONNECTED"
        }
        return model.telemetry.remoteControllerConnected ? "RC CONNECTED" : "DISCONNECTED"
    }

    private var statusColor: Color {
        guard let warning = model.telemetry.highestPriorityWarning else {
            return model.telemetry.connected ? .green : (model.telemetry.remoteControllerConnected ? .orange : .red)
        }
        return warning.severity >= .warning ? .red : .orange
    }
}

private struct DroneHUDIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5).stroke(lineWidth: 1.6)
                .frame(width: 6, height: 6)
            ForEach(0..<4) { index in
                Capsule().fill().frame(width: 7, height: 1.5)
                    .offset(x: 5.2)
                    .rotationEffect(.degrees(45 + Double(index) * 90))
                Circle().stroke(lineWidth: 1.3).frame(width: 5.5, height: 5.5)
                    .offset(x: 8.1)
                    .rotationEffect(.degrees(45 + Double(index) * 90))
            }
        }
    }
}

private struct SignalBars: View {
    let percent: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(index < activeBars ? signalColor : Color.white.opacity(0.18))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
    }

    private var activeBars: Int {
        guard percent > 0 else { return 0 }
        return min(4, max(1, Int(ceil(Double(percent) / 25))))
    }

    private var signalColor: Color { percent <= 20 ? .red : percent <= 45 ? .orange : .green }
}

private struct AircraftBatteryRing: View {
    let percent: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.18))
            Circle().stroke(.white.opacity(0.30), lineWidth: 1.9)
            Circle().trim(from: 0, to: CGFloat(clamped) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(max(0, percent))")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.96))
        }
    }

    private var clamped: Int { min(100, max(0, percent)) }
    private var color: Color { clamped <= 15 ? .red : clamped <= 30 ? .orange : .green }
}

private struct RemoteBatteryBadge: View {
    let percent: Int
    var label: String?

    var body: some View {
        HStack(spacing: 2) {
            if let label { Text(label).font(.system(size: 7, weight: .bold)) }
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.white.opacity(0.72), lineWidth: 1.2)
                    .frame(width: 35, height: 18)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(0.36))
                    .frame(width: 30 * CGFloat(clamped) / 100, height: 13)
                    .frame(width: 30, alignment: .leading)
                Text(percent >= 0 ? "\(percent)" : "--")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
            }
            Capsule().fill(.white.opacity(0.72)).frame(width: 2, height: 7)
        }
        .foregroundStyle(.white.opacity(0.92))
        .accessibilityLabel("遥控器电量 \(percent)%")
    }

    private var clamped: Int { min(100, max(0, percent)) }
    private var color: Color { clamped <= 15 ? .red : clamped <= 30 ? .orange : .green }
}

private struct FlightEnduranceBar: View {
    @EnvironmentObject var model: FlightViewModel

    var body: some View {
        GeometryReader { geometry in
            let left: CGFloat = 4
            let right = max(left + 1, geometry.size.width - 4)
            let usable = right - left
            let centerY = geometry.size.height / 2
            let charge = validPercent(model.telemetry.aircraftBattery) ?? 0
            let landRequirement = validRequirementPercent(model.telemetry.batteryNeededToLandPercent)
            let homeRequirement = validRequirementPercent(model.telemetry.batteryNeededToGoHomePercent)
            let land = min(charge, landRequirement ?? 0)
            let home = min(charge, max(land, homeRequirement ?? land))
            let chargeX = x(charge, left: left, width: usable)
            let homeX = x(home, left: left, width: usable)

            ZStack(alignment: .topLeading) {
                barSegment(from: left, to: right, y: centerY, color: Color(red: 0.82, green: 0.85, blue: 0.88).opacity(0.57))
                barSegment(from: left, to: x(land, left: left, width: usable), y: centerY, color: .red)
                barSegment(from: x(land, left: left, width: usable), to: homeX, y: centerY, color: .yellow)
                barSegment(from: homeX, to: chargeX, y: centerY, color: Color(red: 0.16, green: 0.79, blue: 0.42))

                if homeRequirement != nil {
                    Text("H")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Color(red: 0.15, green: 0.17, blue: 0.19))
                        .frame(width: 12, height: 12)
                        .background(.white, in: Circle())
                        .position(x: homeX, y: centerY)
                }

                Text(timeLabel)
                    .font(.system(size: 7, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 34, minHeight: 11)
                    .background(Color(red: 0.04, green: 0.055, blue: 0.075).opacity(0.96), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 0.6))
                    .fixedSize()
                    .position(
                        x: min(right - 17, max(left + 17, chargeX)),
                        y: centerY + 3
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func barSegment(from start: CGFloat, to end: CGFloat, y: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, end - start), height: 3)
            .position(x: (start + end) / 2, y: y)
    }

    private func x(_ percent: Int, left: CGFloat, width: CGFloat) -> CGFloat {
        left + width * CGFloat(min(100, max(0, percent))) / 100
    }

    private func validPercent(_ value: Int) -> Int? { (0...100).contains(value) ? value : nil }

    /// MSDK4 exposes unknown assessment percentages as zero, so zero cannot be
    /// distinguished from a real estimate. Do not draw a misleading H marker
    /// until the flight controller publishes a positive requirement.
    private func validRequirementPercent(_ value: Int) -> Int? { (1...100).contains(value) ? value : nil }

    private var timeLabel: String {
        let seconds = model.telemetry.remainingFlightTimeSeconds
        guard seconds > 0 else { return "--:--" }
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    private var accessibilityText: String {
        var parts = ["预计剩余飞行时间 \(timeLabel)", "电量 \(model.telemetry.aircraftBattery)%"]
        if let value = validRequirementPercent(model.telemetry.batteryNeededToGoHomePercent) { parts.append("返航所需 \(value)%") }
        if let value = validRequirementPercent(model.telemetry.batteryNeededToLandPercent) { parts.append("降落所需 \(value)%") }
        return parts.joined(separator: "，")
    }
}

private struct FlightModeStrip: View {
    @EnvironmentObject var model: FlightViewModel

    var body: some View {
        HStack(spacing: 9) {
            item(.cine)
            item(.normal)
            item(.sport)
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("遥控器飞行档位：\(model.telemetry.rcFlightProfile.label)")
    }

    private func item(_ mode: RCFlightProfile) -> some View {
        let selected = model.telemetry.rcFlightProfile == mode
        return HStack(spacing: 3) {
            Circle().fill(selected ? Color.green : Color.clear)
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: selected ? 0 : 1))
                .frame(width: 5, height: 5)
            Text(mode.shortLabel).font(.caption2.bold())
            Text(LocalizedStringKey(mode.label)).font(.system(size: 8))
        }
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
    }
}

private struct MoreControlPanel: View {
    @EnvironmentObject var model: FlightViewModel
    @EnvironmentObject private var languageSettings: AppLanguageSettings
    @Environment(\.openURL) private var openURL
    @State private var showingModelImporter = false
    @State private var showingLanguageSelector = false
    @State private var selectedTab = SettingsTab.simulation
    @AppStorage(ChinaMapCalibrationMode.defaultsKey)
    private var chinaMapCalibrationRaw = ChinaMapCalibrationMode.automatic.rawValue

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case link = "链路", flight = "飞控", execution = "执行", simulation = "仿真"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("设置", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.showMoreControls = false }
                } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 28)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(HapticPlainButtonStyle())
            }


            Button {
                HapticFeedback.impact(.light)
                showingLanguageSelector = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "globe").foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("语言").font(.caption.bold())
                        Text("界面语言").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(languageSettings.language.nativeName).font(.caption)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 11)
                .frame(height: 42)
                .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.11)))
            }
            .buttonStyle(HapticPlainButtonStyle())

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("中国地图坐标校准", systemImage: "location.viewfinder")
                        .font(.caption.bold())
                    Spacer()
                    Picker("中国地图坐标校准", selection: $chinaMapCalibrationRaw) {
                        ForEach(ChinaMapCalibrationMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.label)).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                }
                Text("默认自动：任务、飞控、日志和导出始终使用 WGS‑84；仅中国大陆地图显示采用 GCJ‑02。若当前 Apple 地图底图已自行校准，可在此关闭，国外坐标不受影响。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.11)))

            Picker("设置分类", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)

            if selectedTab == .link {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: model.djiAccount.loggedIn
                          ? "person.crop.circle.badge.checkmark"
                          : "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(model.djiAccount.loggedIn ? Color.green : Color.orange)
                    Text("DJI 账号").font(.subheadline.bold())
                    Spacer()
                    if model.djiAccountOperationInProgress {
                        ProgressView().controlSize(.small)
                    }
                    Button(model.djiAccountLoginButtonTitle) {
                        HapticFeedback.impact(.medium)
                        model.requestDJIAccountLogin()
                    }
                    .buttonStyle(HUDButtonStyle(tint: model.djiAccount.loggedIn ? .green : .cyan))
                    .disabled(model.djiAccountOperationInProgress)
                    if model.djiAccount.loggedIn {
                        Button(model.djiAccountLogoutInProgress ? "退出中…" : "退出登录") {
                            HapticFeedback.impact(.medium)
                            model.requestDJIAccountLogout()
                        }
                        .buttonStyle(HUDButtonStyle(tint: .orange))
                        .disabled(model.djiAccountOperationInProgress)
                    }
                }
                Text(model.djiAccountStatusText)
                    .font(.caption2)
                    .foregroundStyle(model.djiAccount.loggedIn ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.djiAccountLoginIsSimulated
                     ? "当前为模拟器 Mock：按钮只验证应用回调和状态刷新，不会连接 DJI 账号服务。"
                     : "登录由 DJI MSDK 安全页面完成；OpenFly 不读取或保存账号密码。未登录仍可使用预览和仿真，真机飞行能力可能受 DJI 激活与地区规则限制。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.11)))
            }

            if selectedTab == .execution {
            Button {
                HapticFeedback.impact(.medium)
                model.surveyPlannerPanelVisible = true
                model.showMoreControls = false
                model.mapFullscreen = true
            } label: {
                HStack {
                    Label("测绘任务规划", systemImage: "map.fill")
                    Spacer()
                    Text("航线 · 任务库").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(HUDButtonStyle(tint: .cyan))
            }

            if selectedTab == .execution && OpenFlyBuildFeatures.vlnInference {
            VStack(alignment: .leading, spacing: 6) {
                Text("VLN 相对位置执行").font(.caption.bold())
                Picker("位置闭环", selection: Binding(
                    get: { model.positionClosureMode },
                    set: { HapticFeedback.selection(); model.selectPositionClosureMode($0) }
                )) {
                    ForEach(PositionClosureMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.shortLabel)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(LocalizedStringKey(model.positionClosureMode.detail))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("水平限速").font(.caption)
                    Slider(value: Binding(
                        get: { model.maxVLNHorizontalSpeed },
                        set: { HapticFeedback.selection(); model.setMaxVLNHorizontalSpeed($0) }
                    ), in: 0.2...4.0, step: 0.1)
                    Text(String(format: "%.1f m/s", model.maxVLNHorizontalSpeed))
                        .font(.caption.monospacedDigit()).frame(width: 58, alignment: .trailing)
                }
                Text(speedLimitNote)
                    .font(.system(size: 9))
                    .foregroundStyle(model.maxVLNHorizontalSpeed > 1.0 ? .orange : .secondary)
                HStack(spacing: 8) {
                    Text("Stop 阈值").font(.caption)
                    Spacer()
                    Picker("Stop 阈值", selection: Binding(
                        get: { model.stopThreshold },
                        set: { HapticFeedback.selection(); model.setStopThreshold($0) }
                    )) {
                        ForEach(model.stopThresholdOptions, id: \.self) { value in
                            Text(String(format: "%.1f", value)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.white)
                }
                Text("模型原始 stop 分数 ≥ \(String(format: "%.1f", model.stopThreshold)) 时立即悬停；修改会安全退出当前 VLN 控制。")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 6) {
                Text("手动 XYZ 相对位置").font(.caption.bold())
                HStack(spacing: 7) {
                    xyzField("X 前", value: $model.manualRelativeX)
                    xyzField("Y 右", value: $model.manualRelativeY)
                    xyzField("Z 上", value: $model.manualRelativeZ)
                }
                HStack(spacing: 8) {
                    Button("执行 XYZ") {
                        HapticFeedback.impact(.medium)
                        model.executeManualRelativePosition()
                    }
                    .buttonStyle(HUDButtonStyle())
                    .disabled(!model.canExecuteManualRelativePosition)
                    Button("停止") {
                        HapticFeedback.impact(.rigid)
                        model.stopManualRelativePosition()
                    }
                    .buttonStyle(HUDButtonStyle(tint: .red))
                    .disabled(!model.vlnArmed && !model.chunkExecutionActive)
                }
                Text("X/Y 单步平面距离不超过 10m；Z 范围 ±0.5m，下降保留 0.8m 安全高度。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 5) {
                Toggle(isOn: Binding(
                    get: { model.continuousChunkEnabled },
                    set: { HapticFeedback.selection(); model.setContinuousChunkEnabled($0) }
                )) {
                    Text("UAVFlow H10 连续执行").font(.subheadline.bold())
                }
                .toggleStyle(.switch)
                Picker("执行前缀", selection: Binding(
                    get: { model.executedPrefix },
                    set: { HapticFeedback.selection(); model.setExecutedPrefix($0) }
                )) {
                    ForEach(1...UAVFlowPolicyContract.horizon, id: \.self) { value in
                        Text("H\(value)").tag(value)
                    }
                }
                .pickerStyle(.menu)
                .disabled(!model.continuousChunkEnabled)
                Text(model.chunkExecutionSummary)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(model.chunkExecutionActive ? .green : .secondary)
                Text("模型始终预测 H10；开启后按所选 H1–H10 前缀执行，首个 stop 命中行只作停止哨兵、不执行移动。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Toggle("穿越中间航点", isOn: Binding(
                    get: { model.flyThroughEnabled },
                    set: { HapticFeedback.selection(); model.setFlyThroughEnabled($0) }
                ))
                .toggleStyle(.switch)
                Text("开启后中间点保留动量并携带残差；最终点仍减速悬停。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            }

            if selectedTab == .link && OpenFlyBuildFeatures.vlnInference {
            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("UAVFlow 模型").font(.subheadline.bold())
                    Spacer()
                    Button(model.modelLoaded ? "已加载" : "加载") {
                        HapticFeedback.impact(.medium)
                        model.loadModel()
                    }
                    .buttonStyle(HUDButtonStyle(tint: model.modelLoaded ? .green : .cyan))
                    .disabled(model.modelLoaded || model.modelOperationInProgress)
                    Button(model.modelOperationInProgress ? "处理中" : "下载最新") {
                        HapticFeedback.impact(.medium)
                        model.downloadLatestUAVFlowModel()
                    }
                    .buttonStyle(HUDButtonStyle())
                    .disabled(model.modelOperationInProgress)
                }
                HStack(spacing: 8) {
                    Button("导入本地 ZIP") {
                        HapticFeedback.impact(.medium)
                        showingModelImporter = true
                    }
                    .buttonStyle(HUDButtonStyle())
                    .disabled(model.modelOperationInProgress)
                    Button("运行时自检") {
                        HapticFeedback.impact(.medium)
                        model.inspectModelRuntime()
                    }
                    .buttonStyle(HUDButtonStyle(tint: .cyan))
                    .disabled(model.modelOperationInProgress)
                    Button("重置运行时") {
                        HapticFeedback.impact(.rigid)
                        model.resetModelRuntime()
                    }
                    .buttonStyle(HUDButtonStyle(tint: .orange))
                    .disabled(model.modelOperationInProgress)
                }
                if let progress = model.modelDownloadProgress, model.modelOperationInProgress {
                    ProgressView(value: progress).tint(.cyan)
                }
                Text(model.modelDownloadStatus)
                    .font(.caption2).foregroundStyle(model.modelDownloadStatus.contains("失败") ? .red : .secondary)
                    .lineLimit(2)
                Text("云端仅接受固定 Azure HTTPS 主机；本地 ZIP 与云端包都会核对 manifest、目录大小、SHA-256 和每个模型文件，再原子安装。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            }

            if selectedTab == .flight {
            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 8) {
                Text("飞控与安全").font(.subheadline.bold())
                HStack(spacing: 8) {
                    Button(model.telemetry.virtualStickActive ? "VS 已启用" : "启用 VS") {
                        HapticFeedback.impact(.medium); model.enableVirtualStickOnly()
                    }.buttonStyle(HUDButtonStyle(tint: .cyan))
                        .disabled(model.telemetry.virtualStickActive || !model.telemetry.connected || model.surveyControlActive)
                    Button("释放 VS") {
                        HapticFeedback.impact(.rigid); model.releaseVirtualStickOnly()
                    }.buttonStyle(HUDButtonStyle(tint: .orange))
                    Button("解除急停") {
                        HapticFeedback.impact(.medium); model.resetEmergency()
                    }.buttonStyle(HUDButtonStyle()).disabled(!model.emergencyStopped)
                }
                HStack(spacing: 8) {
                    Text("水平限速").font(.caption)
                    Slider(value: Binding(
                        get: { model.maxVLNHorizontalSpeed },
                        set: { model.setMaxVLNHorizontalSpeed($0) }
                    ), in: 0.2...4.0, step: 0.1)
                    Text(String(format: "%.1f m/s", model.maxVLNHorizontalSpeed))
                        .font(.caption.monospacedDigit()).frame(width: 62)
                }
                HStack(spacing: 8) {
                    Button(phoneChargingButtonTitle) {
                        HapticFeedback.impact(.medium)
                        model.setPhoneChargingEnabled(!phoneChargingEnabled)
                    }
                    .buttonStyle(HUDButtonStyle(tint: phoneChargingEnabled ? .green : .cyan))
                    .frame(width: 132)
                    .disabled(!phoneChargingControlAllowed)
                    .opacity(phoneChargingControlAllowed ? 1 : 0.45)
                    Text(phoneChargingStatus)
                        .font(.caption2)
                        .foregroundStyle(phoneChargingAvailable ? Color.secondary : Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("安全门：\(model.control.reason)\nVS：\(model.vlnArmed ? "开启" : "关闭") · 控制权：\(model.control.owner.rawValue)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            }

            if selectedTab == .simulation {
            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 5) {
                Toggle(isOn: Binding(
                    get: { model.simulatorStatus.active },
                    set: { HapticFeedback.impact(.medium); model.setSimulatorEnabled($0) }
                )) {
                    HStack(spacing: 7) {
                        Circle().fill(model.simulatorStatus.active ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text("DJI 内置仿真器").font(.subheadline.bold())
                    }
                }
                .toggleStyle(.switch)
                .disabled(!model.simulatorStatus.available || model.simulatorChanging)
                HStack(spacing: 6) {
                    if model.simulatorChanging { ProgressView().controlSize(.mini) }
                    Text(model.simulatorStatus.message)
                }
                .font(.caption2).foregroundStyle(model.simulatorStatus.active ? .green : .secondary)
                .lineLimit(2)
                Text("调试时建议保持开启；关闭后再次启动可能需要重启飞机。")
                    .font(.system(size: 9)).foregroundStyle(.orange.opacity(0.9))
                if model.surveyRuntime.snapshot.state == .paused {
                    Text("航线已暂停，切换仿真不会清除任务断点。")
                        .font(.system(size: 9)).foregroundStyle(.orange.opacity(0.9))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("仿真起点（WGS84）").font(.caption.bold())
                    HStack(spacing: 6) {
                        TextField("纬度", text: $model.simulatorOriginLatitudeText)
                            .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                        TextField("经度", text: $model.simulatorOriginLongitudeText)
                            .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                    }
                    Text("默认使用上海市中心（人民广场）公开演示坐标，不读取当前设备位置。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        Button("保存起点") { model.saveSimulatorOrigin() }
                            .buttonStyle(HUDButtonStyle(tint: .cyan))
                        Button("使用飞机位置") { model.saveSimulatorOrigin(useAircraftLocation: true) }
                            .buttonStyle(HUDButtonStyle())
                            .disabled(!model.telemetry.aircraftLocationValid)
                    }
                    Text("仅在 Simulator 关闭且飞机未起飞时可修改；下次启动生效。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if model.simulatorStatus.active {
                    Text(String(format: "X %.1f  Y %.1f  Z %.1f m · %@", model.simulatorStatus.positionX, model.simulatorStatus.positionY, model.simulatorStatus.positionZ, model.simulatorStatus.flying ? "飞行中" : "地面"))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }

            Divider().opacity(0.35)
            SurveyUeBridgePanel(controller: model.ueBridge,
                                sendMission: model.sendActiveSurveyMissionToUE)

            Divider().opacity(0.35)
            HILControlPanel(controller: model.hil)

#if targetEnvironment(simulator)
            Button("打开 Mock 测试工具") { model.showSimulationTools = true }
                .buttonStyle(HUDButtonStyle())
#endif
            }

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 7) {
                Text("关于与支持").font(.subheadline.bold())
                Button {
                    openURL(URL(string: "https://app.openflygo.com/privacy")!)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.cyan)
                        Text("隐私政策").font(.caption.bold())
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HUDButtonStyle(tint: .cyan))
                .accessibilityHint("在浏览器中打开 OpenFly Go 隐私政策")

                Button {
                    openURL(URL(string: "https://app.openflygo.com/support")!)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(.cyan)
                        Text("支持与联系").font(.caption.bold())
                        Spacer()
                        Image(systemName: "arrow.up.right.square").font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(HUDButtonStyle())
                .accessibilityHint("在浏览器中打开 OpenFly Go 支持页面")

                Text("OpenFly Go · 1.0 · you_zhongrui@outlook.com")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Color.black.opacity(0.94).ignoresSafeArea() }
        .fileImporter(isPresented: $showingModelImporter,
                      allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { model.importUAVFlowModel(from: url) }
            case let .failure(error):
                model.log.append("模型", "选择本地模型包失败：\(error.localizedDescription)")
            }
        }
        .sheet(isPresented: $showingLanguageSelector) {
            LanguageSelectionView(firstLaunch: false,
                                  initialLanguage: languageSettings.language)
                .environmentObject(languageSettings)
        }
    }

    private var speedLimitNote: String {
        "可调范围 0.2–4.0 m/s；GPS/速度估算均使用该上限，调整时会停止当前动作。"
    }

    private var phoneChargingAvailable: Bool {
        model.telemetry.remoteControllerConnected && model.telemetry.rcPhoneChargingAvailable
    }

    private var phoneChargingControlAllowed: Bool {
        model.telemetry.remoteControllerConnected
            && model.telemetry.rcPhoneChargingMode != "UNSUPPORTED"
            && !model.telemetry.rcPhoneChargingMode.hasPrefix("SETTING_")
    }

    private var phoneChargingEnabled: Bool {
        ["ALWAYS", "INTELLIGENT"].contains(model.telemetry.rcPhoneChargingMode)
    }

    private var phoneChargingButtonTitle: String {
        guard model.telemetry.remoteControllerConnected else {
            return AppLocalization.string("手机充电：等待 RC")
        }
        guard model.telemetry.rcPhoneChargingMode != "UNSUPPORTED" else {
            return AppLocalization.string("手机充电：不支持")
        }
        if model.telemetry.rcPhoneChargingMode.hasPrefix("SETTING_") {
            return AppLocalization.string("手机充电：写入中")
        }
        guard model.telemetry.rcPhoneChargingAvailable else {
            return AppLocalization.string("手机充电：尝试开启")
        }
        return AppLocalization.string(phoneChargingEnabled ? "手机充电：开" : "手机充电：关")
    }

    private var phoneChargingStatus: String {
        guard model.telemetry.remoteControllerConnected else {
            return AppLocalization.string("连接遥控器后读取 DJI ChargeMobileMode")
        }
        if model.telemetry.rcPhoneChargingMode == "UNSUPPORTED" {
            return AppLocalization.string("当前遥控器或固件未提供 iOS 手机充电控制")
        }
        if model.telemetry.rcPhoneChargingMode.hasPrefix("SETTING_") {
            return AppLocalization.string("正在写入 DJI ChargeMobileMode，成功后将自动回读")
        }
        if model.telemetry.rcPhoneChargingMode == "READ_FAILED" {
            return AppLocalization.string("自动读取暂时失败，仍可点击尝试开启")
        }
        guard model.telemetry.rcPhoneChargingAvailable else {
            return AppLocalization.string("正在读取遥控器充电能力；失败时将于 1/2/4 秒重试")
        }
        return AppLocalization.format("当前模式：%@", model.telemetry.rcPhoneChargingMode)
    }

    private func xyzField(_ label: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            TextField("0.00", value: value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .font(.caption.monospacedDigit())
                .frame(height: 28)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.12)))
        }
    }
}

private struct SurveyUeBridgePanel: View {
    @ObservedObject var controller: SurveyUeBridgeController
    var sendMission: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UE / AirSim 出站桥（只镜像，不接受飞控命令）")
                .font(.subheadline.bold())
            TextField("http://192.168.1.2:30010", text: $controller.endpoint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.caption.monospaced())
                .padding(.horizontal, 9).frame(height: 32)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Button("发送当前任务", action: sendMission)
                    .buttonStyle(HUDButtonStyle())
                Button(controller.enabled ? "遥测镜像：开" : "遥测镜像：关") {
                    controller.toggle()
                }
                .buttonStyle(HUDButtonStyle(tint: controller.enabled ? .green : .cyan))
            }
            Text(controller.status)
                .font(.caption2.monospaced())
                .foregroundStyle(controller.status.contains("失败") || controller.status.contains("阻止")
                                 ? .red : (controller.enabled ? .green : .secondary))
            Text("兼容 Android openfly.survey.ue.v1：mission / telemetry / target / capture；若 HIL 已发现 UE，会自动复用其主机地址并保留 30010 端口。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

struct HILControlPanel: View {
    @EnvironmentObject private var model: FlightViewModel
    @ObservedObject var controller: OpenFlyHILController
    @State private var showingFramePreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("UE/AirSim 硬件在环").font(.subheadline.bold())
                Spacer()
                Circle().fill(controller.status.peerFresh ? Color.green : (controller.status.running ? .orange : .gray))
                    .frame(width: 8, height: 8)
            }
            Picker("连接方式", selection: $controller.configuration.mode) {
                ForEach(HILConnectionMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            .pickerStyle(.segmented).disabled(controller.status.running)
            if controller.configuration.mode == .lan {
                HStack {
                    Text("UE 地址").font(.caption)
                    TextField("192.168.1.10", text: $controller.configuration.host)
                        .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                        .disabled(controller.status.running)
                }
            } else {
                Picker("热点发现", selection: $controller.configuration.hotspotDiscoveryMode) {
                    ForEach(HILHotspotDiscoveryMode.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                .pickerStyle(.segmented).disabled(controller.status.running)
                if controller.configuration.hotspotDiscoveryMode == .manual {
                HStack {
                    Text("UE 热点 IP").font(.caption)
                    TextField("例如 172.20.10.2", text: $controller.configuration.hotspotHost)
                        .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                        .disabled(controller.status.running)
                }
                Text("手动兜底：填写 UE 电脑加入 iPhone 热点后获得的 IP。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text("默认同时使用 Bonjour 和旧 Android UE 的 OFHL HELLO 单播探测；无需填写电脑 IP，失联后自动重新发现。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                portField("UE UDP", value: $controller.configuration.udpServerPort)
                portField("本机 UDP", value: $controller.configuration.udpLocalPort)
                portField("图像 TCP", value: $controller.configuration.frameTCPPort)
            }
            .disabled(controller.status.running)
            HStack {
                Text("仿真源 / 位姿发送").font(.caption)
                Spacer()
                Picker("仿真与位姿频率", selection: synchronizedHILFrequency) {
                    ForEach([10, 25, 50, 100, 150], id: \.self) { Text("\($0) Hz").tag($0) }
                }.pickerStyle(.menu).disabled(controller.status.running)
            }
            HStack(spacing: 8) {
                Button(controller.status.running ? "重启 HIL" : "启动 HIL") {
                    HapticFeedback.impact(.medium); model.startHIL()
                }.buttonStyle(HUDButtonStyle(tint: .cyan))
                Button("停止") { HapticFeedback.impact(.rigid); model.stopHIL() }
                    .buttonStyle(HUDButtonStyle(tint: .red)).disabled(!controller.status.running)
            }
            Toggle("图像源：UE 虚拟相机", isOn: $controller.useVirtualFrames)
                .toggleStyle(.switch)
                .disabled(!controller.status.running)
            Button("预览 UE 当前帧") { showingFramePreview = true }
                .buttonStyle(HUDButtonStyle(tint: .blue))
                .disabled(controller.latestVirtualFrame == nil)
            Text(controller.status.message).font(.caption2)
                .foregroundStyle(controller.status.peerFresh ? .green : .secondary).lineLimit(2)
            Text(String(format: "peer %@ · raw %.1f Hz · pose %.1f Hz · RTT %@ · frame %@",
                        controller.status.peerHost ?? "--", model.simulatorStatus.measuredUpdateHz,
                        controller.status.measuredPoseSendHz,
                        controller.status.roundTripMilliseconds.map { String(format: "%.1f ms", $0) } ?? "--",
                        controller.status.frameConnected ? "TCP 已连接" : (controller.status.frameListening ? "等待 UE" : "未监听")))
                .font(.system(size: 9).monospaced()).foregroundStyle(.secondary)
            Text(String(format: "image %.1f Hz · age %@ · ok %llu / reject %llu",
                        controller.status.measuredFrameReceiveHz,
                        controller.status.latestFrameAgeMilliseconds.map { String(format: "%.0f ms", $0) } ?? "--",
                        controller.status.receivedFrameCount,
                        controller.status.rejectedFrameCount))
                .font(.system(size: 9).monospaced()).foregroundStyle(.secondary)
            Text(controller.status.frameMessage)
                .font(.system(size: 9))
                .foregroundStyle(controller.status.frameConnected ? .green : .secondary)
                .lineLimit(2)
            Text(OpenFlyBuildFeatures.vlnInference
                 ? "openfly.hil.v1：UDP 30020/30021，TCP 虚拟相机 30022；虚拟相机直接进入模型，不经过飞控。"
                 : "openfly.hil.v1：UDP 30020/30021，TCP 虚拟相机 30022；首版用于仿真图像预览和记录，不启用模型推理。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingFramePreview) {
            HILFramePreview(frame: controller.latestVirtualFrame)
        }
    }

    private func portField(_ title: String, value: Binding<UInt16>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            TextField("端口", value: value, format: .number)
                .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
        }
    }

    private var synchronizedHILFrequency: Binding<Int> {
        Binding(
            get: { controller.configuration.simulatorStateHz },
            set: { value in
                controller.configuration.simulatorStateHz = value
                controller.configuration.poseSendHz = value
            }
        )
    }

}

private struct TransientBannerView: View {
    let banner: TransientBanner

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.subheadline.bold())
            Text(AppLocalization.string(banner.message))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 540)
        .background(color.opacity(0.94), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.24)))
        .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
        .padding(.horizontal, 86)
    }

    private var icon: String {
        switch banner.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch banner.kind {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct HILFramePreview: View {
    var frame: CameraFrame?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let frame, let image = UIImage(data: frame.jpeg) {
                    VStack(spacing: 8) {
                        Image(uiImage: image).resizable().scaledToFit()
                        Text("F\(frame.sequence) · \(frame.width)×\(frame.height) · \(Int(Date().timeIntervalSince(frame.capturedAt) * 1_000)) ms")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.padding()
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 34, weight: .semibold))
                        Text("UE 当前帧不可用")
                            .font(.headline)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .background(Color.black.opacity(0.94))
            .navigationTitle("UE 虚拟相机")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }
}

private struct ControlStatePanel: View {
    @EnvironmentObject var model: FlightViewModel
    @Environment(\.locale) private var locale
    @SceneStorage("openfly.control-panel.minimized") private var minimized = false

    var body: some View {
        Group {
            if minimized {
                Button { withAnimation(.easeInOut(duration: 0.18)) { minimized = false } } label: {
                    HStack(spacing: 7) {
                        Circle().fill(stateColor).frame(width: 8, height: 8)
                        Text(LocalizedStringKey(model.controlEnvironmentLabel)).font(.caption.bold())
                            .foregroundStyle(environmentColor)
                        if let phase = model.simulatorPhaseLabel {
                            (Text("· ") + Text(LocalizedStringKey(phase)))
                                .font(.caption.bold()).foregroundStyle(.mint).lineLimit(1)
                        }
                        compactControlDescription
                            .font(.caption).lineLimit(1)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.down").font(.caption.bold())
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 36)
                    .background(.black.opacity(0.52), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.16)))
                }
                .buttonStyle(HapticPlainButtonStyle())
                .accessibilityLabel("展开飞行控制栏")
            } else {
                VStack(spacing: 6) {
                    HStack(spacing: 7) {
                        Circle().fill(stateColor).frame(width: 8, height: 8)
                        Text(LocalizedStringKey(model.controlEnvironmentLabel)).font(.subheadline.bold())
                            .foregroundStyle(environmentColor)
                        if let phase = model.simulatorPhaseLabel {
                            (Text("· ") + Text(LocalizedStringKey(phase)))
                                .font(.caption.bold()).foregroundStyle(.mint).lineLimit(1)
                        }
                        expandedControlDescription
                            .font(.caption).lineLimit(1)
                        Spacer(minLength: 2)
                        Button { withAnimation(.easeInOut(duration: 0.18)) { minimized = true } } label: {
                            Image(systemName: "minus").font(.caption.bold()).frame(width: 32, height: 28)
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                        .accessibilityLabel("最小化飞行控制栏")
                    }
                    HStack(spacing: 5) {
                        controlButton("返航", enabled: model.telemetry.flying && !model.isReturningHome && !model.isLanding) { model.requestReturnHome() }
                        controlButton("取消返航", enabled: model.isReturningHome) { model.cancelReturnHome() }
                        controlButton("降落", enabled: model.telemetry.flying && !model.isReturningHome) { model.requestLanding() }
                        controlButton("取消降落", enabled: model.isLanding) { model.cancelLanding() }
                        controlButton("状态", enabled: true) { model.showAircraftStatus = true }
                    }
                    if model.telemetry.landingConfirmationNeeded == true {
                        Button("确认下方安全并继续降落") { model.confirmLanding() }
                            .font(.caption.bold())
                            .buttonStyle(HUDButtonStyle(tint: .orange))
                    }
                }
                .padding(8)
                .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14)))
            }
        }
        .frame(width: minimized ? 250 : (locale.identifier.hasPrefix("en") ? 500 : 440))
    }

    private var stateColor: Color { model.control.mode == .failsafe ? .red : model.control.owner == .vln ? .green : .orange }
    private var compactControlDescription: Text {
        Text("· ")
            + Text(LocalizedStringKey(model.control.mode.rawValue))
            + Text(" · ")
            + Text(LocalizedStringKey(model.control.owner.rawValue))
    }

    private var expandedControlDescription: Text {
        Text("· ")
            + Text(LocalizedStringKey(model.control.mode.rawValue))
            + Text(" · 控制权：")
            + Text(LocalizedStringKey(model.control.owner.rawValue))
            + Text(" · ")
            + Text(LocalizedStringKey(model.control.reason))
    }

    private var environmentColor: Color {
        if model.hil.status.running { return model.hil.status.peerFresh ? .green : .cyan }
        if model.simulatorStatus.active || model.simulatorChanging { return .cyan }
        return .secondary
    }
    private func controlButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(LocalizedStringKey(title)) }
            .font(.caption.bold()).buttonStyle(HUDButtonStyle())
            .disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }
}

private struct CameraRail: View {
    @EnvironmentObject var model: FlightViewModel

    var body: some View {
        VStack(spacing: 0) {
            Button { model.takePhoto() } label: {
                ZStack {
                    Circle().stroke(.white.opacity(0.80), lineWidth: 1)
                    Circle()
                        .fill(Color(red: 0.95, green: 0.95, blue: 0.96))
                        .overlay(Circle().stroke(Color(red: 0.72, green: 0.75, blue: 0.78), lineWidth: 1))
                        .padding(4)
                    Image(systemName: "camera")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(red: 0.19, green: 0.20, blue: 0.23))
                }
                .frame(width: 50, height: 50)
            }
                .buttonStyle(CameraRailPressStyle())
                .disabled(!model.camera.canCapturePhotos)
                .opacity(model.camera.canCapturePhotos ? 1 : 0.35)
                .accessibilityLabel("拍照")

            Button { model.toggleRecording() } label: {
                Image(systemName: model.camera.recording ? "stop.fill" : "video.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 34)
                    .background(
                        model.camera.recording
                            ? Color(red: 0.65, green: 0.13, blue: 0.17).opacity(0.90)
                            : Color(red: 0.04, green: 0.36, blue: 0.56).opacity(0.90),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(model.camera.recording ? Color.red : Color(red: 0.16, green: 0.59, blue: 1), lineWidth: 1)
                    )
            }
            .buttonStyle(CameraRailPressStyle())
            .padding(.top, 9)
            .disabled(model.camera.recording
                      ? !model.camera.connected
                      : !(model.camera.connected && model.camera.captureStorageReady))
            .opacity(recordButtonEnabled ? 1 : 0.35)
            .accessibilityLabel(model.camera.recording ? "停止录像" : "开始录像")

            if model.camera.recording {
                Text(recordingDuration)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.61))
                    .frame(height: 16)
                    .padding(.top, 2)
            }
            if cameraProblemVisible {
                Text(model.camera.message)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.50))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 64, height: 18)
                    .padding(.top, 1)
            }

            Button { model.openGallery() } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 34)
                    .background(Color(red: 0.04, green: 0.055, blue: 0.075).opacity(0.70),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.22), lineWidth: 1))
            }
                .buttonStyle(CameraRailPressStyle())
                .padding(.top, 6)
                .disabled(!model.galleryAvailable).opacity(model.galleryAvailable ? 1 : 0.45)
                .accessibilityLabel("打开相册")
        }
        .frame(width: 64)
    }

    private var recordButtonEnabled: Bool {
        model.camera.recording
            ? model.camera.connected
            : model.camera.connected && model.camera.captureStorageReady
    }

    private var recordingDuration: String {
        String(format: "%02d:%02d", model.camera.recordingSeconds / 60,
               model.camera.recordingSeconds % 60)
    }

    private var cameraProblemVisible: Bool {
        ["失败", "不可用", "未连接", "未插入", "没有", "超时", "请先"]
            .contains { model.camera.message.contains($0) }
    }
}

private struct CameraRailPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.045 : 0.07),
                       value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { HapticFeedback.impact(.light) }
            }
    }
}

private struct VLNPanel: View {
    @EnvironmentObject var model: FlightViewModel
    @SceneStorage("openfly.vln-panel.minimized.v2") private var minimized = true

    var body: some View {
        Group {
            if minimized {
                Button { withAnimation(.easeInOut(duration: 0.18)) { minimized = false } } label: {
                    HStack(spacing: 7) {
                        Text("VLN").font(.headline.bold())
                        safeGateLabel
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up").font(.caption.bold())
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 38)
                    .background(Color(red: 0.04, green: 0.055, blue: 0.075).opacity(0.90), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.16)))
                }
                .buttonStyle(HapticPlainButtonStyle())
                .accessibilityLabel("展开 VLN 面板")
            } else {
                VStack(spacing: 7) {
                    HStack {
                        Text("VLN").font(.title3.bold())
                        safeGateLabel
                        Spacer()
                        Button("日志") { model.showLogs.toggle() }.buttonStyle(HapticPlainButtonStyle()).font(.caption)
                        Button("•••") {
                            withAnimation(.easeInOut(duration: 0.18)) { model.showMoreControls.toggle() }
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                        .accessibilityLabel("更多控制")
                        Button { withAnimation(.easeInOut(duration: 0.18)) { minimized = true } } label: {
                            Image(systemName: "minus").font(.caption.bold()).frame(width: 32, height: 28)
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(HapticPlainButtonStyle())
                        .accessibilityLabel("最小化 VLN 面板")
                    }
                    HStack {
                        Text("任务").font(.caption).foregroundStyle(.secondary)
                        Picker("Prompt", selection: Binding(
                            get: { model.selectedPromptID },
                            set: { HapticFeedback.selection(); model.selectPrompt(id: $0) }
                        )) {
                            Text("自定义").tag(FlightViewModel.customPromptID)
                            ForEach(model.promptPresets) { preset in
                                Text(preset.id).tag(preset.id)
                            }
                        }
                        .pickerStyle(.menu).frame(width: 78)
                        TextField("VLN Prompt", text: Binding(
                            get: { model.prompt },
                            set: { model.setPromptText($0) }
                        ))
                        .textFieldStyle(.plain).font(.caption).lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        Button("推理一次") { model.inferOnce() }.buttonStyle(HUDButtonStyle())
                            .disabled(model.inferenceRunning || !model.canStartInferenceAction)
                        Button(model.autoInference ? "自动:开" : "自动:关") { model.toggleAutoInference() }.buttonStyle(HUDButtonStyle())
                            .disabled(!model.autoInference && !model.canStartInferenceAction)
                        Button(model.emergencyStopped ? "已急停" : "急停") { model.emergencyStop() }
                            .buttonStyle(HUDButtonStyle(tint: .red, feedback: .rigid))
                    }
                    HStack(spacing: 5) {
                        Button(model.modelOperationInProgress ? "处理中" : (model.modelLoaded ? "已加载" : "加载")) {
                            model.loadModel()
                        }
                        .buttonStyle(HUDButtonStyle())
                        .disabled(model.modelLoaded || model.modelOperationInProgress)
                        Button(model.vlnArmed ? "控制:开" : "控制:关") { model.toggleVLNControl() }.buttonStyle(HUDButtonStyle(tint: model.vlnArmed ? .green : .blue)).disabled(!model.vlnArmed && !model.canArmVLN)
                        Button("停止") { model.normalStop() }.buttonStyle(HUDButtonStyle())
                        Button("复位") { model.resetEmergency() }.buttonStyle(HUDButtonStyle())
                    }
                    HStack {
                        Text(model.inferenceRunning ? "THINKING" : (model.latestLatency.map { "\(Int($0))ms" } ?? "IDLE"))
                        Spacer()
                        let command = model.latestDecision.command
                        Text("X \(f(command.forward))  Y \(f(command.right))  Z \(f(command.up))  YAW \(f(command.yawRate))")
                    }
                    .font(.caption2.monospaced()).foregroundStyle(model.latestDecision.eligible ? .green : .orange)
                }
                .padding(10)
                .background(Color(red: 0.04, green: 0.055, blue: 0.075).opacity(0.90), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14)))
            }
        }
        .frame(width: minimized ? 190 : 350)
    }

    private var safeGateLabel: some View {
        Text(model.latestDecision.eligible ? "SAFE GATE" : "SAFE HOLD")
            .font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
            .background((model.latestDecision.eligible ? Color.green : Color.orange).opacity(0.25), in: Capsule())
    }

    private func f(_ value: Double) -> String { String(format: "%.1f", value) }
}

private struct WarningListOverlay: View {
    @EnvironmentObject var model: FlightViewModel
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { isPresented = false }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("飞行告警（\(model.telemetry.warnings.count)）", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark").frame(width: 36, height: 32)
                    }.buttonStyle(HapticPlainButtonStyle())
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.telemetry.warnings) { warning in
                            HStack(alignment: .top, spacing: 9) {
                                Circle().fill(warningColor(warning)).frame(width: 8, height: 8).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(AppLocalization.string(warning.title)).font(.subheadline.bold())
                                    if let detail = warning.detail {
                                        Text(AppLocalization.string(detail)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let code = warning.code {
                                        Text("DJI code \(code)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
                .frame(maxHeight: 180)
                Button("打开完整飞机状态") {
                    isPresented = false
                    model.showAircraftStatus = true
                }
                .buttonStyle(HUDButtonStyle())
                .frame(width: 180)
            }
            .padding(13)
            .frame(width: 500)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.18)))
            .padding(.top, 52)
        }
    }

    private func warningColor(_ warning: FlightWarning) -> Color {
        warning.severity >= .warning ? .red : .orange
    }
}

private struct DJIAccountLoginPrompt: View {
    @EnvironmentObject private var model: FlightViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.cyan)
                Text("登录 DJI 账号").font(.title3.bold())
                Text(LocalizedStringKey(promptMessage))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("暂不登录") { model.dismissDJIAccountStartupPrompt() }
                        .buttonStyle(LargeConfirmationButtonStyle(tint: .gray))
                        .frame(width: 132)
                    Button("登录 DJI 账号") { model.requestDJIAccountLogin() }
                        .buttonStyle(LargeConfirmationButtonStyle(tint: .cyan))
                        .frame(width: 150)
                }
            }
            .padding(22)
            .frame(width: 430)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.2)))
        }
    }

    private var promptMessage: String {
        model.djiAccount.state == .tokenOutOfDate
            ? "DJI 登录已过期。重新登录后可恢复需要账号激活的真机飞行能力。"
            : "登录后可使用需要 DJI 账号激活的真机飞行能力；也可以暂不登录，仅使用预览和仿真功能。"
    }
}

private struct ActionConfirmationOverlay: View {
    let alert: AppAlert
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title).foregroundStyle(.orange)
                Text(alert.title).font(.title3.bold())
                Text(alert.message).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button(alert.cancelTitle, action: cancel)
                        .buttonStyle(LargeConfirmationButtonStyle(tint: .gray))
                        .frame(width: 132)
                    Button(alert.confirmTitle) {
                        cancel()
                        alert.confirm()
                    }
                    .buttonStyle(LargeConfirmationButtonStyle(tint: .red))
                    .frame(width: 150)
                }
            }
            .padding(22)
            .frame(width: 430)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.2)))
        }
    }
}

private struct LargeConfirmationButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.bold())
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
            .background(tint.opacity(configuration.isPressed ? 0.62 : 0.34), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.25)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { HapticFeedback.impact(.rigid) }
            }
    }
}

private struct ModelMonitor: View {
    @EnvironmentObject var model: FlightViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("模型监视器").font(.caption.bold()); Spacer(); Button("×") { model.showLogs = false }.buttonStyle(HapticPlainButtonStyle()) }
            ModelMonitorLog(log: model.log)
        }
        .padding(9).background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ModelMonitorBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ModelMonitorLog: View {
    @ObservedObject var log: EventLog
    @State private var followsLatest = true
    @State private var userDragging = false
    @State private var bottomY = CGFloat.infinity
    private let bottomID = "model-monitor-bottom"
    private let coordinateSpace = "model-monitor-scroll"

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(log.events) { event in
                            Text("\(time(event.timestamp)) [\(event.kind)] \(event.message)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(color(event.kind))
                                .id(event.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                            .background {
                                GeometryReader { marker in
                                    Color.clear.preference(
                                        key: ModelMonitorBottomPreferenceKey.self,
                                        value: marker.frame(in: .named(coordinateSpace)).maxY
                                    )
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: coordinateSpace)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { _ in
                            userDragging = true
                            followsLatest = false
                        }
                        .onEnded { _ in
                            userDragging = false
                            if isAtBottom(viewportHeight: viewport.size.height) { followsLatest = true }
                        }
                )
                .onPreferenceChange(ModelMonitorBottomPreferenceKey.self) { value in
                    bottomY = value
                    if !userDragging, isAtBottom(viewportHeight: viewport.size.height) {
                        followsLatest = true
                    }
                }
                .onChange(of: log.events.last?.id) { _ in
                    guard followsLatest else { return }
                    DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
            }
        }
    }

    private func isAtBottom(viewportHeight: CGFloat) -> Bool {
        bottomY <= viewportHeight + 8
    }

    private func time(_ date: Date) -> String { let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; return formatter.string(from: date) }
    private func color(_ kind: String) -> Color { kind == "错误" || kind == "急停" ? .red : kind == "输出" ? .green : .white.opacity(0.85) }
}

private struct NavigationHUD: View {
    @State private var showingMap = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if showingMap {
                    FlightMapPanel(fullscreen: false)
                } else {
                    CompassDial()
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showingMap.toggle() }
                } label: {
                    Image(systemName: showingMap ? "location.north.circle.fill" : "map.fill")
                        .font(.caption.bold())
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.72), in: Circle())
                }
                .buttonStyle(HapticPlainButtonStyle())
                .padding(5)
            }
            .frame(width: 142, height: 102)

            FlightTelemetryBlock()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .padding(5)
    }
}

private struct CompassDial: View {
    @EnvironmentObject var model: FlightViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(.black.opacity(0.68))
            Circle().stroke(.white.opacity(0.55), lineWidth: 1)
                .frame(width: 88, height: 88)
            ForEach(0..<12) { index in
                Rectangle()
                    .fill(index % 3 == 0 ? .orange : .white.opacity(0.55))
                    .frame(width: 2, height: index % 3 == 0 ? 10 : 6)
                    .offset(y: -38)
                    .rotationEffect(.degrees(Double(index) * 30))
            }
            Text("N").font(.caption2.bold()).offset(y: -27)
            Image(systemName: "location.north.fill")
                .foregroundStyle(.yellow)
                .rotationEffect(.degrees(model.telemetry.heading))
            Text("\(Int(model.telemetry.heading))°")
                .font(.caption2.monospacedDigit()).foregroundStyle(.green).offset(y: 32)
        }
    }
}

private struct FlightTelemetryBlock: View {
    @EnvironmentObject var model: FlightViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                metric("HS", model.telemetry.horizontalSpeed, "m/s")
                metric("VS", model.telemetry.verticalSpeed, "m/s")
            }
            HStack(spacing: 12) {
                metric("H", model.telemetry.altitude, "m")
                metric("D", homeDistance, "m")
            }
            Text("AGL \(aglLabel) · ASL~ \(f(model.telemetry.asl)) m · GIM \(Int(model.telemetry.gimbalPitch))° · RC \(sourceLabel)")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 7))
    }

    private func metric(_ label: String, _ value: Double, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label).font(.caption2.bold())
            Text(f(value)).font(.headline.monospacedDigit())
            Text(unit).font(.system(size: 8))
        }
    }

    private var homeDistance: Double {
        let a = model.telemetry.aircraft
        let b = model.telemetry.home
        return hypot((a.latitude - b.latitude) * 111_111, (a.longitude - b.longitude) * 95_000)
    }

    private var sourceLabel: String {
        model.telemetry.remoteControllerLocationSource
            .replacingOccurrences(of: "iPhone 定位", with: "手机")
            .replacingOccurrences(of: "遥控器 GPS", with: "RC")
    }

    private func f(_ value: Double) -> String { String(format: "%.1f", value) }

    private var aglLabel: String {
        model.telemetry.downwardHeightValid
            ? "\(f(model.telemetry.downwardHeight)) m"
            : "--"
    }
}

private struct LongPressTakeoffControl: View {
    @EnvironmentObject var model: FlightViewModel
    @State private var pressing = false
    @State private var progress: CGFloat = 0
    private let duration = 1.4

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.black.opacity(0.72))
                Circle().stroke(.white.opacity(0.3), lineWidth: 2)
                Circle().trim(from: 0, to: progress)
                    .stroke(.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.up")
                    .font(.title3.bold()).foregroundStyle(canTakeOff ? .white : .gray)
            }
            .frame(width: 54, height: 54)
            Text(LocalizedStringKey(takeoffLabel))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(model.takeoffCommandPending ? .orange : (canTakeOff ? .white : .gray))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 104)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.explainTakeoffInteraction(blockReason: takeoffBlockReason)
        }
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 28, pressing: { value in
            guard takeoffBlockReason == nil else { return }
            pressing = value
            if value {
                progress = 0
                withAnimation(.linear(duration: duration)) { progress = 1 }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } else {
                withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
            }
        }, perform: {
            guard let reason = takeoffBlockReason else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                model.requestTakeOff()
                progress = 0
                return
            }
            model.explainTakeoffInteraction(blockReason: reason)
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            progress = 0
        })
        .accessibilityLabel(canTakeOff ? "长按自动起飞" : "当前不可起飞")
    }

    private var canTakeOff: Bool {
        takeoffBlockReason == nil
    }

    private var takeoffBlockReason: String? {
        if !model.telemetry.connected { return "飞机未连接" }
        if model.telemetry.flying || model.isAirborneForControl { return "飞机已在飞行" }
        if model.isReturningHome { return "DJI 正在返航" }
        if model.isLanding { return "DJI 正在降落" }
        if model.telemetry.mode == .emergency { return "DJI 处于保护状态" }
        if model.takeoffCommandPending { return model.takeoffStatus }
        if model.simulatorChanging { return model.simulatorStatus.message }
        return nil
    }

    private var takeoffLabel: String {
        if model.takeoffCommandPending { return model.takeoffStatus }
        if model.simulatorChanging { return model.simulatorStatus.message }
        if model.telemetry.flying || model.isAirborneForControl { return "飞行中" }
        if model.takeoffStatus.hasPrefix("起飞失败") || model.takeoffStatus.hasPrefix("起飞已取消") {
            return model.takeoffStatus
        }
        return "长按起飞"
    }
}

struct HUDButtonStyle: ButtonStyle {
    var tint: Color = .blue
    var feedback: UIImpactFeedbackGenerator.FeedbackStyle = .medium
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.bold()).frame(maxWidth: .infinity, minHeight: 32)
            .padding(.horizontal, 5).background(tint.opacity(configuration.isPressed ? 0.5 : 0.22), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.22)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { HapticFeedback.impact(feedback) }
            }
    }
}

struct HapticPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed { HapticFeedback.impact(.light) }
            }
    }
}

enum HapticFeedback {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: style == .light ? 0.7 : 1.0)
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}

struct LiveCameraThumbnail: View {
    @EnvironmentObject private var model: FlightViewModel
    var body: some View {
        ZStack(alignment: .topLeading) {
#if targetEnvironment(simulator)
            MockVideoView(heading: model.telemetry.heading, flying: model.telemetry.flying)
#elseif canImport(DJISDK)
            // DJIVideoPreviewer has one render target. The higher-priority PIP
            // temporarily owns that target while the map is open, matching
            // Android's live TextureView re-parenting instead of decoding JPEG
            // model snapshots on the UI path.
            DJILiveVideoView(priority: 100)
#else
            LatestFrameThumbnail(frame: model.latestFrame)
#endif
            Text(LocalizedStringKey(model.liveCameraPreviewReady ? "实时图传" : "图传等待帧"))
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(5)
        }
        .frame(width: 200, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.75), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.45), radius: 5)
    }
}

private struct LatestFrameThumbnail: View {
    let frame: CameraFrame?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.black
                    Image(systemName: "camera.viewfinder")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .task(id: frame?.sequence) {
            guard let data = frame?.jpeg else { image = nil; return }
            image = await Task.detached(priority: .utility) { UIImage(data: data) }.value
        }
    }
}

struct MockVideoView: View {
    var heading: Double
    var flying: Bool
    var enduranceBarVisible = false
    var body: some View {
        Canvas { context, size in
            let sky = Path(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.55))
            context.fill(sky, with: .linearGradient(Gradient(colors: [.init(red: 0.13, green: 0.2, blue: 0.27), .init(red: 0.45, green: 0.58, blue: 0.63)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.55)))
            context.fill(Path(CGRect(x: 0, y: size.height * 0.55, width: size.width, height: size.height * 0.45)), with: .color(.init(red: 0.16, green: 0.22, blue: 0.18)))
            for i in 0..<7 {
                let width = size.width * 0.09
                let x = size.width * (0.12 + Double(i) * 0.125)
                let height = size.height * (0.17 + Double(i % 3) * 0.035)
                context.fill(Path(CGRect(x: x, y: size.height * 0.55 - height, width: width, height: height)), with: .color(.gray.opacity(0.8)))
                context.fill(Path(CGRect(x: x + 8, y: size.height * 0.55 - height + 12, width: width - 16, height: 8)), with: .color(.cyan.opacity(0.5)))
            }
            context.fill(Path(CGRect(x: size.width * 0.42, y: size.height * 0.55, width: size.width * 0.16, height: size.height * 0.45)), with: .color(.black.opacity(0.24)))
        }
        .overlay(alignment: .topLeading) {
            Text("SIMULATED CAMERA · \(flying ? "AIRBORNE" : "GROUND")")
                .font(.system(size: 9, design: .monospaced))
                .padding(8)
                .background(.black.opacity(0.45))
                .padding(.top, enduranceBarVisible ? 62 : 52)
                .padding(.leading, 8)
        }
    }
}
