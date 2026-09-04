import Clipper2
import Foundation

enum SurveyPlanner {
    struct MissionStatistics: Equatable {
        var passCountByView: [SurveyCaptureView: Int]
        var photoCountByView: [SurveyCaptureView: Int]
        var estimatedStorageMegabytes: Double
        var estimatedSorties: Int
        var assumedJpegMegabytes: Double
        var assumedUsableSortieSeconds: Double
        var sorties: [SurveySortie]
    }

    struct SurveySortie: Equatable {
        var sortieNumber: Int
        var firstWaypointIndex: Int
        var lastWaypointIndex: Int
        var estimatedPathMeters: Double
        var estimatedFlightSeconds: Double
        var estimatedPhotoCount: Int
    }

    struct TargetArea: Equatable { var boundary: [SurveyGeoPoint]; var areaSquareMeters: Double }
    struct GroundCoverage: Equatable { var boundary: [SurveyGeoPoint]; var areaSquareMeters: Double }

    private struct LocalPoint: Equatable { var east: Double; var north: Double }
    private struct LocalFrame {
        var origin: SurveyGeoPoint
        private var metersPerDegreeLongitude: Double {
            111_320 * cos(origin.latitude * .pi / 180)
        }
        func local(_ point: SurveyGeoPoint) -> LocalPoint {
            .init(east: (point.longitude - origin.longitude) * metersPerDegreeLongitude,
                  north: (point.latitude - origin.latitude) * 111_132)
        }
        func geo(_ point: LocalPoint, altitude: Double) -> SurveyGeoPoint {
            .init(latitude: origin.latitude + point.north / 111_132,
                  longitude: origin.longitude + point.east / metersPerDegreeLongitude,
                  altitudeMeters: altitude)
        }
    }
    private struct LocalPass { var start: LocalPoint; var end: LocalPoint; var scanLineIndex: Int }
    private struct RouteGroup {
        var routeHeading: Double
        var cameraHeading: Double?
        var pitch: Double
        var view: SurveyCaptureView
    }
    private struct PlannedPass { var pass: LocalPass; var group: RouteGroup; var coverage: SurveyCoveragePlanner.Coverage }

