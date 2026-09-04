import SwiftUI
import MapKit

enum AircraftMapMarkerImage {
    /// Matches DJI UXSDK's `uxsdk_ic_compass_aircraft`: a compact two-tone
    /// heading arrow with its nose at 0 degrees and no decorative disk.
    static let djiStyle: UIImage = {
        let size = CGSize(width: 22, height: 27)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            cg.setShadow(offset: .init(width: 0, height: 1), blur: 2,
                         color: UIColor.black.withAlphaComponent(0.62).cgColor)

            let full = UIBezierPath()
            full.move(to: CGPoint(x: 21.95, y: 26.20))
            full.addLine(to: CGPoint(x: 11.33, y: 0.30))
            full.addCurve(to: CGPoint(x: 10.67, y: 0.30),
                          controlPoint1: CGPoint(x: 11.21, y: -0.02),
                          controlPoint2: CGPoint(x: 10.79, y: -0.02))
            full.addLine(to: CGPoint(x: 0.05, y: 26.20))
            full.addCurve(to: CGPoint(x: 0.62, y: 26.80),
                          controlPoint1: CGPoint(x: -0.10, y: 26.56),
                          controlPoint2: CGPoint(x: 0.25, y: 26.93))
            full.addLine(to: CGPoint(x: 10.96, y: 23.12))
            full.addLine(to: CGPoint(x: 21.38, y: 26.80))
            full.addCurve(to: CGPoint(x: 21.95, y: 26.20),
                          controlPoint1: CGPoint(x: 21.75, y: 26.93),
                          controlPoint2: CGPoint(x: 22.10, y: 26.56))
            full.close()
            UIColor(red: 0.71, green: 0, blue: 0, alpha: 1).setFill()
            full.fill()

            cg.setShadow(offset: .zero, blur: 0, color: nil)
            let highlight = UIBezierPath()
            highlight.move(to: CGPoint(x: 19.16, y: 24.33))
            highlight.addLine(to: CGPoint(x: 11.11, y: 21.25))
            highlight.addLine(to: CGPoint(x: 11.11, y: 3.39))
            highlight.addCurve(to: CGPoint(x: 11.44, y: 3.32),
                               controlPoint1: CGPoint(x: 11.11, y: 3.20),
                               controlPoint2: CGPoint(x: 11.37, y: 3.15))
            highlight.addLine(to: CGPoint(x: 19.38, y: 24.11))
            highlight.addCurve(to: CGPoint(x: 19.16, y: 24.33),
                               controlPoint1: CGPoint(x: 19.44, y: 24.25),
                               controlPoint2: CGPoint(x: 19.30, y: 24.39))
            highlight.close()
            UIColor(red: 1, green: 0.08, blue: 0.08, alpha: 1).setFill()
            highlight.fill()
        }
    }()
}

struct FlightMapPanel: View {
    @EnvironmentObject var model: FlightViewModel
    @AppStorage("openfly.map.base-style") private var baseStyle = FlightMapStyle.satellite.rawValue
    @AppStorage(ChinaMapCalibrationMode.defaultsKey)
    private var chinaMapCalibrationRaw = ChinaMapCalibrationMode.automatic.rawValue
    let fullscreen: Bool

