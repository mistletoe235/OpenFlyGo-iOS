import Foundation

struct PromptPreset: Identifiable, Equatable, Sendable {
    let id: String
    let instruction: String
}

enum PromptPresetCatalog {
    private struct Document: Decodable {
        let items: [Item]
    }

    private struct Item: Decodable {
        let sampleIndex: Int?
        let label: String?
        let instruction: String

        enum CodingKeys: String, CodingKey {
            case sampleIndex = "sample_idx"
            case label
            case instruction
        }
    }

    static let fallback = [PromptPreset(id: "DISABLED", instruction: "Inference is not included")]

    static func load(bundle: Bundle = .main) -> [PromptPreset] {
        fallback
    }

    static func decode(_ data: Data) throws -> [PromptPreset] {
        let document = try JSONDecoder().decode(Document.self, from: data)
        var identifiers = Set<String>()
        return try document.items.enumerated().map { index, item in
            let instruction = item.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferredID = item.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let identifier = preferredID.isEmpty
                ? String(format: "%03d", item.sampleIndex ?? index)
                : preferredID
            guard !instruction.isEmpty, identifiers.insert(identifier).inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return PromptPreset(id: identifier, instruction: instruction)
        }
    }
}
