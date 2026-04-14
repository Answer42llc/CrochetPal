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
    var segments: [AtomizedSegment]

    init(segments: [AtomizedSegment]) {
        self.segments = segments
    }

    init(actionGroups: [ParsedActionGroup]) {
        self.segments = actionGroups.map(\.segment)
    }
}

enum AtomizedSegment: Codable, Hashable {
    case stitchRun(StitchRunSegment)
    case repeatBlock(RepeatSegment)
    case control(ControlSegment)

    private enum CodingKeys: String, CodingKey {
        case kind
        case type
        case count
        case instruction
        case producedStitches
        case note
        case notePlacement
        case times
        case sequence
        case controlKind
        case verbatim
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(AtomizedSegmentKind.self, forKey: .kind)

        switch kind {
        case .stitchRun:
            let notePlacement = try container.decodeIfPresent(AtomizedNotePlacement.self, forKey: .notePlacement) ?? .first
            self = .stitchRun(
                StitchRunSegment(
                    type: try container.decode(StitchActionType.self, forKey: .type),
                    count: try container.decode(Int.self, forKey: .count),
                    instruction: try container.decodeIfPresent(String.self, forKey: .instruction),
                    producedStitches: try container.decodeIfPresent(Int.self, forKey: .producedStitches),
                    note: try container.decodeIfPresent(String.self, forKey: .note),
                    notePlacement: notePlacement,
                    verbatim: try container.decode(String.self, forKey: .verbatim)
                )
            )
        case .repeatBlock:
            self = .repeatBlock(
                RepeatSegment(
                    times: try container.decode(Int.self, forKey: .times),
                    sequence: try container.decode([AtomizedSegment].self, forKey: .sequence),
                    verbatim: try container.decode(String.self, forKey: .verbatim)
                )
            )
        case .control:
            self = .control(
                ControlSegment(
                    kind: try container.decode(ControlSegmentKind.self, forKey: .controlKind),
                    instruction: try container.decodeIfPresent(String.self, forKey: .instruction),
                    note: try container.decodeIfPresent(String.self, forKey: .note),
                    verbatim: try container.decode(String.self, forKey: .verbatim)
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .stitchRun(segment):
            try container.encode(AtomizedSegmentKind.stitchRun, forKey: .kind)
            try container.encode(segment.type, forKey: .type)
            try container.encode(segment.count, forKey: .count)
            try container.encodeIfPresent(segment.instruction, forKey: .instruction)
            try container.encodeIfPresent(segment.producedStitches, forKey: .producedStitches)
            try container.encodeIfPresent(segment.note, forKey: .note)
            try container.encode(segment.notePlacement, forKey: .notePlacement)
            try container.encode(segment.verbatim, forKey: .verbatim)
        case let .repeatBlock(segment):
            try container.encode(AtomizedSegmentKind.repeatBlock, forKey: .kind)
            try container.encode(segment.times, forKey: .times)
            try container.encode(segment.sequence, forKey: .sequence)
            try container.encode(segment.verbatim, forKey: .verbatim)
        case let .control(segment):
            try container.encode(AtomizedSegmentKind.control, forKey: .kind)
            try container.encode(segment.kind, forKey: .controlKind)
            try container.encodeIfPresent(segment.instruction, forKey: .instruction)
            try container.encodeIfPresent(segment.note, forKey: .note)
            try container.encode(segment.verbatim, forKey: .verbatim)
        }
    }
}

enum AtomizedSegmentKind: String, Codable, CaseIterable, Hashable {
    case stitchRun
    case repeatBlock = "repeat"
    case control
}

enum AtomizedNotePlacement: String, Codable, CaseIterable, Hashable {
    case first
    case last
    case all
}

enum ControlSegmentKind: String, Codable, CaseIterable, Hashable {
    case turn
    case skip
    case custom
}

struct StitchRunSegment: Codable, Hashable {
    var type: StitchActionType
    var count: Int
    var instruction: String?
    var producedStitches: Int?
    var note: String? = nil
    var notePlacement: AtomizedNotePlacement
    var verbatim: String
}

struct RepeatSegment: Codable, Hashable {
    var times: Int
    var sequence: [AtomizedSegment]
    var verbatim: String
}

struct ControlSegment: Codable, Hashable {
    var kind: ControlSegmentKind
    var instruction: String?
    var note: String? = nil
    var verbatim: String
}

struct ParsedActionGroup: Hashable {
    var type: StitchActionType
    var count: Int
    var instruction: String?
    var producedStitches: Int?
    var note: String? = nil
    var notePlacement: AtomizedNotePlacement = .first
    var verbatim: String? = nil

    var segment: AtomizedSegment {
        .stitchRun(
            StitchRunSegment(
                type: type,
                count: count,
                instruction: instruction,
                producedStitches: producedStitches,
                note: note,
                notePlacement: notePlacement,
                verbatim: verbatim ?? instruction ?? type.defaultInstruction
            )
        )
    }
}

struct AtomizationRoundInput: Codable, Hashable {
    var partName: String
    var title: String
    var rawInstruction: String
    var summary: String
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
