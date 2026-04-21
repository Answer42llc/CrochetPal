import Foundation

struct CrochetIRAtomizationResponse: Codable, Hashable {
    var rounds: [CrochetIRInstructionBlock]
}

/// A loss-preserving intermediate representation for one crochet row, round, or instruction block.
/// The LLM compiles source pattern text into this IR, then deterministic Swift code
/// expands it into AtomicAction values.
///
/// Design invariants:
/// - A Block is a list of statements executed in order. There is no `sequence` statement kind —
///   sequential execution is the natural semantics of an ordered array.
/// - A `repeatBlock` statement expresses a homogeneous loop. Every iteration must be identical.
///   Iteration-specific exceptions ("omit the final X", "on the last repeat Y") must be normalized
///   by the LLM into a homogeneous repeatBlock plus flat statements in the enclosing block.
/// - Operation is split into a closed semantics enum (compiler-relevant) and an open actionTag
///   string (UI-relevant) so new actions never require a code change in the compiler.
struct CrochetIRInstructionBlock: Codable, Hashable {
    var title: String
    var sourceText: String
    var expectedProducedStitches: Int?
    var body: CrochetIRBlock

    init(
        title: String,
        sourceText: String,
        expectedProducedStitches: Int? = nil,
        body: CrochetIRBlock
    ) {
        self.title = title
        self.sourceText = sourceText
        self.expectedProducedStitches = expectedProducedStitches
        self.body = body
    }
}

/// An ordered list of statements. Block is the "sequence" concept: it has no independent
/// execution semantics beyond iterating its children in order, but it owns debug metadata
/// (sourceText, normalizationNote) that documents how the block was produced.
struct CrochetIRBlock: Codable, Hashable {
    var statements: [CrochetIRStatement]
    var sourceText: String?
    var normalizationNote: String?

    init(
        statements: [CrochetIRStatement],
        sourceText: String? = nil,
        normalizationNote: String? = nil
    ) {
        self.statements = statements
        self.sourceText = sourceText
        self.normalizationNote = normalizationNote
    }
}

/// A single statement in a Block. The kind discriminant determines which payload is active.
///
/// The JSON wire format is flat (matching the LLM schema):
/// ```
/// { "kind": "operation", "operation": {...}, "repeat": null, "conditional": null,
///   "note": null, "sourceText": "..." }
/// ```
/// so CrochetIRStatement owns the whole Codable implementation; CrochetIRStatementKind
/// itself does not conform to Codable.
struct CrochetIRStatement: Hashable {
    var kind: CrochetIRStatementKind
    var sourceText: String?

    init(kind: CrochetIRStatementKind, sourceText: String? = nil) {
        self.kind = kind
        self.sourceText = sourceText
    }
}

enum CrochetIRStatementKind: Hashable {
    case operation(CrochetIROperation)
    case repeatBlock(CrochetIRRepeatBlock)
    case conditional(CrochetIRConditional)
    case note(CrochetIRNote)
}

enum CrochetIRStatementKindTag: String, Codable, CaseIterable, Hashable {
    case operation
    case repeatBlock = "repeat"
    case conditional
    case note
}

extension CrochetIRStatement: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case sourceText
        case operation
        case repeatBlock = "repeat"
        case conditional
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(CrochetIRStatementKindTag.self, forKey: .kind)
        self.sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText)

        switch tag {
        case .operation:
            guard let value = try container.decodeIfPresent(CrochetIROperation.self, forKey: .operation) else {
                throw DecodingError.dataCorruptedError(forKey: .operation, in: container, debugDescription: "missing operation payload")
            }
            self.kind = .operation(value)
        case .repeatBlock:
            guard let value = try container.decodeIfPresent(CrochetIRRepeatBlock.self, forKey: .repeatBlock) else {
                throw DecodingError.dataCorruptedError(forKey: .repeatBlock, in: container, debugDescription: "missing repeat payload")
            }
            self.kind = .repeatBlock(value)
        case .conditional:
            guard let value = try container.decodeIfPresent(CrochetIRConditional.self, forKey: .conditional) else {
                throw DecodingError.dataCorruptedError(forKey: .conditional, in: container, debugDescription: "missing conditional payload")
            }
            self.kind = .conditional(value)
        case .note:
            if let value = try container.decodeIfPresent(CrochetIRNote.self, forKey: .note) {
                self.kind = .note(value)
            } else if let fallback = self.sourceText, !fallback.isEmpty {
                // LLM sometimes sets kind=note but leaves the note payload null, putting
                // the actual text in sourceText. Tolerate that so we don't lose the content;
                // downstream validators can still flag it as a prompt-quality issue.
                self.kind = .note(CrochetIRNote(message: fallback, sourceText: fallback, emitAsAction: false))
            } else {
                throw DecodingError.dataCorruptedError(forKey: .note, in: container, debugDescription: "missing note payload")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sourceText, forKey: .sourceText)

        switch kind {
        case let .operation(value):
            try container.encode(CrochetIRStatementKindTag.operation, forKey: .kind)
            try container.encode(value, forKey: .operation)
            try container.encodeNil(forKey: .repeatBlock)
            try container.encodeNil(forKey: .conditional)
            try container.encodeNil(forKey: .note)
        case let .repeatBlock(value):
            try container.encode(CrochetIRStatementKindTag.repeatBlock, forKey: .kind)
            try container.encodeNil(forKey: .operation)
            try container.encode(value, forKey: .repeatBlock)
            try container.encodeNil(forKey: .conditional)
            try container.encodeNil(forKey: .note)
        case let .conditional(value):
            try container.encode(CrochetIRStatementKindTag.conditional, forKey: .kind)
            try container.encodeNil(forKey: .operation)
            try container.encodeNil(forKey: .repeatBlock)
            try container.encode(value, forKey: .conditional)
            try container.encodeNil(forKey: .note)
        case let .note(value):
            try container.encode(CrochetIRStatementKindTag.note, forKey: .kind)
            try container.encodeNil(forKey: .operation)
            try container.encodeNil(forKey: .repeatBlock)
            try container.encodeNil(forKey: .conditional)
            try container.encode(value, forKey: .note)
        }
    }
}

