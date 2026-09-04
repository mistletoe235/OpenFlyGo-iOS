import Foundation

struct BuildingHeightTile: Equatable {
    var x: Int; var y: Int
    var west: Double; var south: Double; var east: Double; var north: Double
}

enum GlobalBuildingHeightTiles {
    static let tileSpanDegrees = 0.2, maximumROISpanDegrees = 0.25, maximumTileCount = 9

    static func covering(_ roi: [SurveyGeoPoint]) throws -> [BuildingHeightTile] {
        guard roi.count >= 3 else { throw SurveyValidationError.invalid("请先绘制至少 3 个规划区边界点") }
        let west = roi.map(\.longitude).min()!, east = roi.map(\.longitude).max()!
        let south = roi.map(\.latitude).min()!, north = roi.map(\.latitude).max()!
        guard west >= -180, east <= 180, south >= -90, north <= 90, east > west, north > south else {
            throw SurveyValidationError.invalid("建筑高度请求区域无效")
        }
        guard east - west <= maximumROISpanDegrees, north - south <= maximumROISpanDegrees else {
            throw SurveyValidationError.invalid("建筑高度请求范围超过 0.25°；请缩小规划区")
        }
        func x(_ value: Double) -> Int { min(1799, max(0, Int(floor((value + 180) / tileSpanDegrees)))) }
        func y(_ value: Double) -> Int { min(899, max(0, Int(floor((value + 90) / tileSpanDegrees)))) }
        var result: [BuildingHeightTile] = []
        for row in y(south)...y(north) { for column in x(west)...x(east) {
            let tileWest = -180 + Double(column) * tileSpanDegrees
            let tileSouth = -90 + Double(row) * tileSpanDegrees
            result.append(.init(x: column, y: row, west: tileWest, south: tileSouth,
                                east: tileWest + tileSpanDegrees, north: tileSouth + tileSpanDegrees))
        } }
        guard result.count <= maximumTileCount else {
            throw SurveyValidationError.invalid("规划区跨越过多建筑高度分块")
        }
        return result
    }

    static func url(template: String, tile: BuildingHeightTile) throws -> URL {
        guard template.hasPrefix("https://") || template.hasPrefix("http://"),
              template.contains("{x}"), template.contains("{y}") else {
            throw SurveyValidationError.invalid("建筑高度 COG 模板必须使用 HTTP(S) 并包含 {x}、{y}")
        }
        func coordinate(_ value: Double) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }
        let raw = template.replacingOccurrences(of: "{x}", with: "\(tile.x)")
            .replacingOccurrences(of: "{y}", with: "\(tile.y)")
            .replacingOccurrences(of: "{west}", with: coordinate(tile.west))
            .replacingOccurrences(of: "{south}", with: coordinate(tile.south))
            .replacingOccurrences(of: "{east}", with: coordinate(tile.east))
            .replacingOccurrences(of: "{north}", with: coordinate(tile.north))
        guard let url = URL(string: raw) else { throw SurveyValidationError.invalid("建筑高度 URL 无效") }
        return url
    }
}

struct TiledTerrainElevationSource: TerrainElevationSource {
    var tiles: [GeoTIFFTerrain]
    let info: TerrainRasterInfo

    init(tiles: [GeoTIFFTerrain], displayName: String) throws {
        guard !tiles.isEmpty else { throw SurveyValidationError.invalid("建筑高度分块为空") }
        self.tiles = tiles
        info = .init(displayName: displayName, width: tiles.map(\.info.width).reduce(0, +),
            height: tiles.map(\.info.height).max()!, epsg: 4326, noDataValue: nil,
            pixelSizeX: tiles.map(\.info.pixelSizeX).min()!, pixelSizeY: tiles.map(\.info.pixelSizeY).min()!,
            minimumLatitude: tiles.map(\.info.minimumLatitude).min()!, maximumLatitude: tiles.map(\.info.maximumLatitude).max()!,
            minimumLongitude: tiles.map(\.info.minimumLongitude).min()!, maximumLongitude: tiles.map(\.info.maximumLongitude).max()!)
    }

    func elevationMeters(latitude: Double, longitude: Double) throws -> Double {
        let candidates = tiles.filter { latitude >= $0.info.minimumLatitude && latitude <= $0.info.maximumLatitude
            && longitude >= $0.info.minimumLongitude && longitude <= $0.info.maximumLongitude }
        guard !candidates.isEmpty else { throw SurveyValidationError.invalid("坐标超出建筑高度分块覆盖范围") }
        for tile in candidates { if let value = try? tile.elevationMeters(latitude: latitude, longitude: longitude) { return value } }
        throw SurveyValidationError.invalid("建筑高度分块在目标位置包含 NoData")
    }
}

struct BuildingHeightDownloadResult {
    var terrain: TiledTerrainElevationSource; var sha256: String
    var downloadedTiles: Int; var cachedTiles: Int
}

actor GlobalBuildingHeightDownloader {
    private let cacheRoot: URL
    init() throws {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        cacheRoot = root.appendingPathComponent("global-terrain/building-height-cog-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    func download(roi: [SurveyGeoPoint], template: String,
                  progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> BuildingHeightDownloadResult {
        let requests = try GlobalBuildingHeightTiles.covering(roi)
        var rasters: [GeoTIFFTerrain] = [], hashes: [String] = [], downloaded = 0, cached = 0
        for (index, tile) in requests.enumerated() {
            let sourceURL = try GlobalBuildingHeightTiles.url(template: template, tile: tile)
            let key = SurveyTerrainPlanner.sha256(Data(sourceURL.absoluteString.utf8)).prefix(24)
            let file = cacheRoot.appendingPathComponent("\(key).tif")
            let data: Data
            if let existing = try? Data(contentsOf: file), !existing.isEmpty { data = existing; cached += 1 }
            else {
                var request = URLRequest(url: sourceURL, timeoutInterval: 120)
                request.setValue("image/tiff,application/octet-stream", forHTTPHeaderField: "Accept")
                let (received, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, received.count <= 128 * 1024 * 1024 else {
                    throw SurveyValidationError.invalid("建筑高度静态 COG 下载失败或超过 128 MB")
                }
                try received.write(to: file, options: .atomic); data = received; downloaded += 1
            }
            hashes.append(SurveyTerrainPlanner.sha256(data))
            rasters.append(try GeoTIFFTerrain.read(data, displayName: "GlobalBuildingAtlas x=\(tile.x) y=\(tile.y)"))
            await progress(index + 1, requests.count)
        }
        let terrain = try TiledTerrainElevationSource(tiles: rasters, displayName: "GlobalBuildingAtlas Height 静态 COG")
        _ = try roi.map { try terrain.elevationMeters(latitude: $0.latitude, longitude: $0.longitude) }
        return .init(terrain: terrain,
                     sha256: SurveyTerrainPlanner.sha256(Data(hashes.sorted().joined().utf8)),
                     downloadedTiles: downloaded, cachedTiles: cached)
    }
}
