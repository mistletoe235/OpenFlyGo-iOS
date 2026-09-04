import Foundation

struct ModelArtifact: Hashable {
    let role: String
}

struct ModelPackManifest: Hashable {
    let packID: String
    let version: String
    let artifacts: [ModelArtifact]
}

struct InstalledModelPack: Hashable {
    let manifest: ModelPackManifest
    let directory: URL
}

final class ModelPackStore: @unchecked Sendable {
    func importPack(from url: URL) async throws -> InstalledModelPack {
        throw CloudUAVFlowInstallError.unavailable
    }

    func activate(_ pack: InstalledModelPack) throws {
        throw CloudUAVFlowInstallError.unavailable
    }
}
