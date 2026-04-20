import Foundation

struct CrochetIRAtomizationResponse: Codable, Hashable {
    var rounds: [CrochetIRInstructionBlock]
}

/// A loss-preserving intermediate representation for one crochet row, round, or instruction block.
/// The LLM should compile source pattern text into this IR, then deterministic Swift code
/// expands it into AtomicAction values.
struct CrochetIRInstructionBlock: Codable, Hashable {
    var title: String
    var sourceText: String
    var expectedProducedStitches: Int?
    var nodes: [CrochetIRNode]

    init(
        title: String,
        sourceText: String,
        expectedProducedStitches: Int? = nil,
        nodes: [CrochetIRNode]
    ) {
        self.title = title
        self.sourceText = sourceText
        self.expectedProducedStitches = expectedProducedStitches
        self.nodes = nodes
    }
}

enum CrochetIRNode: Codable, Hashable {
    case stitch(CrochetIRStitch)
    case repeatBlock(CrochetIRRepeat)
    case conditional(CrochetIRConditional)
    case control(CrochetIRControl)
    case note(CrochetIRNote)
    case ambiguous(CrochetIRAmbiguous)

    private enum CodingKeys: String, CodingKey {
        case kind
        case stitch
        case repeatBlock = "repeat"
        case conditional
        case control
        case note
        case ambiguous
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(CrochetIRNodeKind.self, forKey: .kind)

        switch kind {
        case .stitch:
            guard let value = try container.decodeIfPresent(CrochetIRStitch.self, forKey: .stitch) else {
                throw DecodingError.dataCorruptedError(forKey: .stitch, in: container, debugDescription: "missing stitch payload")
            }
            self = .stitch(value)
        case .repeatBlock:
            guard let value = try container.decodeIfPresent(CrochetIRRepeat.self, forKey: .repeatBlock) else {
                throw DecodingError.dataCorruptedError(forKey: .repeatBlock, in: container, debugDescription: "missing repeat payload")
            }
            self = .repeatBlock(value)
        case .conditional:
            guard let value = try container.decodeIfPresent(CrochetIRConditional.self, forKey: .conditional) else {
                throw DecodingError.dataCorruptedError(forKey: .conditional, in: container, debugDescription: "missing conditional payload")
            }
            self = .conditional(value)
        case .control:
            guard let value = try container.decodeIfPresent(CrochetIRControl.self, forKey: .control) else {
                throw DecodingError.dataCorruptedError(forKey: .control, in: container, debugDescription: "missing control payload")
            }
            self = .control(value)
        case .note:
            guard let value = try container.decodeIfPresent(CrochetIRNote.self, forKey: .note) else {
                throw DecodingError.dataCorruptedError(forKey: .note, in: container, debugDescription: "missing note payload")
            }
            self = .note(value)
        case .ambiguous:
            guard let value = try container.decodeIfPresent(CrochetIRAmbiguous.self, forKey: .ambiguous) else {
                throw DecodingError.dataCorruptedError(forKey: .ambiguous, in: container, debugDescription: "missing ambiguous payload")
            }
            self = .ambiguous(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .stitch(value):
            try container.encode(CrochetIRNodeKind.stitch, forKey: .kind)
            try container.encode(value, forKey: .stitch)
            try container.encodeNil(forKey: .repeatBlock)
            try container.encodeNil(forKey: .conditional)
            try container.encodeNil(forKey: .control)
            try container.encodeNil(forKey: .note)
            try container.encodeNil(forKey: .ambiguous)
        case let .repeatBlock(value):
            try container.encode(CrochetIRNodeKind.repeatBlock, forKey: .kind)
            try container.encodeNil(forKey: .stitch)
            try container.encode(value, forKey: .repeatBlock)
            try container.encodeNil(forKey: .conditional)
            try container.encodeNil(forKey: .control)
            try container.encodeNil(forKey: .note)
            try container.encodeNil(forKey: .ambiguous)
        case let .conditional(value):
            try container.encode(CrochetIRNodeKind.conditional, forKey: .kind)
            try container.encodeNil(forKey: .stitch)
            try container.encodeNil(forKey: .repeatBlock)
            try container.encode(value, forKey: .conditional)
            try container.encodeNil(forKey: .control)
            try container.encodeNil(forKey: .note)
            try container.encodeNil(forKey: .ambiguous)
        case let .control(value):
            try container.encode(CrochetIRNodeKind.control, forKey: .kind)
            try container.encodeNil(forKey: .stitch)
            try container.encodeNil(forKey: .repeatBlock)
            try container.encodeNil(forKey: .conditional)
            try container.encode(value, forKey: .control)
            try container.encodeNil(forKey: .note)
            try container.encodeNil(forKey: .ambiguous)
        case let .note(value):
            try container.encode(CrochetIRNodeKind.note, forKey: .kind)
            try container.encodeNil(forKey: .stitch)
            try container.encodeNil(forKey: .repeatBlock)
            try container.encodeNil(forKey: .conditional)
            try container.encodeNil(forKey: .control)
            try container.encode(value, forKey: .note)
            try container.encodeNil(forKey: .ambiguous)
        case let .ambiguous(value):
            try container.encode(CrochetIRNodeKind.ambiguous, forKey: .kind)
            try container.encodeNil(forKey: .stitch)
            try container.encodeNil(forKey: .repeatBlock)
            try container.encodeNil(forKey: .conditional)
            try container.encodeNil(forKey: .control)
            try container.encodeNil(forKey: .note)
            try container.encode(value, forKey: .ambiguous)
        }
    }
}

enum CrochetIRNodeKind: String, Codable, CaseIterable, Hashable {
    case stitch
    case repeatBlock = "repeat"
    case conditional
    case control
    case note
    case ambiguous
}

struct CrochetIRStitch: Codable, Hashable {
    var type: StitchActionType
    var count: Int
    var instruction: String?
    var producedStitches: Int?
    var note: String?
    var notePlacement: AtomizedNotePlacement
    var sourceText: String?

