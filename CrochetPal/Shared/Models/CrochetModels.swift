import Foundation

enum PatternSourceType: String, Codable, Hashable {
    case web
    case text
    case image

    var supportsDeferredAtomization: Bool {
        switch self {
        case .web, .text:
            return true
        case .image:
            return false
        }
    }
}

enum StitchActionType: String, Codable, CaseIterable, Hashable, Identifiable {
    case mr
    case sc
    case fpsc
    case bpsc
    case inc
    case dec
    case ch
    case slSt = "sl_st"
    case blo
    case flo
    case fo
    case esc
    case hdc
    case fphdc
    case bphdc
    case ehdc
    case dc
    case fpdc
    case bpdc
    case edc
    case tr
    case fptr
    case bptr
    case etr
    case dtr
    case fpdtr
    case bpdtr
    case trtr
    case skip
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mr: "MR"
        case .sc: "SC"
        case .fpsc: "FPSC"
        case .bpsc: "BPSC"
        case .inc: "Inc"
        case .dec: "Dec"
        case .ch: "CH"
        case .slSt: "Sl St"
        case .blo: "BLO"
        case .flo: "FLO"
        case .fo: "FO"
        case .esc: "ESC"
        case .hdc: "HDC"
        case .fphdc: "FPHDC"
        case .bphdc: "BPHDC"
        case .ehdc: "EHDC"
        case .dc: "DC"
        case .fpdc: "FPDC"
        case .bpdc: "BPDC"
        case .edc: "EDC"
        case .tr: "TR"
        case .fptr: "FPTR"
        case .bptr: "BPTR"
        case .etr: "ETR"
        case .dtr: "DTR"
        case .fpdtr: "FPDTR"
        case .bpdtr: "BPDTR"
        case .trtr: "TRTR"
        case .skip: "Skip"
        case .custom: "Custom"
        }
    }

    var defaultInstruction: String {
        switch self {
        case .mr: "mr"
        case .sc: "sc"
        case .fpsc: "fpsc"
        case .bpsc: "bpsc"
        case .inc: "inc"
        case .dec: "dec"
        case .ch: "ch"
        case .slSt: "sl st"
        case .blo: "blo"
        case .flo: "flo"
        case .fo: "fo"
        case .esc: "esc"
        case .hdc: "hdc"
        case .fphdc: "fphdc"
        case .bphdc: "bphdc"
        case .ehdc: "ehdc"
        case .dc: "dc"
        case .fpdc: "fpdc"
        case .bpdc: "bpdc"
        case .edc: "edc"
        case .tr: "tr"
        case .fptr: "fptr"
        case .bptr: "bptr"
        case .etr: "etr"
        case .dtr: "dtr"
        case .fpdtr: "fpdtr"
        case .bpdtr: "bpdtr"
        case .trtr: "trtr"
        case .skip: "skip"
        case .custom: "custom"
        }
    }

    var defaultProducedStitches: Int {
        if let producedStitches = CrochetTermDictionary.definition(for: self)?.defaultProducedStitches {
            return producedStitches
        }

        return switch self {
        case .mr: 0
        case .inc: 2
        case .slSt: 0
        case .dec: 1
        case .fo: 0
        case .ch: 0
        case .skip: 0
        case .custom: 0
        default: 1
        }
    }

    var isAtomicActionType: Bool {
        CrochetTermDictionary.supportedAtomicActionTypeSet.contains(self)
    }

    var allowsAtomizationProducedStitchesOverride: Bool {
        false
    }

    func resolvedAtomizationProducedStitches(from override: Int?) -> Int {
        guard allowsAtomizationProducedStitchesOverride, let override else {
            return defaultProducedStitches
        }

        return override
    }

    static func normalized(from rawValue: String) -> StitchActionType {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "slst", "sl_st", "slip_stitch", "slipstitch":
            return .slSt
        default:
            return StitchActionType(rawValue: normalized) ?? .custom
        }
    }
}

enum CrochetTermKind: String, Hashable {
    case action
    case descriptor
    case control
    case reference
    case meta
}

struct CrochetTermDefinition: Hashable {
    var abbreviation: String
    var description: String
    var kind: CrochetTermKind
    var supportedActionType: StitchActionType?
    var defaultProducedStitches: Int?
    var aliases: [String] = []
}

