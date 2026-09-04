import Foundation

/// Compile-time publication gates. Add either symbol to
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` to include that feature.
enum OpenFlyBuildFeatures {
#if OPENFLY_ENABLE_VLN
    static let vlnInference = true
#else
    static let vlnInference = false
#endif

#if OPENFLY_ENABLE_TERRAIN
    static let terrainFollowing = true
#else
    static let terrainFollowing = false
#endif
}

/// Release-safe inference placeholder. It prevents native model initialization
/// even if a non-UI caller accidentally reaches an inference action.
actor DisabledInferenceEngine: EmbeddedInferenceEngine {
    nonisolated let engineName = "未编译（发布版）"

    func load() async throws {
        throw FlightActionError.unavailable("当前发布版本未启用模型推理")
    }

    func infer(frame: CameraFrame, prompt: String, telemetry: FlightTelemetry,
               modelState: [Double]?) async throws -> InferenceResult {
        throw FlightActionError.unavailable("当前发布版本未启用模型推理")
    }

    func stop() async { }
    func reset() async { }
}
