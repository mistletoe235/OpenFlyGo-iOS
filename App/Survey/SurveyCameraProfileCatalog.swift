import Foundation

enum SurveyCameraProfileCatalog {
    struct Resolution: Equatable {
        var profile: SurveyCameraProfile
        var displayName: String
        var officialSourceURL: URL?
        var verifiedProfile: Bool
    }

    private struct Entry {
        var aliases: [String]
        var resolution: Resolution
    }

    private static let entries: [Entry] = [
        entry(["M4E"], "DJI Matrice 4E 广角", "dji-matrice-4e-wide-20mp", 5280, 3956, 84, 0.5, "https://enterprise.dji.com/matrice-4-series/specs"),
        entry(["M4T"], "DJI Matrice 4T 广角", "dji-matrice-4t-wide-48mp", 8064, 6048, 82, 0.7, "https://enterprise.dji.com/matrice-4-series/specs"),
        entry(["M3E"], "DJI Mavic 3E 广角", "dji-mavic-3e-wide-20mp", 5280, 3956, 84, 0.7, "https://enterprise.dji.com/mavic-3-enterprise/specs"),
        entry(["M3T", "M3TA"], "DJI Mavic 3T/3TA 广角", "dji-mavic-3t-wide-12mp", 4000, 3000, 84, 2, "https://enterprise.dji.com/mavic-3-enterprise/specs"),
        entry(["M3M"], "DJI Mavic 3M RGB", "dji-mavic-3m-rgb-20mp", 5280, 3956, 84, 0.7, "https://enterprise.dji.com/mavic-3-m/specs"),
        entry(["M30", "M30T", "M30SERIES"], "DJI Matrice 30 系列广角", "dji-matrice-30-wide-12mp", 4000, 3000, 84, 2, "https://enterprise.dji.com/matrice-30/specs"),
        entry(["DJIMINI4PRO"], "DJI Mini 4 Pro 12MP", "dji-mini-4-pro-photo-12mp", 4032, 3024, 82.1, 2, "https://www.dji.com/mini-4-pro/specs"),
        entry(["DJIMINI3PRO"], "DJI Mini 3 Pro 12MP", "dji-mini-3-pro-photo-12mp", 4032, 3024, 82.1, 2, "https://www.dji.com/support/product/mini-3-pro"),
        entry(["DJIMINI3"], "DJI Mini 3 12MP", "dji-mini-3-photo-12mp", 4032, 3024, 82.1, 2, "https://www.dji.com/mini-3/specs"),
        entry(["DJIAIR2S", "MAVICAIR2S"], "DJI Air 2S 20MP", "dji-air-2s-photo-20mp", 5472, 3648, 88, 2, "https://www.dji.com/support/product/air-2s"),
        entry(["MAVIC2PRO"], "DJI Mavic 2 Pro", "dji-mavic-2-pro-photo-20mp", 5472, 3648, 77, 2, "https://www.dji.com/mavic-2/info"),
        entry(["MAVIC2ZOOM"], "DJI Mavic 2 Zoom 广角端", "dji-mavic-2-zoom-wide-photo-12mp", 4000, 3000, 83, 2, "https://www.dji.com/mavic-2/info"),
        entry(["PHANTOM4PRO", "PHANTOM4ADVANCED", "P4PV2CAMERA"], "DJI Phantom 4 Pro/Advanced", "dji-phantom-4-pro-photo-20mp", 5472, 3648, 84, 2, "https://www.dji.com/support/product/phantom-4-pro-v2"),
        entry(["MAVICAIR2"], "DJI Mavic Air 2 12MP", "dji-mavic-air-2-photo-12mp", 4000, 3000, 84, 2, "https://www.dji.com/uk/mavic-air-2/specs"),
        entry(["DJIMINI2", "MAVICMINI2", "DJIMINISE", "MAVICMINI"], "DJI Mini 系列 12MP", "dji-mini-2-photo-4x3", 4000, 3000, 83, 2, "https://www.dji.com/support/product/mini-2"),
    ]

    static func resolve(_ identities: String?...) -> Resolution {
        let values = identities.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !sentinels.contains(normalize($0)) }
        let joined = values.map(normalize).joined(separator: " ")
        if let match = entries.first(where: { $0.aliases.contains(where: joined.contains) }) {
            return match.resolution
        }
        return .init(profile: .generic4By3,
                     displayName: values.isEmpty ? "未识别相机" : values.joined(separator: " / "),
                     officialSourceURL: nil, verifiedProfile: false)
    }

    static var allVerified: [Resolution] { entries.map(\.resolution) }

    private static func entry(_ aliases: [String], _ name: String, _ id: String,
                              _ width: Int, _ height: Int, _ diagonalFOV: Double,
                              _ interval: Double, _ source: String) -> Entry {
        let diagonalTangent = tan(diagonalFOV * .pi / 360)
        let aspect = Double(width) / Double(height)
        let verticalHalf = atan(diagonalTangent / sqrt(aspect * aspect + 1))
        let horizontalHalf = atan(aspect * tan(verticalHalf))
        return .init(aliases: aliases.map(normalize), resolution: .init(
            profile: .init(id: id, imageWidthPixels: width, imageHeightPixels: height,
                           horizontalFieldOfViewDegrees: horizontalHalf * 360 / .pi,
                           verticalFieldOfViewDegrees: verticalHalf * 360 / .pi,
                           minimumCaptureIntervalSeconds: interval),
            displayName: name, officialSourceURL: URL(string: source), verifiedProfile: true))
    }

    private static func normalize(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }
    private static let sentinels: Set<String> = ["UNKNOWN", "NOTSUPPORTED", "NONE", "DEFAULT", "OTHER"]
}
