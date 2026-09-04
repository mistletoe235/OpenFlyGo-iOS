import CoreGraphics
import Foundation
import ImageIO

struct WebMercatorTileID: Hashable, Codable {
    var zoom: Int; var x: Int; var y: Int
    var cacheName: String { "\(zoom)-\(x)-\(y).png" }
}

enum WebMercatorTileGrid {
    static let tileSize = 256
    static let maximumLatitude = 85.05112878

    static func tileIDs(for roi: [SurveyGeoPoint], zoom: Int, maximumTiles: Int = 64) throws -> [WebMercatorTileID] {
        guard roi.count >= 3 else { throw SurveyValidationError.invalid("请先绘制至少 3 个规划区边界点") }
        guard (0...15).contains(zoom) else { throw SurveyValidationError.invalid("地形瓦片层级无效") }
        let minLon = roi.map(\.longitude).min()!, maxLon = roi.map(\.longitude).max()!
        guard maxLon - minLon < 180 else { throw SurveyValidationError.invalid("暂不支持跨国际日期变更线的规划区") }
        let minLat = max(-maximumLatitude, roi.map(\.latitude).min()!)
        let maxLat = min(maximumLatitude, roi.map(\.latitude).max()!)
        let firstX = tileX(minLon, zoom), lastX = tileX(maxLon, zoom)
        let firstY = tileY(maxLat, zoom), lastY = tileY(minLat, zoom)
        let count = (lastX - firstX + 1) * (lastY - firstY + 1)
        guard (1...maximumTiles).contains(count) else {
            throw SurveyValidationError.invalid("全球地形下载需要 \(count) 个瓦片，超过上限 \(maximumTiles)；请缩小规划区")
        }
        return (firstY...lastY).flatMap { y in (firstX...lastX).map { .init(zoom: zoom, x: $0, y: y) } }
    }

    static func tileX(_ longitude: Double, _ zoom: Int) -> Int {
        let count = 1 << zoom
        let bounded = min(180 - 1e-12, max(-180, longitude))
        let raw = Int(floor((bounded + 180) / 360 * Double(count)))
        return min(count - 1, max(0, raw))
    }
    static func tileY(_ latitude: Double, _ zoom: Int) -> Int {
        let count = 1 << zoom
        let value = min(maximumLatitude, max(-maximumLatitude, latitude)) * .pi / 180
        let normalized = (1 - asinh(tan(value)) / Double.pi) / 2
        let raw = Int(floor(normalized * Double(count)))
        return min(count - 1, max(0, raw))
    }
    static func globalPixel(longitude: Double, latitude: Double, zoom: Int) -> (Double, Double) {
        let size = Double(tileSize * (1 << zoom))
        let lat = min(maximumLatitude, max(-maximumLatitude, latitude)) * .pi / 180
        return ((longitude + 180) / 360 * size, (1 - asinh(tan(lat)) / .pi) / 2 * size)
    }
    static func longitude(tileX: Int, zoom: Int) -> Double { Double(tileX) / Double(1 << zoom) * 360 - 180 }
    static func latitude(tileY: Int, zoom: Int) -> Double {
        atan(sinh(.pi * (1 - 2 * Double(tileY) / Double(1 << zoom)))) * 180 / .pi
    }
}

struct TerrariumTile {
    var id: WebMercatorTileID; var rgba: [UInt8]
    func elevation(x: Int, y: Int) -> Double {
        let offset = (y * WebMercatorTileGrid.tileSize + x) * 4
        return Double(rgba[offset]) * 256 + Double(rgba[offset + 1]) + Double(rgba[offset + 2]) / 256 - 32768
    }
}

struct TerrariumTerrain: TerrainElevationSource {
    let zoom: Int; let tiles: [WebMercatorTileID: TerrariumTile]; let info: TerrainRasterInfo
    private let minX: Int, maxX: Int, minY: Int, maxY: Int

    init(zoom: Int, tiles values: [TerrariumTile]) throws {
        guard !values.isEmpty, values.allSatisfy({ $0.id.zoom == zoom }) else {
            throw SurveyValidationError.invalid("没有地形瓦片或瓦片层级不一致")
        }
        self.zoom = zoom; tiles = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        minX = values.map(\.id.x).min()!; maxX = values.map(\.id.x).max()!
        minY = values.map(\.id.y).min()!; maxY = values.map(\.id.y).max()!
        let minLon = WebMercatorTileGrid.longitude(tileX: minX, zoom: zoom)
        let maxLon = WebMercatorTileGrid.longitude(tileX: maxX + 1, zoom: zoom)
        let maxLat = WebMercatorTileGrid.latitude(tileY: minY, zoom: zoom)
        let minLat = WebMercatorTileGrid.latitude(tileY: maxY + 1, zoom: zoom)
        let width = (maxX - minX + 1) * 256, height = (maxY - minY + 1) * 256
        info = .init(displayName: "全球裸地 DEM（Mapzen/AWS）", width: width, height: height,
                     epsg: 4326, noDataValue: nil, pixelSizeX: (maxLon - minLon) / Double(width),
                     pixelSizeY: (maxLat - minLat) / Double(height), minimumLatitude: minLat,
                     maximumLatitude: maxLat, minimumLongitude: minLon, maximumLongitude: maxLon)
    }

