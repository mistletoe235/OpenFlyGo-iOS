import Foundation

/// Fail-closed GeoTIFF elevation reader for uncompressed single-band rasters.
/// Supports WGS84, Web Mercator and WGS84 UTM; rotated/sheared rasters are rejected.
struct GeoTIFFTerrain: TerrainElevationSource {
    let info: TerrainRasterInfo
    private let values: [Double]
    private let transform: GeoRasterTransform
    private let projection: any GeoProjection

    static func read(_ data: Data, displayName: String) throws -> GeoTIFFTerrain {
        let tiff = try ClassicTIFF(data)
        let width = try tiff.scalarInt(256), height = try tiff.scalarInt(257)
        guard width > 1, height > 1 else { throw SurveyValidationError.invalid("DSM 栅格尺寸无效") }
        guard (try tiff.scalarInt(259, default: 1)) == 1 else {
            throw SurveyValidationError.invalid("当前 iOS 安全读取器只接受未压缩 GeoTIFF；请导出 Compression=None")
        }
        guard (try tiff.scalarInt(277, default: 1)) == 1 else {
            throw SurveyValidationError.invalid("DSM 必须是单波段高程 GeoTIFF")
        }
        let bits = try tiff.scalarInt(258), sampleFormat = try tiff.scalarInt(339, default: 1)
        guard [8, 16, 32, 64].contains(bits) else { throw SurveyValidationError.invalid("DSM 位深不受支持") }
        let geoKeys = try tiff.unsignedValues(34735).map(Int.init)
        guard geoKeys.count >= 4 else { throw SurveyValidationError.invalid("GeoTIFF 缺少 GeoKeyDirectory") }
        var keys: [Int: Int] = [:]
        for index in 0..<geoKeys[3] {
            let offset = 4 + index * 4
            guard offset + 3 < geoKeys.count else { throw SurveyValidationError.invalid("GeoKeyDirectory 已截断") }
            if geoKeys[offset + 1] == 0, geoKeys[offset + 2] == 1 { keys[geoKeys[offset]] = geoKeys[offset + 3] }
        }
        guard let epsg = keys[3072] ?? keys[2048] else { throw SurveyValidationError.invalid("GeoTIFF 缺少 EPSG 坐标系") }
        let projection = try projectionForEPSG(epsg)
        let pixelIsArea = (keys[1025] ?? 1) == 1
        let transform = try GeoRasterTransform(tiff: tiff, pixelIsArea: pixelIsArea)
        let elevations = try tiff.raster(width: width, height: height, bits: bits, sampleFormat: sampleFormat)
        let noDataText = try tiff.ascii(42113)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 |"))
        let noData = noDataText.flatMap { Double($0) }
        let first = pixelIsArea ? -0.5 : 0
        let lastX = pixelIsArea ? Double(width) - 0.5 : Double(width - 1)
        let lastY = pixelIsArea ? Double(height) - 0.5 : Double(height - 1)
        let corners = [(first, first), (lastX, first), (first, lastY), (lastX, lastY)].map {
            let model = transform.pixelToModel(x: $0.0, y: $0.1)
            return projection.toWGS84(x: model.0, y: model.1)
        }
        return .init(info: .init(displayName: displayName, width: width, height: height, epsg: epsg,
            noDataValue: noData, pixelSizeX: transform.pixelSizeX, pixelSizeY: transform.pixelSizeY,
            minimumLatitude: corners.map(\.0).min()!, maximumLatitude: corners.map(\.0).max()!,
            minimumLongitude: corners.map(\.1).min()!, maximumLongitude: corners.map(\.1).max()!),
            values: elevations, transform: transform, projection: projection)
    }

    func elevationMeters(latitude: Double, longitude: Double) throws -> Double {
        guard latitude.isFinite, longitude.isFinite else { throw SurveyValidationError.invalid("DSM 查询坐标无效") }
        let model = projection.fromWGS84(latitude: latitude, longitude: longitude)
        let pixel = transform.modelToPixel(x: model.0, y: model.1)
        guard pixel.0 >= -0.5, pixel.0 <= Double(info.width) - 0.5,
              pixel.1 >= -0.5, pixel.1 <= Double(info.height) - 0.5 else {
            throw SurveyValidationError.invalid("坐标超出 DSM 覆盖范围")
        }
        let x = min(Double(info.width - 1), max(0, pixel.0)), y = min(Double(info.height - 1), max(0, pixel.1))
        let x0 = Int(floor(x)), y0 = Int(floor(y)), x1 = min(x0 + 1, info.width - 1), y1 = min(y0 + 1, info.height - 1)
        func sample(_ column: Int, _ row: Int) throws -> Double {
            let value = values[row * info.width + column]
            let missing = !value.isFinite || info.noDataValue.map {
                $0.isNaN ? value.isNaN : abs(value - $0) <= max(1, abs($0)) * 1e-9
            } == true
            guard !missing else { throw SurveyValidationError.invalid("DSM 在目标位置包含 NoData") }
            return value
        }
        let q00 = try sample(x0, y0), q10 = try sample(x1, y0), q01 = try sample(x0, y1), q11 = try sample(x1, y1)
        let tx = x - Double(x0), ty = y - Double(y0)
        return (q00 * (1 - tx) + q10 * tx) * (1 - ty) + (q01 * (1 - tx) + q11 * tx) * ty
    }
}