    private var mapStyle: FlightMapStyle {
        FlightMapStyle(rawValue: baseStyle) ?? .satellite
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            FlightMapRepresentable(
                telemetry: model.telemetry, style: mapStyle,
                followsPrimaryLocation: !fullscreen,
                chinaMapCalibrationMode: chinaMapCalibrationMode
            )
                .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 10))

            if !fullscreen {
                Button {
                    HapticFeedback.impact(.light)
                    model.surveyPlannerPanelVisible = false
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.mapFullscreen = true
                    }
                } label: {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开全屏地图")
            }

            HStack(spacing: 6) {
                Button {
                    baseStyle = mapStyle == .satellite
                        ? FlightMapStyle.standard.rawValue
                        : FlightMapStyle.satellite.rawValue
                } label: {
                    Image(systemName: mapStyle == .satellite ? "map.fill" : "globe.asia.australia.fill")
                        .font(.system(size: fullscreen ? 13 : 10, weight: .bold))
                }
                .accessibilityLabel(mapStyle == .satellite ? "切换到标准地图" : "切换到卫星地图")
                .buttonStyle(HUDButtonStyle())
                .frame(width: fullscreen ? 40 : 30, height: 30)

                Button { withAnimation { model.mapFullscreen.toggle() } } label: {
                    if fullscreen {
                        Text("返回").font(.caption.bold())
                    } else {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                }
                .accessibilityLabel(fullscreen ? "关闭全屏地图" : "打开全屏地图")
                .buttonStyle(HUDButtonStyle())
                .frame(width: fullscreen ? 58 : 30, height: 30)
            }
            .padding(fullscreen ? 8 : 5)

            if fullscreen {
                VStack {
                    HStack {
                        Button {
                            HapticFeedback.impact(.medium)
                            model.surveyPlannerPanelVisible = true
                            model.mapFullscreen = true
                        } label: {
                            Label("航线规划", systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.caption.bold())
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                        }
                        .buttonStyle(HUDButtonStyle(tint: .cyan))
                        .frame(width: 132, height: 34)
                        .accessibilityLabel("打开航线规划")
                        Spacer()
                    }
                    Spacer()
                }
                .padding(8)
            }

            if fullscreen {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(mapCaption)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(.black.opacity(0.68), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(8)
                .allowsHitTesting(false)
            }

            if !fullscreen, let eta = surveyETAText {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(eta)
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.72, green: 1, blue: 0.91))
                            .padding(.horizontal, 6)
                            .frame(height: 22)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(5)
                .allowsHitTesting(false)
            }

            if let homeBadge {
                VStack {
                    Spacer()
                    HStack {
                        Text(homeBadge)
                            .font(.system(size: fullscreen ? 12 : 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, fullscreen ? 9 : 5)
                            .padding(.vertical, fullscreen ? 6 : 3)
                            .background(.black.opacity(0.74), in: Capsule())
                            .foregroundStyle(.orange)
                        Spacer()
                    }
                }
                .padding(fullscreen ? 8 : 5)
                .allowsHitTesting(false)
            }
        }
        .background(.black)
    }

    private var surveyETAText: String? {
        let snapshot = model.surveyRuntime.snapshot
        let state: String
        switch snapshot.state {
        case .arming, .running: state = AppLocalization.string("航线执行")
        case .paused: state = AppLocalization.string("航线暂停")
        default: return nil
        }
        return "\(state) · \(etaDuration(snapshot.totalRemainingSeconds))"
    }

    private func etaDuration(_ seconds: Double) -> String {
        let value = max(0, Int(ceil(seconds)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private var mapCaption: String {
        let source: String
        if model.telemetry.connected && model.telemetry.aircraftLocationValid
            && FlightMapRepresentable.isUsableCoordinate(model.telemetry.aircraft) {
            source = "飞机"
        } else if FlightMapRepresentable.hasValidRemoteControllerLocation(model.telemetry) {
            source = "遥控器 · \(model.telemetry.remoteControllerLocationSource)"
        } else {
            source = "上海默认位置"
        }
        let calibration = chinaMapCalibrationMode == .automatic ? "中国校准" : "WGS‑84"
        return "\(mapStyle.label) · \(calibration) · 定位：\(source)"
    }

    private var chinaMapCalibrationMode: ChinaMapCalibrationMode {
        ChinaMapCalibrationMode(rawValue: chinaMapCalibrationRaw) ?? .automatic
    }

    private var homeBadge: String? {
        guard model.telemetry.flying, model.telemetry.connected,
              model.telemetry.aircraftLocationValid, model.telemetry.homeLocationSet,
              FlightMapRepresentable.isUsableCoordinate(model.telemetry.aircraft),
              FlightMapRepresentable.isUsableCoordinate(model.telemetry.home) else { return nil }
        let aircraft = model.telemetry.aircraft
        let home = model.telemetry.home
        let from = CLLocation(latitude: aircraft.latitude, longitude: aircraft.longitude)
        let to = CLLocation(latitude: home.latitude, longitude: home.longitude)
        let bearing = Self.bearing(from: aircraft, to: home)
        return String(format: "H %@ %.0f m", Self.directionArrow(bearing), from.distance(from: to))
    }

    private static func bearing(from: GeoPoint, to: GeoPoint) -> Double {
        let latitude1 = from.latitude * .pi / 180
        let latitude2 = to.latitude * .pi / 180
        let deltaLongitude = (to.longitude - from.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2)
            - sin(latitude1) * cos(latitude2) * cos(deltaLongitude)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func directionArrow(_ bearing: Double) -> String {
        let arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
        return arrows[Int((bearing + 22.5) / 45) % arrows.count]
    }
}

private enum FlightMapStyle: String {
    case satellite
    case standard

    var label: LocalizedStringKey {
        LocalizedStringKey(self == .satellite ? "卫星图" : "标准图")
    }
    var mapType: MKMapType { self == .satellite ? .hybrid : .standard }
}

struct FlightMapRepresentable: UIViewRepresentable {
    var telemetry: FlightTelemetry
    fileprivate var style: FlightMapStyle
    var followsPrimaryLocation: Bool
    var chinaMapCalibrationMode: ChinaMapCalibrationMode

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.showsCompass = false
        view.showsScale = false
        view.isRotateEnabled = false
        view.pointOfInterestFilter = .excludingAll
        return view
    }

    func updateUIView(_ view: MKMapView, context: Context) {
        if context.coordinator.lastMapType != style.mapType {
            context.coordinator.lastMapType = style.mapType
            view.mapType = style.mapType
        }
        context.coordinator.updateRemoteControllerCourse(
            Self.hasValidRemoteControllerLocation(telemetry) ? telemetry.remoteController : nil,
            source: telemetry.remoteControllerLocationSource
        )

        let aircraft = telemetry.connected && telemetry.aircraftLocationValid
            && Self.isUsableCoordinate(telemetry.aircraft)
            ? telemetry.aircraft : nil
        let remoteController = Self.hasValidRemoteControllerLocation(telemetry)
            ? telemetry.remoteController : nil
        let home = telemetry.connected && telemetry.homeLocationSet
            && Self.isUsableCoordinate(telemetry.home)
            ? telemetry.home : nil
        let rcCourse = telemetry.remoteControllerHeading ?? context.coordinator.remoteControllerCourse
        context.coordinator.syncAnnotation(
            kind: .aircraft, point: aircraft, title: "飞机",
            heading: normalizedHeading(telemetry.heading),
            calibrationMode: chinaMapCalibrationMode, in: view
        )
        context.coordinator.syncAnnotation(
            kind: .remoteController, point: remoteController,
            title: rcCourse == nil ? "遥控器 · 朝向不可用" : String(
                format: "遥控器 · %@ %.0f°",
                telemetry.remoteControllerHeadingSource ?? "移动方向", rcCourse!
            ),
            heading: rcCourse, calibrationMode: chinaMapCalibrationMode, in: view
        )
        context.coordinator.syncAnnotation(
            kind: .home, point: home, title: "返航点 H", heading: nil,
            calibrationMode: chinaMapCalibrationMode, in: view
        )
        context.coordinator.syncHomeOverlay(
            aircraft: telemetry.flying ? aircraft : nil,
            home: telemetry.flying ? home : nil,
            calibrationMode: chinaMapCalibrationMode,
            in: view
        )

        let center = aircraft ?? remoteController ?? home
            ?? OpenFlyDemoLocation.shanghaiCityCenter
        let centerKey: String
        if aircraft != nil { centerKey = "aircraft" }
        else if remoteController != nil { centerKey = "remote-controller" }
        else if home != nil { centerKey = "home" }
        else { centerKey = "fallback" }
        let now = Date()
        let shouldFollow = followsPrimaryLocation
            && now.timeIntervalSince(context.coordinator.lastFollowAt) >= 2
        if !context.coordinator.hasCentered
            || context.coordinator.centerSource != centerKey
            || shouldFollow {
            view.setRegion(MKCoordinateRegion(
                center: coordinate(center), latitudinalMeters: 650, longitudinalMeters: 650
            ), animated: false)
            context.coordinator.hasCentered = true
            context.coordinator.centerSource = centerKey
            context.coordinator.lastFollowAt = now
        }
    }

    static func hasValidRemoteControllerLocation(_ telemetry: FlightTelemetry) -> Bool {
        guard telemetry.remoteControllerConnected,
              isUsableCoordinate(telemetry.remoteController) else { return false }
        let source = telemetry.remoteControllerLocationSource
        return !source.contains("默认") && !source.contains("等待") && !source.contains("无定位")
    }

    static func isUsableCoordinate(_ point: GeoPoint) -> Bool {
        let value = coordinate(point)
        return CLLocationCoordinate2DIsValid(value)
            && (abs(point.latitude) > 1e-9 || abs(point.longitude) > 1e-9)
    }

    private func normalizedHeading(_ heading: Double) -> Double? {
        guard heading.isFinite else { return nil }
        let value = heading.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }

    private func coordinate(_ point: GeoPoint) -> CLLocationCoordinate2D {
        let display = ChinaMapCoordinateTransform.wgs84ToMap(.init(
            latitude: point.latitude, longitude: point.longitude,
            altitudeMeters: 0
        ), mode: chinaMapCalibrationMode)
        return .init(latitude: display.latitude, longitude: display.longitude)
    }

    private static func coordinate(_ point: GeoPoint) -> CLLocationCoordinate2D {
        .init(latitude: point.latitude, longitude: point.longitude)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastMapType: MKMapType?
        var hasCentered = false
        var centerSource = ""
        var lastFollowAt = Date.distantPast
        var remoteControllerCourse: Double?
        private var remoteControllerCourseAnchor: GeoPoint?
        private var remoteControllerCourseUpdatedAt = Date.distantPast
        private var remoteControllerSource = ""
        private var annotationsByKind: [FlightMapItem.Kind: FlightMapItem] = [:]
        private var homeOverlay: MKPolyline?
        private var lastHomeAircraft: GeoPoint?
        private var lastHomePoint: GeoPoint?
        private var lastHomeCalibrationMode: ChinaMapCalibrationMode?
        private static let headingIconTag = 9_117

        func syncAnnotation(kind: FlightMapItem.Kind, point: GeoPoint?, title: String,
                            heading: Double?, calibrationMode: ChinaMapCalibrationMode,
                            in mapView: MKMapView) {
            guard let point else {
                if let existing = annotationsByKind.removeValue(forKey: kind) {
                    mapView.removeAnnotation(existing)
                }
                return
            }
            let annotation: FlightMapItem
            let headingChanged: Bool
            if let existing = annotationsByKind[kind] {
                headingChanged = existing.heading != heading
                existing.update(
                    point: point, title: title, heading: heading,
                    chinaMapCalibrationMode: calibrationMode
                )
                annotation = existing
            } else {
                annotation = FlightMapItem(
                    point: point, title: title, kind: kind, heading: heading,
                    chinaMapCalibrationMode: calibrationMode
                )
                annotationsByKind[kind] = annotation
                mapView.addAnnotation(annotation)
                headingChanged = true
            }
            if headingChanged, let annotationView = mapView.view(for: annotation) {
                updateHeading(in: annotationView, for: annotation)
            }
        }

        func syncHomeOverlay(aircraft: GeoPoint?, home: GeoPoint?,
                             calibrationMode: ChinaMapCalibrationMode,
                             in mapView: MKMapView) {
            guard let aircraft, let home else {
                if let homeOverlay { mapView.removeOverlay(homeOverlay) }
                homeOverlay = nil
                lastHomeAircraft = nil
                lastHomePoint = nil
                lastHomeCalibrationMode = nil
                return
            }
            let calibrationChanged = lastHomeCalibrationMode != calibrationMode
            let aircraftMoved = lastHomeAircraft.map { Self.distanceMeters($0, aircraft) >= 0.5 } ?? true
            let homeMoved = lastHomePoint.map { Self.distanceMeters($0, home) >= 0.5 } ?? true
            guard calibrationChanged || aircraftMoved || homeMoved || homeOverlay == nil else { return }
            if let homeOverlay { mapView.removeOverlay(homeOverlay) }
            var coordinates = [home, aircraft].map {
                FlightMapItem.mapCoordinate($0, calibrationMode: calibrationMode)
            }
            let overlay = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            homeOverlay = overlay
            lastHomeAircraft = aircraft
            lastHomePoint = home
            lastHomeCalibrationMode = calibrationMode
            mapView.addOverlay(overlay)
        }

        private static func distanceMeters(_ lhs: GeoPoint, _ rhs: GeoPoint) -> Double {
            let north = (rhs.latitude - lhs.latitude) * 111_132
            let east = (rhs.longitude - lhs.longitude) * 111_320
                * cos((lhs.latitude + rhs.latitude) * .pi / 360)
            return hypot(north, east)
        }

        func updateRemoteControllerCourse(_ point: GeoPoint?, source: String) {
            if source != remoteControllerSource {
                remoteControllerSource = source
                remoteControllerCourseAnchor = point
                remoteControllerCourse = nil
                remoteControllerCourseUpdatedAt = .distantPast
                return
            }
            guard let point else {
                remoteControllerCourseAnchor = nil
                remoteControllerCourse = nil
                remoteControllerCourseUpdatedAt = .distantPast
                return
            }
            guard let anchor = remoteControllerCourseAnchor else {
                remoteControllerCourseAnchor = point
                return
            }
            let from = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
            let to = CLLocation(latitude: point.latitude, longitude: point.longitude)
            // Keep the anchor while stationary. Updating it for every sub-meter GPS
            // sample makes a normally walking RC appear to have no direction forever.
            guard from.distance(from: to) >= 1 else {
                if Date().timeIntervalSince(remoteControllerCourseUpdatedAt) >= 2 {
                    remoteControllerCourse = nil
                }
                return
            }
            let lat1 = anchor.latitude * .pi / 180
            let lat2 = point.latitude * .pi / 180
            let deltaLongitude = (point.longitude - anchor.longitude) * .pi / 180
            let y = sin(deltaLongitude) * cos(lat2)
            let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
            let degrees = atan2(y, x) * 180 / .pi
            remoteControllerCourse = degrees < 0 ? degrees + 360 : degrees
            remoteControllerCourseAnchor = point
            remoteControllerCourseUpdatedAt = Date()
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let item = annotation as? FlightMapItem else { return nil }
            let identifier = "openfly-\(item.kind.rawValue)"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKAnnotationView(annotation: item, reuseIdentifier: identifier)
            view.annotation = item
            view.canShowCallout = true
            view.frame = CGRect(x: 0, y: 0, width: 38, height: 38)
            view.centerOffset = CGPoint(x: 0, y: -3)
            view.subviews.forEach { $0.removeFromSuperview() }

            switch item.kind {
            case .home:
                let label = UILabel(frame: view.bounds.insetBy(dx: 4, dy: 4))
                label.text = "H"
                label.textAlignment = .center
                label.font = .systemFont(ofSize: 17, weight: .black)
                label.textColor = .white
                label.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.94)
                label.layer.cornerRadius = 15
                label.layer.masksToBounds = true
                label.layer.borderWidth = 2
                label.layer.borderColor = UIColor.white.cgColor
                view.addSubview(label)
            case .aircraft:
                let icon = UIImageView(image: AircraftMapMarkerImage.djiStyle)
                icon.tag = Self.headingIconTag
                icon.frame = CGRect(
                    x: (view.bounds.width - 22) / 2,
                    y: (view.bounds.height - 27) / 2,
                    width: 22, height: 27
                )
                icon.contentMode = .scaleAspectFit
                view.addSubview(icon)
            case .remoteController:
                let disk = UIView(frame: view.bounds.insetBy(dx: 3, dy: 3))
                disk.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.94)
                disk.layer.cornerRadius = 16
                disk.layer.borderWidth = 2
                disk.layer.borderColor = UIColor.white.cgColor
                let icon = UIImageView(frame: disk.bounds.insetBy(dx: 7, dy: 7))
                icon.tag = Self.headingIconTag
                icon.contentMode = .scaleAspectFit
                icon.tintColor = .white
                icon.image = UIImage(systemName: "location.north.line.fill")
                disk.addSubview(icon)
                view.addSubview(disk)
            }
            updateHeading(in: view, for: item)
            return view
        }

        private func updateHeading(in view: MKAnnotationView, for item: FlightMapItem) {
            guard let icon = view.viewWithTag(Self.headingIconTag) as? UIImageView else { return }
            let radians = (item.heading ?? 0) * .pi / 180
            icon.transform = CGAffineTransform(rotationAngle: radians)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.systemOrange.withAlphaComponent(0.94)
            renderer.lineWidth = 2
            renderer.lineDashPattern = [6, 5]
            return renderer
        }
    }

    final class FlightMapItem: NSObject, MKAnnotation {
        enum Kind: String { case aircraft, remoteController, home }
        @objc dynamic private(set) var coordinate: CLLocationCoordinate2D
        @objc dynamic private(set) var title: String?
        let kind: Kind
        private(set) var heading: Double?

        init(point: GeoPoint, title: String, kind: Kind, heading: Double?,
             chinaMapCalibrationMode: ChinaMapCalibrationMode) {
            coordinate = Self.mapCoordinate(point, calibrationMode: chinaMapCalibrationMode)
            self.title = title
            self.kind = kind
            self.heading = heading
        }

        func update(point: GeoPoint, title: String, heading: Double?,
                    chinaMapCalibrationMode: ChinaMapCalibrationMode) {
            let nextCoordinate = Self.mapCoordinate(point, calibrationMode: chinaMapCalibrationMode)
            if abs(nextCoordinate.latitude - coordinate.latitude) > 1e-9
                || abs(nextCoordinate.longitude - coordinate.longitude) > 1e-9 {
                coordinate = nextCoordinate
            }
            if self.title != title { self.title = title }
            self.heading = heading
        }

        static func mapCoordinate(_ point: GeoPoint,
                                  calibrationMode: ChinaMapCalibrationMode) -> CLLocationCoordinate2D {
            let display = ChinaMapCoordinateTransform.wgs84ToMap(.init(
                latitude: point.latitude, longitude: point.longitude,
                altitudeMeters: 0
            ), mode: calibrationMode)
            return .init(latitude: display.latitude, longitude: display.longitude)
        }
    }
}