    func elevationMeters(latitude: Double, longitude: Double) throws -> Double {
        guard (info.minimumLatitude...info.maximumLatitude).contains(latitude),
              (info.minimumLongitude...info.maximumLongitude).contains(longitude) else {
            throw SurveyValidationError.invalid("坐标超出已下载全球地形范围")
        }
        let raw = WebMercatorTileGrid.globalPixel(longitude: min(longitude, info.maximumLongitude.nextDown),
                                                   latitude: max(latitude, info.minimumLatitude.nextUp), zoom: zoom)
        let x = min(Double((maxX + 1) * 256) - 1.000001, max(Double(minX * 256), raw.0))
        let y = min(Double((maxY + 1) * 256) - 1.000001, max(Double(minY * 256), raw.1))
        let x0 = Int(floor(x)), y0 = Int(floor(y)), tx = x - Double(x0), ty = y - Double(y0)
        let q00 = try sample(x0, y0), q10 = try sample(x0 + 1, y0)
        let q01 = try sample(x0, y0 + 1), q11 = try sample(x0 + 1, y0 + 1)
        return (q00 * (1 - tx) + q10 * tx) * (1 - ty) + (q01 * (1 - tx) + q11 * tx) * ty
    }

    private func sample(_ globalX: Int, _ globalY: Int) throws -> Double {
        let tileX = globalX / 256, tileY = globalY / 256
        guard let tile = tiles[.init(zoom: zoom, x: tileX, y: tileY)] else {
            throw SurveyValidationError.invalid("地形瓦片边缘缺失：\(zoom)/\(tileX)/\(tileY)")
        }
        return tile.elevation(x: globalX % 256, y: globalY % 256)
    }
}

struct GlobalTerrainDownloadResult {
    var terrain: TerrariumTerrain; var sha256: String; var downloadedTiles: Int; var cachedTiles: Int
}

actor GlobalTerrainDownloader {
    private let cacheRoot: URL
    init() throws {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        cacheRoot = root.appendingPathComponent("global-terrain/terrarium-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    func download(roi: [SurveyGeoPoint], zoom: Int = 14,
                  progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> GlobalTerrainDownloadResult {
        let ids = try WebMercatorTileGrid.tileIDs(for: roi, zoom: zoom)
        var tiles: [TerrariumTile] = [], digestInput = Data(), downloaded = 0, cached = 0
        for (index, id) in ids.enumerated() {
            let file = cacheRoot.appendingPathComponent(id.cacheName)
            let bytes: Data
            if let cachedData = try? Data(contentsOf: file), !cachedData.isEmpty {
                bytes = cachedData; cached += 1
            } else {
                let url = URL(string: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(id.zoom)/\(id.x)/\(id.y).png")!
                let (value, response) = try await URLSession.shared.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw SurveyValidationError.invalid("全球地形下载失败：\(id.zoom)/\(id.x)/\(id.y)")
                }
                try value.write(to: file, options: .atomic); bytes = value; downloaded += 1
            }
            digestInput.append(Data(id.cacheName.utf8)); digestInput.append(bytes)
            tiles.append(try decode(id, bytes)); await progress(index + 1, ids.count)
        }
        return .init(terrain: try TerrariumTerrain(zoom: zoom, tiles: tiles),
                     sha256: SurveyTerrainPlanner.sha256(digestInput),
                     downloadedTiles: downloaded, cachedTiles: cached)
    }

    private func decode(_ id: WebMercatorTileID, _ data: Data) throws -> TerrariumTile {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == 256, image.height == 256 else {
            throw SurveyValidationError.invalid("全球地形瓦片不是有效 256×256 PNG：\(id.cacheName)")
        }
        var rgba = [UInt8](repeating: 0, count: 256 * 256 * 4)
        guard let context = CGContext(data: &rgba, width: 256, height: 256, bitsPerComponent: 8,
                                      bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SurveyValidationError.invalid("无法解码地形瓦片")
        }
        context.translateBy(x: 0, y: 256); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: .init(x: 0, y: 0, width: 256, height: 256))
        return .init(id: id, rgba: rgba)
    }
}
