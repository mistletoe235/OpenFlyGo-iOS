import Foundation
import SceneKit

struct SurveyCloudPointCloud {
    let positions: [SIMD3<Float>]
    let colors: Data
    let sourceCount: Int
}

enum SurveyCloudPLY {
    private struct Property { let name: String; let type: String; let offset: Int }
    private static let sizes = ["char": 1, "uchar": 1, "int8": 1, "uint8": 1, "short": 2, "ushort": 2,
                                "int16": 2, "uint16": 2, "int": 4, "uint": 4, "int32": 4, "uint32": 4,
                                "float": 4, "float32": 4, "double": 8, "float64": 8]

    static func decode(_ data: Data, maximumPoints: Int = 50_000) throws -> SurveyCloudPointCloud {
        guard maximumPoints > 0, maximumPoints <= 50_000, data.count <= 32 * 1_048_576,
              let marker = data.prefix(65_536).range(of: Data("end_header".utf8)),
              let newline = data[marker.upperBound...].firstIndex(of: 10), newline < 65_536,
              let header = String(data: data[..<marker.lowerBound], encoding: .ascii) else {
            throw SurveyCloudError.invalid("点云不是有效的 PLY 文件，或头部/文件过大")
        }
        var format = ""
        var count = 0
        var stride = 0
        var inVertices = false
        var properties: [Property] = []
        var elements: [String] = []
        let lines = header.split(whereSeparator: \.isNewline)
        guard lines.first == "ply" else { throw SurveyCloudError.invalid("缺少 PLY 文件标识") }
        for line in lines.dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let kind = fields.first else { continue }
            if kind == "format", fields.count == 3, fields[2] == "1.0" { format = fields[1] }
            if kind == "element", fields.count == 3 {
                elements.append(fields[1])
                inVertices = fields[1] == "vertex"
                if inVertices { count = Int(fields[2]) ?? 0 }
            }
            if kind == "property", inVertices {
                guard fields.count == 3, let size = sizes[fields[1]], !properties.contains(where: { $0.name == fields[2] }) else {
                    throw SurveyCloudError.invalid("PLY 顶点属性不支持或重复")
                }
                properties.append(Property(name: fields[2], type: fields[1], offset: stride))
                stride += size
            }
        }
        guard elements.first == "vertex", elements.filter({ $0 == "vertex" }).count == 1,
              count > 0, count <= 5_000_000, stride > 0, stride <= 512,
              ["ascii", "binary_little_endian"].contains(format),
              let xIndex = properties.firstIndex(where: { $0.name == "x" }),
              let yIndex = properties.firstIndex(where: { $0.name == "y" }),
              let zIndex = properties.firstIndex(where: { $0.name == "z" }) else {
            throw SurveyCloudError.invalid("仅支持顶点在前、带 XYZ 的 ASCII / little-endian PLY（最多500万原始点）")
        }
        let body = newline + 1
        let sampleStride = max(1, (count + maximumPoints - 1) / maximumPoints)
        let colorIndices = ["red", "green", "blue"].map { name in properties.firstIndex { $0.name == name } }
        var positions: [SIMD3<Float>] = []
        var colors = Data()
        func append(_ values: [Double]) {
            let position = SIMD3(Float(values[xIndex]), Float(values[yIndex]), Float(values[zIndex]))
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
            positions.append(position)
            for index in colorIndices {
                let value = index.map { values[$0] } ?? 200
                colors.append(UInt8(value.isFinite ? max(0, min(255, value)) : 200))
            }
            colors.append(255)
        }
        if format == "ascii" {
            guard let text = String(data: data[body...], encoding: .utf8) else {
                throw SurveyCloudError.invalid("ASCII PLY 含无效字符")
            }
            var row = 0
            var malformed = false
            text.enumerateLines { line, stop in
                if row >= count { stop = true; return }
                defer { row += 1 }
                if row % sampleStride != 0 { return }
                let fields = line.split(whereSeparator: \.isWhitespace)
                let values = fields.compactMap { Double($0) }
                guard values.count == properties.count, fields.count == properties.count else {
                    malformed = true; stop = true; return
                }
                append(values)
            }
            guard row == count, !malformed else { throw SurveyCloudError.invalid("PLY 顶点数据截断或格式错误") }
        } else {
            guard data.count - body >= count * stride else { throw SurveyCloudError.invalid("二进制 PLY 顶点数据截断") }
            data.withUnsafeBytes { buffer in
                let bytes = buffer.bindMemory(to: UInt8.self)
                for row in Swift.stride(from: 0, to: count, by: sampleStride) {
                    let values = properties.map { property -> Double in
                        let offset = body + row * stride + property.offset
                        let size = sizes[property.type]!
                        var bits: UInt64 = 0
                        for byte in 0..<size { bits |= UInt64(bytes[offset + byte]) << (8 * byte) }
                        switch property.type {
                        case "float", "float32": return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
                        case "double", "float64": return Double(bitPattern: bits)
                        case "char", "int8": return Double(Int8(bitPattern: UInt8(truncatingIfNeeded: bits)))
                        case "short", "int16": return Double(Int16(bitPattern: UInt16(truncatingIfNeeded: bits)))
                        case "int", "int32": return Double(Int32(bitPattern: UInt32(truncatingIfNeeded: bits)))
                        default: return Double(bits)
                        }
                    }
                    append(values)
                }
            }
        }
        guard !positions.isEmpty else { throw SurveyCloudError.invalid("点云没有有效 XYZ 点") }
        return SurveyCloudPointCloud(positions: positions, colors: colors, sourceCount: count)
    }

    static func scene(_ cloud: SurveyCloudPointCloud) -> SCNScene {
        var minimum = cloud.positions[0], maximum = minimum
        for point in cloud.positions {
            minimum = SIMD3(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
            maximum = SIMD3(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
        }
        let center = minimum * 0.5 + maximum * 0.5
        let extent = max(0.01, max(maximum.x / 2 - minimum.x / 2,
                                  max(maximum.y / 2 - minimum.y / 2, maximum.z / 2 - minimum.z / 2)))
        let vertices = cloud.positions.map { point -> SCNVector3 in
            let local = (point / 2 - center / 2) / extent * 2
            return SCNVector3(local.x, local.z, -local.y)
        }
        let indices = (0..<vertices.count).map(UInt32.init)
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 3
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 4
        let colors = SCNGeometrySource(data: cloud.colors, semantic: .color, vectorCount: vertices.count,
                                      usesFloatComponents: false, componentsPerVector: 4,
                                      bytesPerComponent: 1, dataOffset: 0, dataStride: 4)
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), colors], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        geometry.materials = [material]
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.position = SCNVector3(0, 1.2, 3.5)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)
        return scene
    }
}
