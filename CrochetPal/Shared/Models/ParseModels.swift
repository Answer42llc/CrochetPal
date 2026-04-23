import Foundation

struct PatternOutlineResponse: Codable, Hashable {
    var projectTitle: String
    var materials: [String]
    var confidence: Double
    /// Author-defined abbreviations extracted from the pattern. Used to teach the IR
    /// atomization LLM about non-standard terminology (e.g. `cs = cap stitch`).
    var abbreviations: [PatternAbbreviation]
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
    /// For range expansion instructions (e.g. "Rows 2-109: Ch 1, sc in first 3 sts..."):
    /// the start number of the range (e.g. 2). Must be paired with `rangeEndNumber`.
    /// Mutually exclusive with the `repeat*` fields.
    var rangeStartNumber: Int?
    /// The end number of the range (e.g. 109). Must be paired with `rangeStartNumber`.
    var rangeEndNumber: Int?
}

struct PatternParseResponse: Codable, Hashable {
    var projectTitle: String
    var materials: [String]
    var confidence: Double
    var abbreviations: [PatternAbbreviation]
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

/// Atomic action emitted by image-parsing (full-parse) path. Mirrors the IR operation
/// shape closely but is flatter since image parsing doesn't need a full AST.
struct ParsedAtomicAction: Codable, Hashable {
    var semantics: CrochetIROperationSemantics
    var actionTag: String
    var stitchTag: String?
    var instruction: String
    var producedStitches: Int?
    var note: String? = nil
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
    /// Pattern-level abbreviations forwarded from the outline stage so the IR LLM can
    /// honor author-defined terminology (e.g. `cs = cap stitch`).
    var abbreviations: [PatternAbbreviation]
}

struct AtomizationEvaluationActionInput: Codable, Hashable {
    var semantics: CrochetIROperationSemantics
    var actionTag: String
    var stitchTag: String?
    var instruction: String?
    var producedStitches: Int
    var note: String?
    var sequenceIndex: Int

    init(
        semantics: CrochetIROperationSemantics,
        actionTag: String,
        stitchTag: String?,
        instruction: String?,
        producedStitches: Int,
        note: String?,
        sequenceIndex: Int
    ) {
        self.semantics = semantics
        self.actionTag = actionTag
        self.stitchTag = stitchTag
        self.instruction = instruction
        self.producedStitches = producedStitches
        self.note = note
        self.sequenceIndex = sequenceIndex
    }

    init(action: AtomicAction) {
        self.semantics = action.semantics
        self.actionTag = action.actionTag
        self.stitchTag = action.stitchTag
        self.instruction = action.instruction
        self.producedStitches = action.producedStitches
        self.note = action.note
        self.sequenceIndex = action.sequenceIndex
    }
}

struct AtomizationMatchEvaluationInput: Codable, Hashable {
    var roundTitle: String
    var rawInstruction: String
    var roundSummary: String
    var targetStitchCount: Int?
    var irSourceText: String
    var expectedProducedStitches: Int?
    var validationIssues: [CrochetIRValidationIssue]
    var expansionFailure: String?
    var producedStitchCount: Int?
    var warnings: [CrochetIRExpansionWarning]
    var atomicActions: [AtomizationEvaluationActionInput]
}

enum AtomizationMatchVerdict: String, Codable, CaseIterable, Hashable {
    case exactMatch = "exact_match"
    case normalizedMatch = "normalized_match"
    case partialMatch = "partial_match"
    case mismatch
    case notActionable = "not_actionable"
}

enum AtomizationMatchIssueCode: String, Codable, CaseIterable, Hashable {
    case missingOperation = "missing_operation"
    case extraOperation = "extra_operation"
    case wrongOperationType = "wrong_operation_type"
    case wrongStitch = "wrong_stitch"
    case wrongCount = "wrong_count"
    case wrongTarget = "wrong_target"
    case wrongOrder = "wrong_order"
    case missingBookkeeping = "missing_bookkeeping"
    case extraBookkeeping = "extra_bookkeeping"
    case missingContext = "missing_context"
    case validationError = "validation_error"
    case expansionFailure = "expansion_failure"
    case ambiguousSource = "ambiguous_source"
}

struct AtomizationMatchEvaluation: Codable, Hashable {
    var roundTitle: String
    var rawInstruction: String
    var verdict: AtomizationMatchVerdict
    var confidence: Double
    var issueCodes: [AtomizationMatchIssueCode]
    var missingElements: [String]
    var extraElements: [String]
    var rationale: String
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