    static func plan(name: String, roi: [SurveyGeoPoint],
                     camera: SurveyCameraProfile = .djiMini2,
                     constraints: SurveyConstraints = .init(),
                     takeoffPoint: SurveyGeoPoint? = nil) throws -> SurveyMission {
        try camera.validate(); try constraints.validate()
        let normalizedROI = try normalizeAndValidateROI(roi)
        let frame = LocalFrame(origin: centroid(normalizedROI))
        let polygon = normalizedROI.map(frame.local)
        let extentEast = polygon.map(\.east).max()! - polygon.map(\.east).min()!
        let extentNorth = polygon.map(\.north).max()! - polygon.map(\.north).min()!
        guard hypot(extentEast, extentNorth) <= 10_000 else {
            throw SurveyValidationError.invalid("ROI extent exceeds the 10 km planning safety limit")
        }
        let nadirCoverage = SurveyCoveragePlanner.coverage(camera: camera, constraints: constraints)
        var passes: [PlannedPass] = []
        var orderingReference = takeoffPoint.map(frame.local)
        for (index, group) in routeGroups(constraints).enumerated() {
            let coverage = group.view == .nadir ? nadirCoverage
                : try SurveyCoveragePlanner.obliqueCoverage(camera: camera, constraints: constraints)
            let generated = try generatePasses(
                polygon: polygon, headingDegrees: group.routeHeading,
                spacingMeters: coverage.lineSpacingMeters,
                footprintWidthMeters: coverage.footprintWidthMeters,
                boundaryMarginMeters: constraints.boundaryMarginMeters
            )
            let mode = index == 0 ? constraints.startPointMode : .autoNearest
            let ordered = orientPasses(generated, mode: mode, reference: orderingReference)
            passes += ordered.map { .init(pass: $0, group: group, coverage: coverage) }
            orderingReference = ordered.last?.end ?? orderingReference
        }
        guard !passes.isEmpty else {
            throw SurveyValidationError.invalid("ROI is too small for the selected survey settings")
        }

        var waypoints: [SurveyWaypoint] = []
        var path = 0.0
        var photos = 0
        var previous: LocalPoint?
        for (passIndex, planned) in passes.enumerated() {
            let pass = planned.pass
            let routeHeading = headingDegrees(pass.start, pass.end)
            let heading = constraints.obliqueHeadingMode == .fixedCaptureDirection
                ? (planned.group.cameraHeading ?? routeHeading) : routeHeading
            if let previous { path += distance(previous, pass.start) }
            let passLength = distance(pass.start, pass.end)
            path += passLength
            let interval = constraints.captureTriggerMode == .distance
                ? planned.coverage.captureIntervalMeters
                : constraints.speed(for: planned.group.view) * constraints.timedCaptureIntervalSeconds
            photos += max(2, Int(ceil(passLength / interval)) + 1)
            waypoints.append(.init(
                point: frame.geo(pass.start, altitude: constraints.effectiveFlightAltitudeMeters),
                headingDegrees: heading, gimbalPitchDegrees: planned.group.pitch,
                kind: .passStart, captureAction: .startDistanceInterval,
                captureIntervalMeters: interval, passIndex: passIndex, captureView: planned.group.view
            ))
            waypoints.append(.init(
                point: frame.geo(pass.end, altitude: constraints.effectiveFlightAltitudeMeters),
                headingDegrees: heading, gimbalPitchDegrees: planned.group.pitch,
                kind: .passEnd, captureAction: .stopDistanceInterval,
                captureIntervalMeters: nil, passIndex: passIndex, captureView: planned.group.view
            ))
            previous = pass.end
        }
        let mission = SurveyMission(
            name: name, cameraProfile: camera, constraints: constraints, roi: normalizedROI,
            waypoints: waypoints, estimatedPathMeters: path, estimatedPhotoCount: photos,
            estimatedFlightSeconds: estimateRouteSeconds(waypoints, constraints: constraints)
        )
        try mission.validate()
        return mission
    }

    static func estimateRouteSeconds(_ waypoints: [SurveyWaypoint], constraints: SurveyConstraints) -> Double {
        var total = waypoints.first.map {
            SurveyETAPolicy.captureDelaySeconds(for: $0.captureAction)
        } ?? 0
        for (start, end) in zip(waypoints, waypoints.dropFirst()) {
            var seconds = SurveyCaptureSchedule.distance(start.point, end.point)
                / max(0.2, constraints.speed(for: end.captureView))
            let yaw = abs(((end.headingDegrees - start.headingDegrees)
                .truncatingRemainder(dividingBy: 360) + 540)
                .truncatingRemainder(dividingBy: 360) - 180)
            if yaw > SurveyWaypointFollower.headingToleranceDegrees {
                seconds += 2 + yaw / SurveyWaypointFollower.maxYawRateDegreesPerSecond
            }
            if abs(start.gimbalPitchDegrees - end.gimbalPitchDegrees) > 5 { seconds += 3 }
            seconds += SurveyETAPolicy.captureDelaySeconds(for: end.captureAction)
            total += seconds
        }
        return total
    }

    static func suggestedRouteHeading(_ roi: [SurveyGeoPoint]) throws -> Double {
        let normalized = try normalizeAndValidateROI(roi)
        let frame = LocalFrame(origin: centroid(normalized))
        let polygon = normalized.map(frame.local)
        var bestArea = Double.infinity
        var bestLongSpan = -Double.infinity
        var bestHeading = 0.0
        for index in polygon.indices {
            let start = polygon[index], end = polygon[(index + 1) % polygon.count]
            guard distance(start, end) >= 1e-6 else { continue }
            let edgeHeading = headingDegrees(start, end)
            let angle = (90 - edgeHeading) * .pi / 180
            let rotated = polygon.map { rotate($0, angle: -angle) }
            let along = rotated.map(\.east).max()! - rotated.map(\.east).min()!
            let cross = rotated.map(\.north).max()! - rotated.map(\.north).min()!
            let area = along * cross, longSpan = max(along, cross)
            let longHeading = normalizeHeading(edgeHeading + (along >= cross ? 0 : 90))
                .truncatingRemainder(dividingBy: 180)
            if area < bestArea - 1e-6 || (abs(area - bestArea) <= 1e-6 && longSpan > bestLongSpan) {
                bestArea = area; bestLongSpan = longSpan; bestHeading = longHeading
            }
        }
        return bestHeading
    }

