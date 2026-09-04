import Foundation

/** Inert compatibility values retained for shared flight-state decoding in the public build. */
enum UAVFlowPolicyContract {
    static let horizon = 1
    static let defaultExecutedPrefix = 1
    static let defaultStopThreshold = 0.7

    static func shouldStop(_ score: Double, threshold: Double = defaultStopThreshold) -> Bool {
        score.isFinite && score >= threshold
    }
}
