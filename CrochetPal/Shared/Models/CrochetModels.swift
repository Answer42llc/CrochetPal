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
    case inc
    case dec
    case ch
    case slSt = "sl_st"
    case blo
    case flo
    case fo
    case hdc
    case dc
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mr: "MR"
        case .sc: "SC"
        case .inc: "Inc"
        case .dec: "Dec"
        case .ch: "CH"
        case .slSt: "Sl St"
        case .blo: "BLO"
        case .flo: "FLO"
        case .fo: "FO"
        case .hdc: "HDC"
        case .dc: "DC"
        case .custom: "Custom"
        }
    }

    var defaultInstruction: String {
        switch self {
        case .mr: "mr"
        case .sc: "sc"
        case .inc: "inc"
        case .dec: "dec"
        case .ch: "ch"
        case .slSt: "sl st"
        case .blo: "blo"
        case .flo: "flo"
        case .fo: "fo"
        case .hdc: "hdc"
        case .dc: "dc"
        case .custom: "custom"
        }
    }

    var defaultProducedStitches: Int {
        switch self {
        case .mr: 0
        case .inc: 2
        case .slSt: 0
        case .dec: 1
        case .fo: 0
        case .ch: 0
        case .custom: 0
        default: 1
        }
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
    var instruction: String
    var producedStitches: Int
    var note: String? = nil
    var sequenceIndex: Int

    var shortDisplay: String {
        if instruction.isEmpty {
            return type.title
        }
        return instruction
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
    var actionHint: String
    var actionNote: String? = nil
    var nextActionTitle: String?
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
    case failed(String)

    var snapshotState: SnapshotExecutionState {
        switch self {
        case .idle:
            return .ready
        case .bootstrapping, .parsingNextRound:
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
            return "正在解析前两圈"
        case .parsingNextRound:
            return "正在解析下一圈"
        case let .failed(message):
            return message
        }
    }

    var canAdvance: Bool {
        switch self {
        case .idle:
            return true
        case .bootstrapping, .parsingNextRound, .failed:
            return false
        }
    }
}