    static func statistics(_ mission: SurveyMission, assumedJpegMegabytes: Double = 5,
                           assumedUsableSortieSeconds: Double = 20 * 60) throws -> MissionStatistics {
        guard assumedJpegMegabytes > 0, assumedUsableSortieSeconds > 0 else {
            throw SurveyValidationError.invalid("survey statistics assumptions must be positive")
        }
        let frame = LocalFrame(origin: centroid(mission.roi))
        var passes: [SurveyCaptureView: Int] = [:]
        var photos: [SurveyCaptureView: Int] = [:]
        for pass in try mission.surveyPasses() {
            let start = pass.start
            guard let interval = start.captureIntervalMeters else { continue }
            let passLength = zip(pass.waypoints, pass.waypoints.dropFirst()).reduce(0.0) {
                $0 + distance(frame.local($1.0.point), frame.local($1.1.point))
            }
            let count = max(2, Int(ceil(passLength / interval)) + 1)
            passes[start.captureView, default: 0] += 1
            photos[start.captureView, default: 0] += count
        }
        let sortiePlan = try planSorties(mission, usableSortieSeconds: assumedUsableSortieSeconds)
        return .init(passCountByView: passes, photoCountByView: photos,
                     estimatedStorageMegabytes: Double(photos.values.reduce(0, +)) * assumedJpegMegabytes,
                     estimatedSorties: sortiePlan.count, assumedJpegMegabytes: assumedJpegMegabytes,
                     assumedUsableSortieSeconds: assumedUsableSortieSeconds, sorties: sortiePlan)
    }

    static func planSorties(_ mission: SurveyMission,
                            usableSortieSeconds: Double = 20 * 60) throws -> [SurveySortie] {
        guard usableSortieSeconds.isFinite, usableSortieSeconds > 0 else {
            throw SurveyValidationError.invalid("usable sortie duration must be positive")
        }
        let frame = LocalFrame(origin: centroid(mission.roi))
        struct Estimate {
            var first: Int; var last: Int; var start: LocalPoint; var end: LocalPoint
            var path: Double; var seconds: Double; var photos: Int
            var startWaypoint: SurveyWaypoint; var endWaypoint: SurveyWaypoint
        }
        let photoCounts = Dictionary(grouping: try SurveyCaptureSchedule.build(mission), by: \.passIndex)
            .mapValues(\.count)
        var estimates: [Estimate] = []
        for pass in try mission.surveyPasses() {
            let start = frame.local(pass.start.point)
            let end = frame.local(pass.end.point)
            let path = zip(pass.waypoints, pass.waypoints.dropFirst()).reduce(0.0) {
                $0 + distance(frame.local($1.0.point), frame.local($1.1.point))
            }
            estimates.append(.init(first: pass.firstWaypointIndex, last: pass.lastWaypointIndex, start: start, end: end,
                                   path: path,
                                   seconds: estimateRouteSeconds(pass.waypoints, constraints: mission.constraints),
                                   photos: photoCounts[pass.start.passIndex] ?? 0,
                                   startWaypoint: pass.start, endWaypoint: pass.end))
        }
        var result: [SurveySortie] = []
        var first = -1, last = -1, photoCount = 0
        var path = 0.0, seconds = 0.0
        var previous: LocalPoint?
        var previousWaypoint: SurveyWaypoint?
        func flush() {
            guard first >= 0 else { return }
            result.append(.init(sortieNumber: result.count + 1, firstWaypointIndex: first,
                                lastWaypointIndex: last, estimatedPathMeters: path,
                                estimatedFlightSeconds: seconds,
                                estimatedPhotoCount: photoCount))
            first = -1; last = -1; photoCount = 0; path = 0; seconds = 0
            previous = nil; previousWaypoint = nil
        }
        for estimate in estimates {
            let transitionSeconds = previousWaypoint.map {
                estimateRouteSeconds([$0, estimate.startWaypoint], constraints: mission.constraints)
                    - SurveyETAPolicy.captureDelaySeconds(for: estimate.startWaypoint.captureAction)
            } ?? 0
            let additionSeconds = transitionSeconds + estimate.seconds
            if first >= 0 && seconds + additionSeconds > usableSortieSeconds { flush() }
            if first < 0 { first = estimate.first }
            let actualTransition = previous.map { distance($0, estimate.start) } ?? 0
            path += actualTransition + estimate.path
            seconds += transitionSeconds + estimate.seconds
            photoCount += estimate.photos; last = estimate.last; previous = estimate.end
            previousWaypoint = estimate.endWaypoint
        }
        flush()
        return result
    }