private struct GeoRasterTransform {
    var originPixelX: Double, originPixelY: Double, originModelX: Double, originModelY: Double
    var pixelSizeX: Double, pixelSizeY: Double, pixelCenterOffset: Double

    init(tiff: ClassicTIFF, pixelIsArea: Bool) throws {
        pixelCenterOffset = pixelIsArea ? 0.5 : 0
        if let matrix = try tiff.optionalDoubles(34264) {
            guard matrix.count == 16, matrix[0] > 0, matrix[5] < 0,
                  [1, 2, 4, 6, 8, 9, 11, 12, 13, 14].allSatisfy({ abs(matrix[$0]) <= 1e-12 }),
                  abs(matrix[15] - 1) <= 1e-12 else {
                throw SurveyValidationError.invalid("暂不支持旋转/剪切 GeoTIFF；请导出 north-up DSM")
            }
            originPixelX = 0; originPixelY = 0; originModelX = matrix[3]; originModelY = matrix[7]
            pixelSizeX = matrix[0]; pixelSizeY = -matrix[5]
        } else {
            let scale = try tiff.doubles(33550), tie = try tiff.doubles(33922)
            guard scale.count >= 2, tie.count >= 6, scale[0] > 0, scale[1] > 0 else {
                throw SurveyValidationError.invalid("GeoTIFF 缺少像元比例或控制点")
            }
            originPixelX = tie[0]; originPixelY = tie[1]; originModelX = tie[3]; originModelY = tie[4]
            pixelSizeX = scale[0]; pixelSizeY = scale[1]
        }
    }
    func pixelToModel(x: Double, y: Double) -> (Double, Double) {
        (originModelX + (x + pixelCenterOffset - originPixelX) * pixelSizeX,
         originModelY - (y + pixelCenterOffset - originPixelY) * pixelSizeY)
    }
    func modelToPixel(x: Double, y: Double) -> (Double, Double) {
        (originPixelX + (x - originModelX) / pixelSizeX - pixelCenterOffset,
         originPixelY + (originModelY - y) / pixelSizeY - pixelCenterOffset)
    }
}

