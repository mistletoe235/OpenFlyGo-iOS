import Foundation

enum CloudUAVFlowInstallError: LocalizedError {
    case unavailable
    case importedPackMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "On-device model distribution is not included in this public release"
        case .importedPackMismatch:
            return "The selected model pack is not supported by this public release"
        }
    }
}

actor CloudUAVFlowModelInstaller {
    static let targetPackID = "not-included"

    func installLatest(
        progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> InstalledModelPack {
        progress("Not included", nil)
        throw CloudUAVFlowInstallError.unavailable
    }
}