    static func targetArea(_ mission: SurveyMission) throws -> TargetArea {
        let frame = LocalFrame(origin: centroid(mission.roi))
        let expanded = try expandPolygon(mission.roi.map(frame.local), by: mission.constraints.boundaryMarginMeters)
        return .init(boundary: expanded.map { frame.geo($0, altitude: mission.constraints.altitudeMetersAgl) },
                     areaSquareMeters: abs(signedArea(expanded)))
    }

    static func groundCoverage(_ mission: SurveyMission) throws -> GroundCoverage {
        let frame = LocalFrame(origin: centroid(mission.roi))
        let coverage = SurveyCoveragePlanner.coverage(camera: mission.cameraProfile, constraints: mission.constraints)
        let allPasses = try mission.surveyPasses()
        let previewPasses: [SurveyPassWaypoints]
        if mission.constraints.collectionMode == .obliqueFiveDirection {
            let nadir = allPasses.filter { $0.start.captureView == .nadir }
            let view = allPasses.first?.start.captureView
            previewPasses = nadir.isEmpty ? allPasses.filter { $0.start.captureView == view } : nadir
        } else {
            previewPasses = allPasses
        }
        let pairs = previewPasses.compactMap { pass in
            passFootprint(frame.local(pass.start.point), frame.local(pass.end.point),
                                 halfWidth: coverage.footprintWidthMeters / 2,
                                 halfLength: coverage.footprintLengthMeters / 2)
        }
        guard !pairs.isEmpty else { throw SurveyValidationError.invalid("mission has no measurable survey passes") }
        let union = Clipper.union(pairs.map(path), .nonZero)
        guard let largest = union.max(by: { abs(pathArea($0)) < abs(pathArea($1)) }) else {
            throw SurveyValidationError.invalid("coverage union produced no polygon")
        }
        let local = largest.map { LocalPoint(east: $0.x, north: $0.y) }
        return .init(boundary: local.map { frame.geo($0, altitude: mission.constraints.altitudeMetersAgl) },
                     areaSquareMeters: union.reduce(0) { $0 + abs(pathArea($1)) })
    }

    private static func routeGroups(_ value: SurveyConstraints) -> [RouteGroup] {
        let base = normalizeHeading(value.routeHeadingDegrees)
        func group(_ route: Double, _ camera: Double?, _ pitch: Double, _ view: SurveyCaptureView) -> RouteGroup {
            .init(routeHeading: normalizeHeading(route),
                  cameraHeading: camera.map { normalizeHeading($0) }, pitch: pitch, view: view)
        }
        switch value.collectionMode {
        case .ortho: return [group(base, base, -90, .nadir)]
        case .crosshatchNadir:
            return [group(base, base, value.gimbalPitchDegrees, .nadir),
                    group(base + 90, base + 90, value.gimbalPitchDegrees, .nadir)]
        case .obliqueFiveDirection:
            return [
                group(base, base, -90, .nadir),
                group(base, base, value.obliqueGimbalPitchDegrees, .forwardOblique),
                group(base, base + 180, value.obliqueGimbalPitchDegrees, .backwardOblique),
                group(base + 90, base - 90, value.obliqueGimbalPitchDegrees, .leftOblique),
                group(base + 90, base + 90, value.obliqueGimbalPitchDegrees, .rightOblique),
            ].filter { value.enabledCaptureViews.contains($0.view) }
        }
    }