private protocol GeoProjection {
    func fromWGS84(latitude: Double, longitude: Double) -> (Double, Double)
    func toWGS84(x: Double, y: Double) -> (Double, Double)
}
private func projectionForEPSG(_ epsg: Int) throws -> any GeoProjection {
    switch epsg {
    case 4326: return GeographicProjection()
    case 3857: return WebMercatorProjection()
    case 32601...32660: return UTMProjection(zone: epsg - 32600, south: false)
    case 32701...32760: return UTMProjection(zone: epsg - 32700, south: true)
    default: throw SurveyValidationError.invalid("暂不支持 EPSG:\(epsg)；支持 4326、3857、WGS84 UTM 326xx/327xx")
    }
}
private struct GeographicProjection: GeoProjection {
    func fromWGS84(latitude: Double, longitude: Double) -> (Double, Double) { (longitude, latitude) }
    func toWGS84(x: Double, y: Double) -> (Double, Double) { (y, x) }
}
private struct WebMercatorProjection: GeoProjection {
    let radius = 6_378_137.0
    func fromWGS84(latitude: Double, longitude: Double) -> (Double, Double) {
        (longitude * .pi / 180 * radius, log(tan(.pi / 4 + min(85.05112878, max(-85.05112878, latitude)) * .pi / 360)) * radius)
    }
    func toWGS84(x: Double, y: Double) -> (Double, Double) {
        ((2 * atan(exp(y / radius)) - .pi / 2) * 180 / .pi, x / radius * 180 / .pi)
    }
}
private struct UTMProjection: GeoProjection {
    let zone: Int, south: Bool
    let a = 6_378_137.0, e2 = 0.0066943799901413165, k0 = 0.9996
    var ep2: Double { e2 / (1 - e2) }; var lon0: Double { Double(zone * 6 - 183) * .pi / 180 }
    func fromWGS84(latitude: Double, longitude: Double) -> (Double, Double) {
        let lat = latitude * .pi / 180, lon = longitude * .pi / 180
        let n = a / sqrt(1 - e2 * pow(sin(lat), 2)), t = pow(tan(lat), 2), c = ep2 * pow(cos(lat), 2)
        let aa = cos(lat) * (lon - lon0), m = meridional(lat)
        let x = 500_000 + k0 * n * (aa + (1 - t + c) * pow(aa, 3) / 6 + (5 - 18*t + t*t + 72*c - 58*ep2) * pow(aa, 5) / 120)
        var y = k0 * (m + n * tan(lat) * (aa*aa/2 + (5-t+9*c+4*c*c)*pow(aa,4)/24 + (61-58*t+t*t+600*c-330*ep2)*pow(aa,6)/720))
        if south { y += 10_000_000 }; return (x, y)
    }
    func toWGS84(x: Double, y: Double) -> (Double, Double) {
        let xx = x - 500_000, yy = south ? y - 10_000_000 : y, m = yy / k0
        let mu = m / (a * (1-e2/4-3*pow(e2,2)/64-5*pow(e2,3)/256)), e1 = (1-sqrt(1-e2))/(1+sqrt(1-e2))
        let fp = mu + (3*e1/2-27*pow(e1,3)/32)*sin(2*mu) + (21*e1*e1/16-55*pow(e1,4)/32)*sin(4*mu) + 151*pow(e1,3)/96*sin(6*mu) + 1097*pow(e1,4)/512*sin(8*mu)
        let c1=ep2*pow(cos(fp),2), t1=pow(tan(fp),2), n1=a/sqrt(1-e2*pow(sin(fp),2)), r1=a*(1-e2)/pow(1-e2*pow(sin(fp),2),1.5), d=xx/(n1*k0)
        let lat=fp-n1*tan(fp)/r1*(d*d/2-(5+3*t1+10*c1-4*c1*c1-9*ep2)*pow(d,4)/24+(61+90*t1+298*c1+45*t1*t1-252*ep2-3*c1*c1)*pow(d,6)/720)
        let lon=lon0+(d-(1+2*t1+c1)*pow(d,3)/6+(5-2*c1+28*t1-3*c1*c1+8*ep2+24*t1*t1)*pow(d,5)/120)/cos(fp)
        return (lat * 180 / Double.pi, lon * 180 / Double.pi)
    }
    private func meridional(_ lat: Double) -> Double { a*((1-e2/4-3*pow(e2,2)/64-5*pow(e2,3)/256)*lat-(3*e2/8+3*pow(e2,2)/32+45*pow(e2,3)/1024)*sin(2*lat)+(15*pow(e2,2)/256+45*pow(e2,3)/1024)*sin(4*lat)-35*pow(e2,3)/3072*sin(6*lat)) }
}

