import Foundation

/// Semantics decide how the compiler expands an Operation. Only 4 values — this enum is
/// closed by design, because these are the only distinct compiler behaviors we need.
///
/// Defined here (rather than in CrochetIRModels.swift) so that `AtomicAction` — which is
/// linked into both the main app and the watch target — can reference it.
enum CrochetIROperationSemantics: String, Codable, CaseIterable, Hashable {
    /// Produces `count` stitches, each occupying one stitch-slot of the previous round.
    /// Examples: sc, hdc, dc, ch, slst, fpdc, fphdc, fpsc.
    case stitchProducing
    /// Produces N stitches into a single stitch-slot. Encoded as `count = 1`, with
    /// `producedStitches = N`.
    case increase
    /// Consumes M stitch-slots and produces 1 stitch. Typically `stitch = "dec"`.
    case decrease
    /// Does not produce stitches. Examples: turn, skip, joinYarn, fastenOff, changeColor,
    /// setWorkingLoop, placeMarker, removeMarker, moveMarker, assembly, custom.
    case bookkeeping
}

/// One author-defined abbreviation, typically from an "Abbreviations" section at the top
/// of the pattern. Propagated verbatim into the IR atomization prompt so the LLM uses
/// the author's vocabulary instead of remapping to standard stitches.
///
/// Defined here (rather than in ParseModels.swift) so it can live on `CrochetProject`,
/// which is shared with the watch target.
struct PatternAbbreviation: Codable, Hashable {
    var term: String
    var definition: String
}

enum PatternSourceType: String, Codable, Hashable {
    case web
    case text
    case image
    case pdf

    var supportsDeferredAtomization: Bool {
        switch self {
        case .web, .text, .pdf:
            return true
        case .image:
            return false
        }
    }
}

/// Canonical vocabulary of known crochet stitch tags. `stitchTag` is an OPEN string
/// (the LLM may invent new tags for pattern-specific abbreviations), but for the subset we
/// do recognize we provide display titles, default produced-stitch counts, and a
/// descriptor/action classification so the compiler can validate whether a tag is usable as
/// an actual stitch-producing operation.
///
/// NOTE: this is intentionally tag-centric, not enum-centric. New stitches don't require
/// code changes; they just flow through with fallback defaults.
enum CrochetStitchCatalog {
    /// All stitch tags that are valid as a stitch-producing operation. `blo/flo/fo` etc.
    /// are descriptors/meta, not stitches themselves, so they're excluded.
    static let knownStitchTags: Set<String> = [
        "mr",
        "sc", "fpsc", "bpsc",
        "dec",
        "ch",
        "slst",
        "esc", "hdc", "fphdc", "bphdc", "ehdc",
        "dc", "fpdc", "bpdc", "edc",
        "tr", "fptr", "bptr", "etr",
        "dtr", "fpdtr", "bpdtr",
        "trtr"
    ]

    /// Tags that are NOT valid as stitch-producing — they describe WHERE to insert
    /// (loops), or are meta commands. Validator rejects these in stitchProducing/inc/dec.
    static let knownDescriptorOrMetaTags: Set<String> = [
        "blo", "flo", "bl", "fl", "fo", "skip", "sk", "yo", "yoh", "custom",
        "turn", "join", "fastenoff", "fasten_off",
        "placemarker", "place_marker", "removemarker", "remove_marker",
        "movemarker", "move_marker", "assembly"
    ]

    /// Tags typically shown in the round editor picker. Order matches common usage.
    static let commonPickerTags: [String] = [
        "sc", "hdc", "dc", "ch", "slst", "mr", "dec",
        "fpdc", "fphdc", "fpsc", "bpdc", "bphdc", "bpsc",
        "tr", "dtr",
        "custom"
    ]

    /// Canonicalizes free-form tag spellings to a normalized form we can match against the
    /// catalog. Example: "sl_st" / "SL ST" / "Sl-St" / "slip stitch" all map to "slst".
    static func canonicalize(_ tag: String) -> String {
        let lowered = tag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch lowered {
        case "sl_st", "slst", "slip_stitch", "slipstitch":
            return "slst"
        case "magic_ring", "magicring", "magic_loop", "magicloop":
            return "mr"
        case "single_crochet":
            return "sc"
        case "double_crochet":
            return "dc"
        case "half_double_crochet":
            return "hdc"
        case "treble_crochet", "triple_crochet":
            return "tr"
        case "fasten_off", "fastenoff":
            return "fo"
        case "back_loop", "back_loop_only", "blo":
            return "blo"
        case "front_loop", "front_loop_only", "flo":
            return "flo"
        case "place_marker", "placemarker":
            return "placeMarker"
        case "remove_marker", "removemarker":
            return "removeMarker"
        default:
            return lowered.replacingOccurrences(of: "_", with: "")
        }
    }