    private static func generatePasses(polygon: [LocalPoint], headingDegrees: Double,
                                       spacingMeters: Double, footprintWidthMeters: Double,
                                       boundaryMarginMeters: Double) throws -> [LocalPass] {
        let angle = (90 - normalizeHeading(headingDegrees)) * .pi / 180
        let rotated = polygon.map { rotate($0, angle: -angle) }
        let coveragePolygon = try expandPolygon(rotated, by: boundaryMarginMeters)
        let minY = coveragePolygon.map(\.north).min()!, maxY = coveragePolygon.map(\.north).max()!
        let span = maxY - minY
        guard span >= 0.2 else { return [] }
        let pilotCount = max(1, Int((span / spacingMeters).rounded()))
        let safeCount = span <= footprintWidthMeters ? 1
            : Int(ceil((span - footprintWidthMeters) / spacingMeters)) + 1
        let lineCount = max(pilotCount, safeCount)
        guard lineCount <= 5_000 else { throw SurveyValidationError.invalid("survey requires too many flight lines") }
        let firstY = (minY + maxY - Double(lineCount - 1) * spacingMeters) / 2
        var result: [LocalPass] = [], reverse = false
        for index in 0..<lineCount {
            let y = firstY + Double(index) * spacingMeters
            let intersections = horizontalIntersections(coveragePolygon, y: y)
            var segments: [LocalPass] = []
            var offset = 0
            while offset + 1 < intersections.count {
                let start = intersections[offset], end = intersections[offset + 1]
                if end - start >= 0.2 {
                    segments.append(.init(
                        start: .init(east: start, north: y),
                        end: .init(east: end, north: y),
                        scanLineIndex: index
                    ))
                }
                offset += 2
            }
            let ordered = reverse ? Array(segments.reversed()) : segments
            for segment in ordered {
                let oriented = reverse
                    ? LocalPass(start: segment.end, end: segment.start, scanLineIndex: index)
                    : segment
                result.append(.init(
                    start: rotate(oriented.start, angle: angle),
                    end: rotate(oriented.end, angle: angle),
                    scanLineIndex: index
                ))
            }
            if !segments.isEmpty { reverse.toggle() }
        }
        return result
    }

    private static func expandPolygon(_ polygon: [LocalPoint], by margin: Double) throws -> [LocalPoint] {
        guard margin > 1e-9 else { return polygon }
        let inflated = try Clipper.inflatePaths([path(polygon)], margin, .miter, .polygon, 5, 0, 8)
        guard let largest = inflated.max(by: { abs(pathArea($0)) < abs(pathArea($1)) }), largest.count >= 3 else {
            throw SurveyValidationError.invalid("ROI boundary expansion produced an empty polygon")
        }
        return largest.map { .init(east: $0.x, north: $0.y) }
    }

    private static func normalizeAndValidateROI(_ roi: [SurveyGeoPoint]) throws -> [SurveyGeoPoint] {
        var result = roi
        if result.count > 3, result.first == result.last { result.removeLast() }
        guard result.count >= 3 else { throw SurveyValidationError.invalid("ROI requires at least three vertices") }
        try result.forEach { try $0.validate() }
        let local = result.map(LocalFrame(origin: centroid(result)).local)
        guard abs(signedArea(local)) >= 1 else { throw SurveyValidationError.invalid("ROI area must be at least 1 square meter") }
        guard !hasSelfIntersection(local) else { throw SurveyValidationError.invalid("ROI polygon is not geometrically valid") }
        return result
    }