private struct ClassicTIFF {
    struct Entry { var type: Int; var count: Int; var valueOffset: Int; var inlineBytes: Data }
    let data: Data, littleEndian: Bool, entries: [Int: Entry]
    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 8 else { throw SurveyValidationError.invalid("TIFF 文件已截断") }
        let marker = String(data: data.prefix(2), encoding: .ascii)
        guard marker == "II" || marker == "MM" else { throw SurveyValidationError.invalid("TIFF 字节序无效") }
        let isLittle = marker == "II"
        littleEndian = isLittle
        func u16(_ at: Int) -> UInt16 { ClassicTIFF.read(data, at, little: isLittle) }
        func u32(_ at: Int) -> UInt32 { ClassicTIFF.read(data, at, little: isLittle) }
        guard u16(2) == 42 else { throw SurveyValidationError.invalid("只支持 Classic TIFF（非 BigTIFF）") }
        let ifd = Int(u32(4)); guard ifd + 2 <= data.count else { throw SurveyValidationError.invalid("TIFF IFD 无效") }
        let count = Int(u16(ifd)); var result: [Int: Entry] = [:]
        for index in 0..<count {
            let offset = ifd + 2 + index * 12; guard offset + 12 <= data.count else { throw SurveyValidationError.invalid("TIFF IFD 已截断") }
            let type = Int(u16(offset + 2)), n = Int(u32(offset + 4)), value = Int(u32(offset + 8))
            result[Int(u16(offset))] = .init(type: type, count: n, valueOffset: value,
                                             inlineBytes: data.subdata(in: offset+8..<offset+12))
        }
        entries = result
    }
    func scalarInt(_ tag: Int, default fallback: Int? = nil) throws -> Int {
        if entries[tag] == nil, let fallback { return fallback }
        guard let first = try unsignedValues(tag).first else { throw SurveyValidationError.invalid("TIFF 缺少 tag \(tag)") }
        return Int(first)
    }
    func unsignedValues(_ tag: Int) throws -> [UInt64] {
        guard let entry = entries[tag] else { throw SurveyValidationError.invalid("TIFF 缺少 tag \(tag)") }
        let bytes = try raw(entry); let size = typeSize(entry.type)
        return (0..<entry.count).map { index in
            let offset = index * size
            switch entry.type { case 1, 2, 6, 7: return UInt64(bytes[offset]); case 3: return UInt64(ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt16); default: return UInt64(ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt32) }
        }
    }
    func doubles(_ tag: Int) throws -> [Double] { guard let value = try optionalDoubles(tag) else { throw SurveyValidationError.invalid("TIFF 缺少 tag \(tag)") }; return value }
    func optionalDoubles(_ tag: Int) throws -> [Double]? {
        guard let entry = entries[tag] else { return nil }; let bytes = try raw(entry), size = typeSize(entry.type)
        return (0..<entry.count).map { index in
            let offset = index * size
            switch entry.type {
            case 3: return Double(ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt16)
            case 4: return Double(ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt32)
            case 11: return Double(Float(bitPattern: ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt32))
            case 12: return Double(bitPattern: ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt64)
            default: return .nan
            }
        }
    }
    func ascii(_ tag: Int) throws -> String? { guard let entry = entries[tag] else { return nil }; return String(data: try raw(entry), encoding: .ascii) }
    func raster(width: Int, height: Int, bits: Int, sampleFormat: Int) throws -> [Double] {
        let bytesPer = bits / 8
        func decode(_ bytes: Data, count: Int) -> [Double] {
            (0..<count).map { index in
                let offset = index * bytesPer
                if sampleFormat == 3 { return bits == 32 ? Double(Float(bitPattern: ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt32)) : Double(bitPattern: ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt64) }
                if sampleFormat == 2 { return bits == 16 ? Double(Int16(bitPattern: ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt16)) : Double(Int32(bitPattern: ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt32)) }
                if bits == 8 { return Double(bytes[offset]) }; if bits == 16 { return Double(ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt16) }
                return Double(ClassicTIFF.read(bytes, offset, little: littleEndian) as UInt32)
            }
        }
        if entries[324] != nil {
            let offsets = try unsignedValues(324).map(Int.init), counts = try unsignedValues(325).map(Int.init)
            let tileWidth = try scalarInt(322), tileHeight = try scalarInt(323), across = Int(ceil(Double(width)/Double(tileWidth)))
            var result = [Double](repeating: .nan, count: width*height)
            for tileIndex in offsets.indices {
                let tile = decode(try slice(offsets[tileIndex], counts[tileIndex]), count: tileWidth*tileHeight)
                let tileX = tileIndex % across, tileY = tileIndex / across
                for y in 0..<tileHeight where tileY*tileHeight+y < height { for x in 0..<tileWidth where tileX*tileWidth+x < width { result[(tileY*tileHeight+y)*width+tileX*tileWidth+x] = tile[y*tileWidth+x] } }
            }
            return result
        }
        let offsets = try unsignedValues(273).map(Int.init), counts = try unsignedValues(279).map(Int.init), rows = try scalarInt(278, default: height)
        var result: [Double] = []
        for index in offsets.indices { result += decode(try slice(offsets[index], counts[index]), count: min(rows, height-index*rows)*width) }
        guard result.count >= width*height else { throw SurveyValidationError.invalid("TIFF 像素数据已截断") }; return Array(result.prefix(width*height))
    }
    private func raw(_ entry: Entry) throws -> Data { let size = typeSize(entry.type)*entry.count; return size <= 4 ? entry.inlineBytes.prefix(size) : try slice(entry.valueOffset,size) }
    private func slice(_ offset: Int, _ count: Int) throws -> Data { guard offset >= 0, count >= 0, offset+count <= data.count else { throw SurveyValidationError.invalid("TIFF 数据偏移无效") }; return data.subdata(in: offset..<offset+count) }
    private func typeSize(_ type: Int) -> Int { [3:2,4:4,5:8,8:2,9:4,10:8,11:4,12:8][type] ?? 1 }
    private static func read<T: FixedWidthInteger>(_ data: Data, _ offset: Int, little: Bool) -> T { let value = data.subdata(in: offset..<offset+MemoryLayout<T>.size).withUnsafeBytes { $0.loadUnaligned(as:T.self) }; return little ? T(littleEndian:value) : T(bigEndian:value) }
}
