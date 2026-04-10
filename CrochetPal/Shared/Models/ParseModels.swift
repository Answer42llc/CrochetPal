import Foundation

struct PatternOutlineResponse: Codable, Hashable {
    var projectTitle: String
    var materials: [String]
    var confidence: Double
    var parts: [OutlinedPatternPart]
}

struct OutlinedPatternPart: Codable, Hashable {
    var name: String
    var rounds: [OutlinedPatternRound]
}

struct OutlinedPatternRound: Codable, Hashable {
    var title: String
    var rawInstruction: String
    var summary: String
    var targetStitchCount: Int?
}

struct PatternParseResponse: Codable, Hashable {
    var projectTitle: String
    var materials: [String]
    var confidence: Double
    var parts: [ParsedPatternPart]
}

struct ParsedPatternPart: Codable, Hashable {
    var name: String
    var rounds: [ParsedPatternRound]
}

struct ParsedPatternRound: Codable, Hashable {
    var title: String
    var rawInstruction: String
    var summary: String
    var targetStitchCount: Int?
    var atomicActions: [ParsedAtomicAction]
}

struct ParsedAtomicAction: Codable, Hashable {
    var type: StitchActionType
    var instruction: String
    var producedStitches: Int?
    var note: String? = nil
}

struct RoundAtomizationResponse: Codable, Hashable {
    var rounds: [AtomizedPatternRound]
}

struct AtomizedPatternRound: Codable, Hashable {
    var actionGroups: [ParsedActionGroup]
}

struct ParsedActionGroup: Codable, Hashable {
    var type: StitchActionType
    var count: Int
    var instruction: String?
    var producedStitches: Int?
    var note: String? = nil
}

struct AtomizationRoundInput: Codable, Hashable {
    var partName: String
    var title: String
    var rawInstruction: String
    var targetStitchCount: Int?
}

struct ParseRequestContext: Codable, Hashable {
    var traceID: String
    var parseRequestID: String
    var sourceType: PatternSourceType
}

struct ExtractionDecision: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var index: Int
    var preview: String
    var score: Double
    var keep: Bool
    var reasons: [String]
}

struct WebExtractionResult: Codable, Hashable {
    var title: String?
    var keptBlocks: [String]
    var decisions: [ExtractionDecision]
    var finalText: String
    var fallbackUsed: Bool
    var rawHTMLLength: Int
    var reducedHTMLLength: Int
}

enum PatternImportFailure: Error, LocalizedError {
    case invalidURL
    case fetchFailed(statusCode: Int)
    case emptyExtraction
    case invalidResponse(String)
    case inconsistentRound(String)
    case atomizationFailed(String)
    case missingConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无法识别这个网页地址。"
        case let .fetchFailed(statusCode):
            return "网页抓取失败，状态码 \(statusCode)。"
        case .emptyExtraction:
            return "没有提取到可解析的 pattern 内容。"
        case let .invalidResponse(message):
            return "模型返回的数据无效：\(message)"
        case let .inconsistentRound(message):
            return "轮次解析结果不一致：\(message)"
        case let .atomizationFailed(message):
            return "步骤解析失败：\(message)"
        case let .missingConfiguration(key):
            return "缺少配置项：\(key)"
        }
    }
}