    private static func orientPasses(_ passes: [LocalPass], mode: SurveyStartPointMode,
                                     reference: LocalPoint?) -> [LocalPass] {
        guard !passes.isEmpty else { return [] }
        func reversedLine(_ line: [LocalPass]) -> [LocalPass] {
            line.reversed().map {
                .init(start: $0.end, end: $0.start, scanLineIndex: $0.scanLineIndex)
            }
        }
        let lines = Dictionary(grouping: passes, by: \.scanLineIndex)
            .sorted { $0.key < $1.key }.map(\.value)
        func rows(_ values: [[LocalPass]], flipped: Bool) -> [LocalPass] {
            values.flatMap { flipped ? reversedLine($0) : $0 }
        }
        let rowCandidates = [
            rows(lines, flipped: false), rows(lines, flipped: true),
            rows(Array(lines.reversed()), flipped: false),
            rows(Array(lines.reversed()), flipped: true),
        ]
        let candidates: [[LocalPass]] = lines.allSatisfy { $0.count == 1 }
            ? rowCandidates : rowCandidates.map { candidate in
                var remaining = passes
                var result: [LocalPass] = []
                var selected = candidate[0]
                guard let seed = remaining.firstIndex(where: {
                    $0.scanLineIndex == selected.scanLineIndex &&
                        (($0.start == selected.start && $0.end == selected.end) ||
                         ($0.start == selected.end && $0.end == selected.start))
                }) else { preconditionFailure("selected survey segment is missing") }
                remaining.remove(at: seed)
                result.append(selected)
                while !remaining.isEmpty {
                    let endpoint = selected.end
                    let index = remaining.indices.min { left, right in
                        let leftDistance = min(distance(endpoint, remaining[left].start),
                                               distance(endpoint, remaining[left].end))
                        let rightDistance = min(distance(endpoint, remaining[right].start),
                                                distance(endpoint, remaining[right].end))
                        if abs(leftDistance - rightDistance) > 1e-9 {
                            return leftDistance < rightDistance
                        }
                        return abs(remaining[left].scanLineIndex - selected.scanLineIndex)
                            < abs(remaining[right].scanLineIndex - selected.scanLineIndex)
                    }!
                    let next = remaining.remove(at: index)
                    selected = distance(endpoint, next.start) <= distance(endpoint, next.end)
                        ? next : .init(start: next.end, end: next.start,
                                      scanLineIndex: next.scanLineIndex)
                    result.append(selected)
                }
                if result.count <= 512 {
                    let limit = result.count <= 128 ? 128 : 12
                    var active = true
                    var iteration = 0
                    while active && iteration < limit {
                        active = false
                        iteration += 1
                        improvement: for left in 1..<result.count {
                            for right in left..<result.count {
                                let before = result[left - 1]
                                let first = result[left]
                                let last = result[right]
                                let after = right + 1 < result.count ? result[right + 1] : nil
                                let old = distance(before.end, first.start)
                                    + (after.map { distance(last.end, $0.start) } ?? 0)
                                let replacement = distance(before.end, last.end)
                                    + (after.map { distance(first.start, $0.start) } ?? 0)
                                if replacement + 0.01 < old {
                                    let reversed = result[left...right].reversed().map {
                                        LocalPass(start: $0.end, end: $0.start,
                                                  scanLineIndex: $0.scanLineIndex)
                                    }
                                    result.replaceSubrange(left...right, with: reversed)
                                    active = true
                                    break improvement
                                }
                            }
                        }
                    }
                }
                return result
            }
        switch mode {
        case .firstRouteStart: return candidates[0]
        case .routeCorner2: return candidates[1]
        case .routeCorner3: return candidates[2]
        case .routeCorner4: return candidates[3]
        case .autoNearest:
            guard let reference else {
                return candidates.min(by: { connectorDistance($0) < connectorDistance($1) }) ?? candidates[0]
            }
            return candidates.min(by: {
                distance(reference, $0[0].start) + connectorDistance($0)
                    < distance(reference, $1[0].start) + connectorDistance($1)
            }) ?? candidates[0]
        case .custom:
            guard let reference else { return candidates[0] }
            return candidates.min(by: {
                distance(reference, $0[0].start) < distance(reference, $1[0].start)
            }) ?? candidates[0]
        }
    }

    private static func connectorDistance(_ passes: [LocalPass]) -> Double {
        zip(passes, passes.dropFirst()).reduce(0) { $0 + distance($1.0.end, $1.1.start) }
    }