enum CrochetTermDictionary {
    // Source: Craft Yarn Council U.S. crochet abbreviations master list,
    // plus a small set of app-supported aliases that are common in amigurumi patterns.
    static let usTerms: [CrochetTermDefinition] = [
        term("mr", "magic ring", kind: .action, supportedActionType: .mr, producedStitches: 0, aliases: ["magic ring", "magic loop"]),
        term("alt", "alternate", kind: .meta),
        term("approx", "approximately", kind: .meta),
        term("beg", "begin/beginning", kind: .meta),
        term("bet", "between", kind: .reference),
        term("bl", "back loop or back loop only", kind: .descriptor, aliases: ["blo", "back loop", "back loop only"]),
        term("bo", "bobble", kind: .action),
        term("bp", "back post", kind: .descriptor, aliases: ["back post"]),
        term("bpdc", "back post double crochet", kind: .action, supportedActionType: .bpdc, producedStitches: 1),
        term("bpdtr", "back post double treble crochet", kind: .action, supportedActionType: .bpdtr, producedStitches: 1),
        term("bphdc", "back post half double crochet", kind: .action, supportedActionType: .bphdc, producedStitches: 1),
        term("bpsc", "back post single crochet", kind: .action, supportedActionType: .bpsc, producedStitches: 1),
        term("bptr", "back post treble crochet", kind: .action, supportedActionType: .bptr, producedStitches: 1),
        term("cc", "contrasting color", kind: .control),
        term("ch", "chain stitch", kind: .action, supportedActionType: .ch, producedStitches: 0, aliases: ["chain", "chain stitch"]),
        term("ch-", "chain reference", kind: .reference),
        term("ch-sp", "chain space", kind: .reference, aliases: ["chain space"]),
        term("cl", "cluster", kind: .action),
        term("cont", "continue", kind: .meta),
        term("dc", "double crochet", kind: .action, supportedActionType: .dc, producedStitches: 1, aliases: ["double crochet"]),
        term("dc2tog", "double crochet 2 stitches together", kind: .action, supportedActionType: .dec, producedStitches: 1),
        term("dec", "decrease", kind: .action, supportedActionType: .dec, producedStitches: 1, aliases: ["decrease"]),
        term("dtr", "double treble crochet", kind: .action, supportedActionType: .dtr, producedStitches: 1),
        term("edc", "extended double crochet", kind: .action, supportedActionType: .edc, producedStitches: 1),
        term("ehdc", "extended half double crochet", kind: .action, supportedActionType: .ehdc, producedStitches: 1),
        term("esc", "extended single crochet", kind: .action, supportedActionType: .esc, producedStitches: 1),
        term("etr", "extended treble crochet", kind: .action, supportedActionType: .etr, producedStitches: 1),
        term("fl", "front loop or front loop only", kind: .descriptor, aliases: ["flo", "front loop", "front loop only"]),
        term("foll", "following", kind: .meta),
        term("fp", "front post", kind: .descriptor, aliases: ["front post"]),
        term("fpdc", "front post double crochet", kind: .action, supportedActionType: .fpdc, producedStitches: 1),
        term("fpdtr", "front post double treble crochet", kind: .action, supportedActionType: .fpdtr, producedStitches: 1),
        term("fphdc", "front post half double crochet", kind: .action, supportedActionType: .fphdc, producedStitches: 1),
        term("fpsc", "front post single crochet", kind: .action, supportedActionType: .fpsc, producedStitches: 1),
        term("fptr", "front post treble crochet", kind: .action, supportedActionType: .fptr, producedStitches: 1),
        term("fo", "fasten off", kind: .action, supportedActionType: .fo, producedStitches: 0, aliases: ["fasten off"]),
        term("hdc", "half double crochet", kind: .action, supportedActionType: .hdc, producedStitches: 1, aliases: ["half double crochet"]),
        term("hdc2tog", "half double crochet 2 stitches together", kind: .action, supportedActionType: .dec, producedStitches: 1),
        term("inc", "increase", kind: .action, supportedActionType: .inc, producedStitches: 2, aliases: ["increase"]),
        term("lp", "loop", kind: .reference),
        term("m", "marker", kind: .control, aliases: ["marker"]),
        term("mc", "main color", kind: .control, aliases: ["main color"]),
        term("pat", "pattern", kind: .meta, aliases: ["patt"]),
        term("pc", "popcorn stitch", kind: .action),
        term("pm", "place marker", kind: .control, aliases: ["place marker"]),
        term("prev", "previous", kind: .reference),
        term("ps", "puff stitch", kind: .action, aliases: ["puff"]),
        term("rem", "remaining", kind: .meta),
        term("rep", "repeat", kind: .meta, aliases: ["repeat"]),
        term("rnd", "round", kind: .meta, aliases: ["round"]),
        term("rs", "right side", kind: .reference, aliases: ["right side"]),
        term("sc", "single crochet", kind: .action, supportedActionType: .sc, producedStitches: 1, aliases: ["single crochet"]),
        term("sc2tog", "single crochet 2 stitches together", kind: .action, supportedActionType: .dec, producedStitches: 1),
        term("sh", "shell", kind: .action, aliases: ["shell"]),
        term("sk", "skip", kind: .control, supportedActionType: .skip, producedStitches: 0, aliases: ["skip"]),
        term("sl st", "slip stitch", kind: .action, supportedActionType: .slSt, producedStitches: 0, aliases: ["slst", "sl_st", "slip stitch"]),
        term("sm", "slip marker", kind: .control, aliases: ["sl m", "slip marker"]),
        term("sp", "space", kind: .reference, aliases: ["space"]),
        term("st", "stitch", kind: .reference, aliases: ["stitch"]),
        term("tbl", "through back loop", kind: .descriptor, aliases: ["through back loop"]),
        term("tch", "turning chain", kind: .control, aliases: ["t-ch", "turning chain"]),
        term("tog", "together", kind: .reference, aliases: ["together"]),
        term("tr", "treble crochet", kind: .action, supportedActionType: .tr, producedStitches: 1, aliases: ["treble crochet"]),
        term("tr2tog", "treble crochet 2 stitches together", kind: .action, supportedActionType: .dec, producedStitches: 1),
        term("trtr", "triple treble crochet", kind: .action, supportedActionType: .trtr, producedStitches: 1),
        term("ws", "wrong side", kind: .reference, aliases: ["wrong side"]),
        term("yo", "yarn over", kind: .control, aliases: ["yarn over"]),
        term("yoh", "yarn over hook", kind: .control, aliases: ["yarn over hook"])
    ]