    /// `true` if this tag is acceptable as a stitchProducing / increase / decrease operation.
    /// Unknown tags are treated as "yes" (open vocabulary) — only explicit descriptors are blocked.
    static func isValidStitchTag(_ tag: String) -> Bool {
        let canonical = canonicalize(tag)
        return !knownDescriptorOrMetaTags.contains(canonical)
    }

    /// Default produced stitches for known tags. Unknown tags default to 1 (safest for an
    /// unrecognized custom stitch — it's at least producing something).
    static func defaultProducedStitches(for tag: String) -> Int {
        let canonical = canonicalize(tag)
        switch canonical {
        case "mr", "slst", "ch", "fo", "skip", "custom":
            return 0
        default:
            return 1
        }
    }

    /// Display title used by execution UI. Prefers the catalog's short uppercase form for
    /// known tags; falls back to the original tag uppercased for unknown ones (which is a
    /// reasonable default for user-invented tags like "cs" → "CS" or "capStitch" → "CAPSTITCH").
    static func displayTitle(for tag: String) -> String {
        let canonical = canonicalize(tag)
        switch canonical {
        case "mr": return "MR"
        case "sc": return "SC"
        case "fpsc": return "FPSC"
        case "bpsc": return "BPSC"
        case "dec": return "Dec"
        case "ch": return "CH"
        case "slst": return "Sl St"
        case "blo": return "BLO"
        case "flo": return "FLO"
        case "fo": return "FO"
        case "esc": return "ESC"
        case "hdc": return "HDC"
        case "fphdc": return "FPHDC"
        case "bphdc": return "BPHDC"
        case "ehdc": return "EHDC"
        case "dc": return "DC"
        case "fpdc": return "FPDC"
        case "bpdc": return "BPDC"
        case "edc": return "EDC"
        case "tr": return "TR"
        case "fptr": return "FPTR"
        case "bptr": return "BPTR"
        case "etr": return "ETR"
        case "dtr": return "DTR"
        case "fpdtr": return "FPDTR"
        case "bpdtr": return "BPDTR"
        case "trtr": return "TRTR"
        case "skip": return "Skip"
        case "custom": return "Custom"
        default:
            // Unknown tag — just uppercase. Keeps the original author's wording visible.
            return tag.uppercased()
        }
    }
}

/// Classic term dictionary used to build prompt vocabulary and normalize abbreviations in
/// extracted text. Values are plain strings so they can be substituted for the old enum.
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
    /// The canonical `stitchTag` string if this term maps to a stitch-producing operation.
    /// nil for descriptors/meta.
    var supportedStitchTag: String?
    var defaultProducedStitches: Int?
    var aliases: [String] = []
}

