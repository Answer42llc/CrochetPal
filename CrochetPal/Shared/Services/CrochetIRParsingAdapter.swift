import Foundation

extension PatternLLMParsing {
    /// Compatibility bridge for tests and older parsing clients.
    /// Implementations that do not yet produce Crochet IR can still return the legacy
    /// segment response; this adapter lifts those segments into IR and lets the new
    /// deterministic compiler own expansion.
    func parseTextRoundsToIR(
        projectTitle: String,
        materials: [String],
        rounds: [AtomizationRoundInput],
        context: ParseRequestContext
    ) async throws -> CrochetIRAtomizationResponse {
        let legacyResponse = try await atomizeTextRounds(
            projectTitle: projectTitle,
            materials: materials,
            rounds: rounds,
            context: context
        )

        let irRounds = zip(rounds, legacyResponse.rounds).map { input, parsedRound in
            CrochetIRInstructionBlock(
                title: input.title,
                sourceText: input.rawInstruction,
                expectedProducedStitches: input.targetStitchCount,
                nodes: parsedRound.segments.map(CrochetIRNode.init(legacySegment:))
            )
        }
        return CrochetIRAtomizationResponse(rounds: irRounds)
    }
}

private extension CrochetIRNode {
    init(legacySegment segment: AtomizedSegment) {
        switch segment {
        case let .stitchRun(stitchRun):
            self = .stitch(CrochetIRStitch(
                type: stitchRun.type,
                count: stitchRun.count,
                instruction: stitchRun.instruction,
                producedStitches: stitchRun.producedStitches,
                note: stitchRun.note,
                notePlacement: stitchRun.notePlacement,
                sourceText: stitchRun.verbatim
            ))
        case let .repeatBlock(repeatSegment):
            self = .repeatBlock(CrochetIRRepeat(
                times: repeatSegment.times,
                body: repeatSegment.sequence.map(CrochetIRNode.init(legacySegment:)),
                sourceText: repeatSegment.verbatim
            ))
        case let .control(control):
            self = .control(CrochetIRControl(
                kind: control.kind,
                instruction: control.instruction,
                note: control.note,
                sourceText: control.verbatim
            ))
        }
    }
}