    static let supportedAtomicActionTypes: [StitchActionType] = {
        var seen: Set<StitchActionType> = []
        return usTerms.compactMap(\.supportedActionType).filter { seen.insert($0).inserted }
    }()

    static let supportedAtomicActionTypeSet = Set(supportedAtomicActionTypes)

    static func definition(for type: StitchActionType) -> CrochetTermDefinition? {
        usTerms.first(where: { $0.supportedActionType == type })
    }

    static func definition(for abbreviation: String) -> CrochetTermDefinition? {
        let normalizedAbbreviation = normalize(abbreviation)
        return usTerms.first { term in
            normalize(term.abbreviation) == normalizedAbbreviation ||
            term.aliases.contains(where: { normalize($0) == normalizedAbbreviation })
        }
    }

    private static func term(
        _ abbreviation: String,
        _ description: String,
        kind: CrochetTermKind,
        supportedActionType: StitchActionType? = nil,
        producedStitches: Int? = nil,
        aliases: [String] = []
    ) -> CrochetTermDefinition {
        CrochetTermDefinition(
            abbreviation: abbreviation,
            description: description,
            kind: kind,
            supportedActionType: supportedActionType,
            defaultProducedStitches: producedStitches,
            aliases: aliases
        )
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

struct PatternSource: Codable, Hashable {
    var type: PatternSourceType
    var displayName: String
    var sourceURL: String?
    var fileName: String?
    var fileSizeBytes: Int?
    var importedAt: Date
}

struct AtomicAction: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var type: StitchActionType
    var instruction: String?
    var producedStitches: Int
    var note: String? = nil
    var sequenceIndex: Int

    var shortDisplay: String {
        if let instruction, !instruction.isEmpty {
            return instruction
        }
        return type.title
    }

    var executionDisplayTitle: String {
        if type == .custom, let instruction = AtomicAction.normalizedInstruction(instruction) {
            return instruction
        }
        return type.title
    }

    var executionDisplayHint: String? {
        if type == .custom {
            return nil
        }
        return AtomicAction.normalizedInstruction(instruction)
    }

    func matchesExecutionDisplay(as other: AtomicAction) -> Bool {
        type == other.type &&
        instruction == other.instruction &&
        producedStitches == other.producedStitches &&
        note == other.note
    }

    static func normalizedInstruction(_ instruction: String?) -> String? {
        guard let instruction else { return nil }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum RoundAtomizationStatus: String, Codable, Hashable {
    case pending
    case ready
    case failed
}

struct PatternRound: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var rawInstruction: String
    var summary: String
    var targetStitchCount: Int?
    var atomizationStatus: RoundAtomizationStatus
    var atomizationError: String?
    var atomizationWarning: String?
    var atomicActions: [AtomicAction]
}

struct PatternPart: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var rounds: [PatternRound]
}

struct CrochetProject: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var source: PatternSource
    var materials: [String]
    var confidence: Double
    var parts: [PatternPart]
    var activePartID: UUID?
    var createdAt: Date
    var updatedAt: Date