enum CrochetTermDictionary {
    static let usTerms: [CrochetTermDefinition] = [
        term("mr", "magic ring", kind: .action, stitchTag: "mr", producedStitches: 0, aliases: ["magic ring", "magic loop"]),
        term("alt", "alternate", kind: .meta),
        term("approx", "approximately", kind: .meta),
        term("beg", "begin/beginning", kind: .meta),
        term("bet", "between", kind: .reference),
        term("bl", "back loop or back loop only", kind: .descriptor, aliases: ["blo", "back loop", "back loop only"]),
        term("bo", "bobble", kind: .action),
        term("bp", "back post", kind: .descriptor, aliases: ["back post"]),
        term("bpdc", "back post double crochet", kind: .action, stitchTag: "bpdc", producedStitches: 1),
        term("bpdtr", "back post double treble crochet", kind: .action, stitchTag: "bpdtr", producedStitches: 1),
        term("bphdc", "back post half double crochet", kind: .action, stitchTag: "bphdc", producedStitches: 1),
        term("bpsc", "back post single crochet", kind: .action, stitchTag: "bpsc", producedStitches: 1),
        term("bptr", "back post treble crochet", kind: .action, stitchTag: "bptr", producedStitches: 1),
        term("cc", "contrasting color", kind: .control),
        term("ch", "chain stitch", kind: .action, stitchTag: "ch", producedStitches: 0, aliases: ["chain", "chain stitch"]),
        term("ch-", "chain reference", kind: .reference),
        term("ch-sp", "chain space", kind: .reference, aliases: ["chain space"]),
        term("cl", "cluster", kind: .action),
        term("cont", "continue", kind: .meta),
        term("dc", "double crochet", kind: .action, stitchTag: "dc", producedStitches: 1, aliases: ["double crochet"]),
        term("dc2tog", "double crochet 2 stitches together", kind: .action, stitchTag: "dec", producedStitches: 1),
        term("dec", "decrease", kind: .action, stitchTag: "dec", producedStitches: 1, aliases: ["decrease"]),
        term("dtr", "double treble crochet", kind: .action, stitchTag: "dtr", producedStitches: 1),
        term("edc", "extended double crochet", kind: .action, stitchTag: "edc", producedStitches: 1),
        term("ehdc", "extended half double crochet", kind: .action, stitchTag: "ehdc", producedStitches: 1),
        term("esc", "extended single crochet", kind: .action, stitchTag: "esc", producedStitches: 1),
        term("etr", "extended treble crochet", kind: .action, stitchTag: "etr", producedStitches: 1),
        term("fl", "front loop or front loop only", kind: .descriptor, aliases: ["flo", "front loop", "front loop only"]),
        term("foll", "following", kind: .meta),
        term("fp", "front post", kind: .descriptor, aliases: ["front post"]),
        term("fpdc", "front post double crochet", kind: .action, stitchTag: "fpdc", producedStitches: 1),
        term("fpdtr", "front post double treble crochet", kind: .action, stitchTag: "fpdtr", producedStitches: 1),
        term("fphdc", "front post half double crochet", kind: .action, stitchTag: "fphdc", producedStitches: 1),
        term("fpsc", "front post single crochet", kind: .action, stitchTag: "fpsc", producedStitches: 1),
        term("fptr", "front post treble crochet", kind: .action, stitchTag: "fptr", producedStitches: 1),
        term("fo", "fasten off", kind: .action, stitchTag: "fo", producedStitches: 0, aliases: ["fasten off"]),
        term("hdc", "half double crochet", kind: .action, stitchTag: "hdc", producedStitches: 1, aliases: ["half double crochet"]),
        term("hdc2tog", "half double crochet 2 stitches together", kind: .action, stitchTag: "dec", producedStitches: 1),
        term("inc", "increase", kind: .action, aliases: ["increase"]),
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
        term("sc", "single crochet", kind: .action, stitchTag: "sc", producedStitches: 1, aliases: ["single crochet"]),
        term("sc2tog", "single crochet 2 stitches together", kind: .action, stitchTag: "dec", producedStitches: 1),
        term("sh", "shell", kind: .action, aliases: ["shell"]),
        term("sk", "skip", kind: .control, stitchTag: "skip", producedStitches: 0, aliases: ["skip"]),
        term("sl st", "slip stitch", kind: .action, stitchTag: "slst", producedStitches: 0, aliases: ["slst", "sl_st", "slip stitch"]),
        term("sm", "slip marker", kind: .control, aliases: ["sl m", "slip marker"]),
        term("sp", "space", kind: .reference, aliases: ["space"]),
        term("st", "stitch", kind: .reference, aliases: ["stitch"]),
        term("tbl", "through back loop", kind: .descriptor, aliases: ["through back loop"]),
        term("tch", "turning chain", kind: .control, aliases: ["t-ch", "turning chain"]),
        term("tog", "together", kind: .reference, aliases: ["together"]),
        term("tr", "treble crochet", kind: .action, stitchTag: "tr", producedStitches: 1, aliases: ["treble crochet"]),
        term("tr2tog", "treble crochet 2 stitches together", kind: .action, stitchTag: "dec", producedStitches: 1),
        term("trtr", "triple treble crochet", kind: .action, stitchTag: "trtr", producedStitches: 1),
        term("ws", "wrong side", kind: .reference, aliases: ["wrong side"]),
        term("yo", "yarn over", kind: .control, aliases: ["yarn over"]),
        term("yoh", "yarn over hook", kind: .control, aliases: ["yarn over hook"])
    ]

    /// All canonical stitch tags that appear as `supportedStitchTag` in the dictionary.
    static let supportedStitchTags: [String] = {
        var seen: Set<String> = []
        return usTerms.compactMap(\.supportedStitchTag).filter { seen.insert($0).inserted }
    }()

