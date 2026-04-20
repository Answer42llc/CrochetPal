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
    /// For macro-repeat instructions (e.g. "Repeat Rows 6-13 until 118 rows"):
    /// title of the first round in the repeating cycle.
    var repeatFromTitle: String?
    /// Title of the last round in the repeating cycle.
    var repeatToTitle: String?
    /// Target total round/row count the pattern wants to reach.
    var repeatUntilCount: Int?
    /// The row/round number of the last numbered row before this repeat instruction.
    /// E.g. if rows 1-13 precede "Repeat Rows 6-13 until 118", set to 13.
    var repeatAfterRow: Int?
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

enum ControlSegmentKind: String, Codable, CaseIterable, Hashable {
    case turn
    case skip
    case custom
}

enum AtomizedNotePlacement: String, Codable, CaseIterable, Hashable {
    case first
    case last
    case all
}

struct AtomizationRoundInput: Codable, Hashable {
    var partName: String
    var title: String
    var rawInstruction: String
    var summary: String
    var targetStitchCount: Int?
    var previousRoundStitchCount: Int?
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
    case fetchFailed(statusCode: Int, details: String?)
    case emptyExtraction
    case invalidResponse(String)
    case inconsistentRound(String)
    case atomizationFailed(String)
    case missingConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无法识别这个网页地址。"
        case let .fetchFailed(statusCode, details):
            let normalizedDetails = details?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedDetails, !normalizedDetails.isEmpty {
                return "请求失败，状态码 \(statusCode)：\(normalizedDetails)"
            }
            return "请求失败，状态码 \(statusCode)。"
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