    private static func horizontalIntersections(_ polygon: [LocalPoint], y: Double) -> [Double] {
        var values: [Double] = []
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let minY = min(a.north, b.north), maxY = max(a.north, b.north)
            if y < minY || y >= maxY || abs(b.north - a.north) < 1e-9 { continue }
            let ratio = (y - a.north) / (b.north - a.north)
            values.append(a.east + ratio * (b.east - a.east))
        }
        return values.sorted()
    }

    private static func passFootprint(_ start: LocalPoint, _ end: LocalPoint,
                                      halfWidth: Double, halfLength: Double) -> [LocalPoint]? {
        let length = distance(start, end)
        guard length >= 1e-6 else { return nil }
        let alongEast = (end.east - start.east) / length, alongNorth = (end.north - start.north) / length
        let crossEast = -alongNorth, crossNorth = alongEast
        let extendedStart = LocalPoint(east: start.east - alongEast * halfLength, north: start.north - alongNorth * halfLength)
        let extendedEnd = LocalPoint(east: end.east + alongEast * halfLength, north: end.north + alongNorth * halfLength)
        func offset(_ point: LocalPoint, _ sign: Double) -> LocalPoint {
            .init(east: point.east + crossEast * halfWidth * sign,
                  north: point.north + crossNorth * halfWidth * sign)
        }
        return [offset(extendedStart, 1), offset(extendedEnd, 1), offset(extendedEnd, -1), offset(extendedStart, -1)]
    }

    private static func hasSelfIntersection(_ points: [LocalPoint]) -> Bool {
        guard points.count >= 4 else { return false }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            for j in (i + 1)..<points.count {
                if j == i || j == (i + 1) % points.count || (j + 1) % points.count == i { continue }
                if segmentsIntersect(a, b, points[j], points[(j + 1) % points.count]) { return true }
            }
        }
        return false
    }

    private static func segmentsIntersect(_ a: LocalPoint, _ b: LocalPoint,
                                          _ c: LocalPoint, _ d: LocalPoint) -> Bool {
        func cross(_ p: LocalPoint, _ q: LocalPoint, _ r: LocalPoint) -> Double {
            (q.east - p.east) * (r.north - p.north) - (q.north - p.north) * (r.east - p.east)
        }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        return ((abC > 1e-9 && abD < -1e-9) || (abC < -1e-9 && abD > 1e-9))
            && ((cdA > 1e-9 && cdB < -1e-9) || (cdA < -1e-9 && cdB > 1e-9))
    }

    private static func path(_ points: [LocalPoint]) -> PathD { points.map { PointD($0.east, $0.north) } }
    private static func pathArea(_ value: PathD) -> Double {
        guard value.count >= 3 else { return 0 }
        return value.indices.reduce(0) { sum, index in
            let a = value[index], b = value[(index + 1) % value.count]
            return sum + a.x * b.y - b.x * a.y
        } / 2
    }
    private static func signedArea(_ value: [LocalPoint]) -> Double {
        value.indices.reduce(0) { sum, index in
            let a = value[index], b = value[(index + 1) % value.count]
            return sum + a.east * b.north - b.east * a.north
        } / 2
    }
    private static func centroid(_ points: [SurveyGeoPoint]) -> SurveyGeoPoint {
        .init(latitude: points.map(\.latitude).reduce(0, +) / Double(points.count),
              longitude: points.map(\.longitude).reduce(0, +) / Double(points.count))
    }
    private static func rotate(_ point: LocalPoint, angle: Double) -> LocalPoint {
        .init(east: point.east * cos(angle) - point.north * sin(angle),
              north: point.east * sin(angle) + point.north * cos(angle))
    }
    private static func distance(_ a: LocalPoint, _ b: LocalPoint) -> Double { hypot(a.east - b.east, a.north - b.north) }
    private static func headingDegrees(_ a: LocalPoint, _ b: LocalPoint) -> Double {
        normalizeHeading(atan2(b.east - a.east, b.north - a.north) * 180 / .pi)
    }
    private static func normalizeHeading(_ value: Double) -> Double {
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }
}