    static let supportedStitchTagSet = Set(supportedStitchTags)

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
        stitchTag: String? = nil,
        producedStitches: Int? = nil,
        aliases: [String] = []
    ) -> CrochetTermDefinition {
        CrochetTermDefinition(
            abbreviation: abbreviation,
            description: description,
            kind: kind,
            supportedStitchTag: stitchTag,
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

/// A single tap-per-action instruction emitted by the compiler and executed by the UI.
///
/// Fields:
/// - `semantics`: how this action contributes to stitch counting (matches `CrochetIROperationSemantics`)
/// - `actionTag`: UI identity — used for icon lookup; always present
/// - `stitchTag`: for stitch-producing / increase / decrease semantics, the author's stitch
///   name (could be a standard like `"sc"` or a pattern-specific like `"cs"`); nil for
///   bookkeeping actions
/// - `instruction`: free-text description to display; required for bookkeeping actions and
///   optional otherwise
struct AtomicAction: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var semantics: CrochetIROperationSemantics
    var actionTag: String
    var stitchTag: String?
    var instruction: String?
    var producedStitches: Int
    var note: String? = nil
    /// The segment of the enclosing round's `rawInstruction` that produced this action.
    /// Threaded through from `CrochetIRStatement.sourceText`; used by the UI to highlight
    /// the matching phrase while stepping through a round. May be nil for actions emitted
    /// by error-fallback paths (e.g., missing conditional choice) or for actions loaded
    /// from fixtures captured before this field existed.
    var sourceText: String? = nil
    var sequenceIndex: Int

    var shortDisplay: String {
        if let instruction = Self.normalizedInstruction(instruction) {
            return instruction
        }
        return preferredDisplayTitle
    }

    var executionDisplayTitle: String {
        switch semantics {
        case .bookkeeping:
            // "custom" is the free-text fallback tag: treat instruction as the title itself.
            // Any other bookkeeping tag (skip, turn, joinYarn, placeMarker, ...) has a
            // meaningful display name — show that in the title and put instruction in the
            // hint so users see both.
            if actionTag == "custom", let instruction = Self.normalizedInstruction(instruction) {
                return instruction
            }
            return CrochetStitchCatalog.displayTitle(for: actionTag)
        case .stitchProducing, .increase, .decrease:
            return preferredDisplayTitle
        }
    }

    var executionDisplayHint: String? {
        switch semantics {
        case .bookkeeping where actionTag == "custom":
            return nil
        case .bookkeeping:
            return Self.normalizedInstruction(instruction)
        case .stitchProducing, .increase, .decrease:
            return Self.normalizedInstruction(instruction)
        }
    }

    func matchesExecutionDisplay(as other: AtomicAction) -> Bool {
        semantics == other.semantics &&
        actionTag == other.actionTag &&
        stitchTag == other.stitchTag &&
        instruction == other.instruction &&
        producedStitches == other.producedStitches &&
        note == other.note
    }

    static func normalizedInstruction(_ instruction: String?) -> String? {
        guard let instruction else { return nil }
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Preferred human title: stitchTag (upper-cased through catalog) if present, else actionTag.
    private var preferredDisplayTitle: String {
        if let stitchTag {
            return CrochetStitchCatalog.displayTitle(for: stitchTag)
        }
        return CrochetStitchCatalog.displayTitle(for: actionTag)
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
    /// Index of the source round within the macro-repeat cycle (0..<cycleLength).
    /// Only set for rounds generated by macro-repeat or range expansion. Rounds sharing
    /// the same non-nil index originate from the same source instruction and can reuse
    /// each other's atomization results.
    var macroRepeatSourceIndex: Int?
    /// Identifier of the expansion group this round belongs to (one UUID per macro-repeat
    /// sentinel or per range sentinel). Only set for rounds generated by expansion.
    /// Atomization results propagate only between rounds sharing the same group — this
    /// prevents cross-contamination when a project contains multiple independent groups
    /// that happen to share a sourceIndex value.
    var macroRepeatGroupID: UUID?

    /// 原子化展开后的实际产出针数（atomicActions 的 producedStitches 求和）。
    /// 与 targetStitchCount 语义区分：target 是 pattern/用户声明的目标，resolved 是本次展开结果。
    var resolvedStitchCount: Int {
        atomicActions.reduce(0) { $0 + $1.producedStitches }
    }
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
    /// Pattern-level abbreviations table extracted from the source (e.g. "cs = cap stitch").
    /// Propagated to the IR prompt so the model can honor author-defined terminology.
    var abbreviations: [PatternAbbreviation]
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

/// Draft structure used by RoundEditorView for manual round editing. Preserves the
/// open-string stitchTag semantics so users can type non-standard pattern abbreviations.
struct RoundActionDraft: Identifiable, Hashable {
    var id: UUID = UUID()
    var semantics: CrochetIROperationSemantics
    var actionTag: String
    var stitchTag: String
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