    init(
        type: StitchActionType,
        count: Int = 1,
        instruction: String? = nil,
        producedStitches: Int? = nil,
        note: String? = nil,
        notePlacement: AtomizedNotePlacement = .first,
        sourceText: String? = nil
    ) {
        self.type = type
        self.count = count
        self.instruction = instruction
        self.producedStitches = producedStitches
        self.note = note
        self.notePlacement = notePlacement
        self.sourceText = sourceText
    }
}

struct CrochetIRRepeat: Codable, Hashable {
    var times: Int
    var body: [CrochetIRNode]
    var lastIterationTransform: CrochetIRRepeatLastIterationTransform?
    var sourceText: String?

    init(
        times: Int,
        body: [CrochetIRNode],
        lastIterationTransform: CrochetIRRepeatLastIterationTransform? = nil,
        sourceText: String? = nil
    ) {
        self.times = times
        self.body = body
        self.lastIterationTransform = lastIterationTransform
        self.sourceText = sourceText
    }
}

/// Represents final-repeat exceptions, such as "omit the final ch3; instead work ch1, then hdc".
struct CrochetIRRepeatLastIterationTransform: Codable, Hashable {
    var removeTailNodeCount: Int
    var append: [CrochetIRNode]
    var sourceText: String?

    init(
        removeTailNodeCount: Int,
        append: [CrochetIRNode] = [],
        sourceText: String? = nil
    ) {
        self.removeTailNodeCount = removeTailNodeCount
        self.append = append
        self.sourceText = sourceText
    }
}

struct CrochetIRConditional: Codable, Hashable {
    var choiceID: String
    var question: String
    var branches: [CrochetIRConditionalBranch]
    var defaultBranchValue: String?
    var commonBody: [CrochetIRNode]
    var sourceText: String?

    init(
        choiceID: String,
        question: String,
        branches: [CrochetIRConditionalBranch],
        defaultBranchValue: String? = nil,
        commonBody: [CrochetIRNode] = [],
        sourceText: String? = nil
    ) {
        self.choiceID = choiceID
        self.question = question
        self.branches = branches
        self.defaultBranchValue = defaultBranchValue
        self.commonBody = commonBody
        self.sourceText = sourceText
    }
}

struct CrochetIRConditionalBranch: Codable, Hashable {
    var value: String
    var label: String
    var nodes: [CrochetIRNode]

    init(value: String, label: String, nodes: [CrochetIRNode]) {
        self.value = value
        self.label = label
        self.nodes = nodes
    }
}

struct CrochetIRControl: Codable, Hashable {
    var kind: ControlSegmentKind
    var instruction: String?
    var note: String?
    var sourceText: String?

    init(
        kind: ControlSegmentKind,
        instruction: String? = nil,
        note: String? = nil,
        sourceText: String? = nil
    ) {
        self.kind = kind
        self.instruction = instruction
        self.note = note
        self.sourceText = sourceText
    }
}

struct CrochetIRNote: Codable, Hashable {
    var message: String
    var sourceText: String?
    var emitAsAction: Bool

    init(message: String, sourceText: String? = nil, emitAsAction: Bool = false) {
        self.message = message
        self.sourceText = sourceText
        self.emitAsAction = emitAsAction
    }
}

/// A safe placeholder for text that is important but cannot be normalized confidently.
/// The compiler emits it as a custom action and returns a warning.
struct CrochetIRAmbiguous: Codable, Hashable {
    var reason: String
    var sourceText: String
    var safeInstruction: String?

    init(reason: String, sourceText: String, safeInstruction: String? = nil) {
        self.reason = reason
        self.sourceText = sourceText
        self.safeInstruction = safeInstruction
    }
}

struct CrochetIRExpansion: Hashable {
    var atomicActions: [AtomicAction]
    var producedStitchCount: Int
    var warnings: [CrochetIRExpansionWarning]
}

struct CrochetIRExpansionWarning: Codable, Hashable {
    var code: String
    var message: String
    var sourceText: String?
}

enum CrochetIRValidationSeverity: String, Codable, Hashable {
    case warning
    case error
}

struct CrochetIRValidationIssue: Codable, Hashable {
    var severity: CrochetIRValidationSeverity
    var code: String
    var message: String
    var sourceText: String?
}

struct CrochetIRValidationReport: Codable, Hashable {
    var issues: [CrochetIRValidationIssue]

    var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    var warnings: [CrochetIRValidationIssue] {
        issues.filter { $0.severity == .warning }
    }
}