    var activePart: PatternPart? {
        let preferred = activePartID ?? parts.first?.id
        return parts.first(where: { $0.id == preferred })
    }

    var totalAtomicActionCount: Int {
        parts.flatMap(\.rounds).flatMap(\.atomicActions).count
    }

    var totalRoundCount: Int {
        parts.reduce(0) { $0 + $1.rounds.count }
    }

    var hasPendingRounds: Bool {
        parts.flatMap(\.rounds).contains { $0.atomizationStatus != .ready }
    }
}

enum ExecutionCommand: String, Codable, Hashable {
    case forward
    case undo
}

enum ExecutionCommandSource: String, Codable, Hashable {
    case phoneButton
    case watchButton
    case motion
    case sync
}

struct ExecutionCursor: Codable, Hashable {
    var partID: UUID
    var roundIndex: Int
    var actionIndex: Int
}

struct RoundReference: Hashable {
    var partID: UUID
    var roundID: UUID
}

struct ExecutionProgress: Codable, Hashable {
    var projectID: UUID
    var cursor: ExecutionCursor
    var history: [ExecutionCursor]
    var lastCommandSource: ExecutionCommandSource?
    var lastUpdatedAt: Date
    var completedAt: Date?

    static func initial(for project: CrochetProject) -> ExecutionProgress {
        let firstPartID = project.parts.first?.id ?? UUID()
        return ExecutionProgress(
            projectID: project.id,
            cursor: ExecutionCursor(partID: firstPartID, roundIndex: 0, actionIndex: 0),
            history: [],
            lastCommandSource: nil,
            lastUpdatedAt: .now,
            completedAt: nil
        )
    }
}

struct ProjectRecord: Codable, Hashable, Identifiable {
    var project: CrochetProject
    var progress: ExecutionProgress

    var id: UUID { project.id }
}

struct ProjectSnapshot: Codable, Hashable {
    var projectID: UUID
    var title: String
    var partName: String
    var roundTitle: String
    var actionTitle: String
    var actionHint: String?
    var actionNote: String? = nil
    var nextActionTitle: String?
    var actionSequenceProgress: Int?
    var actionSequenceTotal: Int?
    var stitchProgress: Int
    var targetStitches: Int?
    var executionState: SnapshotExecutionState
    var statusMessage: String?
    var canAdvance: Bool
    var isComplete: Bool
    var updatedAt: Date
}

struct RoundActionDraft: Identifiable, Hashable {
    var id: UUID = UUID()
    var type: StitchActionType
    var instruction: String
    var producedStitches: Int
    var note: String
    var count: Int
}

enum SnapshotExecutionState: String, Codable, Hashable {
    case loading
    case ready
    case failed
    case complete
}

enum ProjectExecutionState: Hashable {
    case idle
    case bootstrapping
    case parsingNextRound
    case regeneratingCurrentRound
    case failed(String)

    var snapshotState: SnapshotExecutionState {
        switch self {
        case .idle, .parsingNextRound:
            return .ready
        case .bootstrapping, .regeneratingCurrentRound:
            return .loading
        case .failed:
            return .failed
        }
    }

    var statusMessage: String? {
        switch self {
        case .idle:
            return nil
        case .bootstrapping:
            return "正在解析当前圈"
        case .parsingNextRound:
            return nil
        case .regeneratingCurrentRound:
            return "正在重新生成当前圈"
        case let .failed(message):
            return message
        }
    }

    var canAdvance: Bool {
        switch self {
        case .idle, .parsingNextRound:
            return true
        case .bootstrapping, .regeneratingCurrentRound, .failed:
            return false
        }
    }

    var isBusy: Bool {
        switch self {
        case .bootstrapping, .parsingNextRound, .regeneratingCurrentRound:
            return true
        case .idle, .failed:
            return false
        }
    }
}