// `CrochetIROperationSemantics` is defined in CrochetModels.swift so that
// `AtomicAction.semantics` can be referenced by both the main app and the watch target
// (which only links CrochetModels.swift, not the IR files).

/// The concrete atomic action in an instruction.
///
/// - `semantics` is a closed enum that the compiler switches on.
/// - `actionTag` is an open string that labels the action for UI / trace. The prompt suggests
///   a recommended vocabulary, but the schema does not constrain it — unknown tags flow through
///   the compiler unchanged and are rendered by a table-driven UI lookup with a generic fallback.
struct CrochetIROperation: Codable, Hashable {
    var semantics: CrochetIROperationSemantics
    var actionTag: String
    /// Author's stitch name — OPEN string. Can be a standard tag (`"sc"`, `"dc"`, `"slst"`)
    /// or a pattern-specific abbreviation (`"cs"` for "cap stitch"). The catalog tells us
    /// whether it's a known tag or not, but unknown tags are accepted.
    var stitch: String?
    var count: Int
    var instruction: String?
    var target: String?
    var note: String?
    var notePlacement: AtomizedNotePlacement
    var producedStitches: Int?

    init(
        semantics: CrochetIROperationSemantics,
        actionTag: String,
        stitch: String? = nil,
        count: Int = 1,
        instruction: String? = nil,
        target: String? = nil,
        note: String? = nil,
        notePlacement: AtomizedNotePlacement = .first,
        producedStitches: Int? = nil
    ) {
        self.semantics = semantics
        self.actionTag = actionTag
        self.stitch = stitch
        self.count = count
        self.instruction = instruction
        self.target = target
        self.note = note
        self.notePlacement = notePlacement
        self.producedStitches = producedStitches
    }
}

/// A homogeneous repeat. Every iteration of `body` is identical. Iteration-specific exceptions
/// (omit the final X, on the last repeat Y) must be normalized by the LLM into a shorter
/// `times` plus flat statements in the enclosing block.
struct CrochetIRRepeatBlock: Codable, Hashable {
    var times: Int
    var body: CrochetIRBlock
    /// The count that appeared in the pattern source before normalization (for debugging).
    /// May be higher than `times` when the final iteration was pulled out.
    var sourceRepeatCount: Int?
    var normalizationNote: String?

    init(
        times: Int,
        body: CrochetIRBlock,
        sourceRepeatCount: Int? = nil,
        normalizationNote: String? = nil
    ) {
        self.times = times
        self.body = body
        self.sourceRepeatCount = sourceRepeatCount
        self.normalizationNote = normalizationNote
    }
}

struct CrochetIRConditional: Codable, Hashable {
    var choiceID: String
    var question: String
    var branches: [CrochetIRConditionalBranch]
    var defaultBranchValue: String?
    /// Statements executed after the selected branch. Optional — nil means no common tail.
    var commonBody: CrochetIRBlock?

    init(
        choiceID: String,
        question: String,
        branches: [CrochetIRConditionalBranch],
        defaultBranchValue: String? = nil,
        commonBody: CrochetIRBlock? = nil
    ) {
        self.choiceID = choiceID
        self.question = question
        self.branches = branches
        self.defaultBranchValue = defaultBranchValue
        self.commonBody = commonBody
    }
}

struct CrochetIRConditionalBranch: Codable, Hashable {
    var value: String
    var label: String
    var body: CrochetIRBlock

    init(value: String, label: String, body: CrochetIRBlock) {
        self.value = value
        self.label = label
        self.body = body
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
