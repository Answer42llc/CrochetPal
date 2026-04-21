import XCTest
@testable import CrochetPal

@MainActor
final class ExecutionEngineTests: XCTestCase {
    func testForwardStopsAtRoundCompletionBeforeEnteringNextRound() async throws {
        let record = try await makeImageRecord()

        var progress = record.progress
        progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)
        var cursor = cursorState(for: progress)
        XCTAssertEqual(cursor.roundIndex, 0)
        XCTAssertEqual(cursor.actionIndex, 1)

        for _ in 0..<6 {
            progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)
        }

        cursor = cursorState(for: progress)
        XCTAssertEqual(cursor.roundIndex, 0)
        XCTAssertEqual(cursor.actionIndex, 7)
        let isAwaitingNextRound = awaitingNextRound(in: record.project, progress: progress)
        XCTAssertTrue(isAwaitingNextRound)
        XCTAssertNil(completionDate(for: progress))

        progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)

        cursor = cursorState(for: progress)
        XCTAssertEqual(cursor.roundIndex, 1)
        XCTAssertEqual(cursor.actionIndex, 0)
        let enteredNextRound = awaitingNextRound(in: record.project, progress: progress)
        XCTAssertFalse(enteredNextRound)
        XCTAssertNil(completionDate(for: progress))
    }

    func testUndoReturnsToRoundCompletionBeforeLastAction() async throws {
        let record = try await makeImageRecord()
        var progress = record.progress
        for _ in 0..<8 {
            progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)
        }

        let undoneToRoundCompletion = ExecutionEngine.apply(.undo, to: progress, in: record.project, source: .phoneButton)
        var cursor = cursorState(for: undoneToRoundCompletion)
        XCTAssertEqual(cursor.roundIndex, 0)
        XCTAssertEqual(cursor.actionIndex, 7)
        let isAwaitingNextRound = awaitingNextRound(in: record.project, progress: undoneToRoundCompletion)
        XCTAssertTrue(isAwaitingNextRound)
        XCTAssertNil(completionDate(for: undoneToRoundCompletion))

        let undoneToLastAction = ExecutionEngine.apply(.undo, to: undoneToRoundCompletion, in: record.project, source: .phoneButton)
        cursor = cursorState(for: undoneToLastAction)
        XCTAssertEqual(cursor.roundIndex, 0)
        XCTAssertEqual(cursor.actionIndex, 6)
        let returnedToAction = awaitingNextRound(in: record.project, progress: undoneToLastAction)
        XCTAssertFalse(returnedToAction)
        XCTAssertNil(completionDate(for: undoneToLastAction))
    }

    func testSnapshotUsesLoadingStateForPendingWebRound() async throws {
        let record = try await makeWebRecord()
        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .bootstrapping)

        XCTAssertEqual(snapshot.roundTitle, "Round 1")
        XCTAssertEqual(snapshot.actionTitle, "Loading")
        XCTAssertEqual(snapshot.executionState, .loading)
        XCTAssertFalse(snapshot.canAdvance)
    }

    func testProgressFractionFallsBackToRoundProgressWhenPendingRoundsExist() async throws {
        let record = try await makeWebRecord()
        let fraction = ExecutionEngine.progressFraction(for: record)
        XCTAssertEqual(fraction, 0, accuracy: 0.0001)
    }

    func testSnapshotIncludesCurrentActionNote() async throws {
        var record = try await makeImageRecord()
        record.project.parts[0].rounds[0].atomicActions[0].note = "Change to white yarn before this stitch."

        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .idle)

        XCTAssertEqual(snapshot.actionTitle, "MR")
        XCTAssertEqual(snapshot.actionNote, "Change to white yarn before this stitch.")
    }

    func testSnapshotOmitsActionHintWhenInstructionIsNil() async throws {
        var record = try await makeImageRecord()
        record.project.parts[0].rounds[0].atomicActions[0].instruction = nil

        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .idle)

        XCTAssertNil(snapshot.actionHint)
    }

    func testSnapshotUsesFrontPostDoubleCrochetTitleForPostStitchAction() {
        let round = PatternRound(
            title: "Row 5",
            rawInstruction: "fpdc around next st",
            summary: "Work one front post double crochet.",
            targetStitchCount: 1,
            atomizationStatus: .ready,
            atomizationError: nil,
            atomicActions: [
                AtomicAction(semantics: .stitchProducing, actionTag: "fpdc", stitchTag: "fpdc", instruction: "fpdc around next st", producedStitches: 1, note: nil, sequenceIndex: 0)
            ]
        )
        let part = PatternPart(name: "Main", rounds: [round])
        let project = CrochetProject(
            title: "Post Stitch",
            source: PatternSource(
                type: .text,
                displayName: "Post Stitch",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            ),
            materials: [],
            confidence: 1,
            abbreviations: [],
            parts: [part],
            activePartID: part.id,
            createdAt: .now,
            updatedAt: .now
        )
        let record = ProjectRecord(project: project, progress: .initial(for: project))

        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .idle)

        XCTAssertEqual(snapshot.actionTitle, "FPDC")
        XCTAssertEqual(snapshot.actionHint, "fpdc around next st")
    }

    func testSnapshotUsesCustomInstructionAsDisplayTitle() {
        let round = PatternRound(
            title: "Row 1",
            rawInstruction: "turn",
            summary: "Turn the work.",
            targetStitchCount: 0,
            atomizationStatus: .ready,
            atomizationError: nil,
            atomicActions: [
                AtomicAction(semantics: .bookkeeping, actionTag: "custom", stitchTag: nil, instruction: "turn", producedStitches: 0, sequenceIndex: 0)
            ]
        )
        let part = PatternPart(name: "Body", rounds: [round])
        let project = CrochetProject(
            title: "Custom Control",
            source: PatternSource(
                type: .text,
                displayName: "Custom Control",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            ),
            materials: [],
            confidence: 1,
            abbreviations: [],
            parts: [part],
            activePartID: part.id,
            createdAt: .now,
            updatedAt: .now
        )
        let record = ProjectRecord(project: project, progress: .initial(for: project))

        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .idle)

        XCTAssertEqual(snapshot.actionTitle, "turn")
        XCTAssertNil(snapshot.actionHint)
        XCTAssertNil(snapshot.nextActionTitle)
    }

    func testSnapshotDisplaysSkipWithTitleAndHint() {
        let round = PatternRound(
            title: "Row 5",
            rawInstruction: "sk the sc behind the fpdc",
            summary: "Skip stitch behind post stitch.",
            targetStitchCount: 0,
            atomizationStatus: .ready,
            atomizationError: nil,
            atomicActions: [
                AtomicAction(semantics: .bookkeeping, actionTag: "skip", stitchTag: nil, instruction: "skip the sc behind the fpdc you just made", producedStitches: 0, sequenceIndex: 0)
            ]
        )
        let part = PatternPart(name: "Body", rounds: [round])
        let project = CrochetProject(
            title: "Skip Control",
            source: PatternSource(
                type: .text,
                displayName: "Skip Control",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            ),
            materials: [],
            confidence: 1,
            abbreviations: [],
            parts: [part],
            activePartID: part.id,
            createdAt: .now,
            updatedAt: .now
        )
        let record = ProjectRecord(project: project, progress: .initial(for: project))

        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .idle)

        XCTAssertEqual(snapshot.actionTitle, "Skip")
        XCTAssertEqual(snapshot.actionHint, "skip the sc behind the fpdc you just made")
    }

    func testSnapshotTracksProgressWithinRepeatedFoundationChainSequence() {
        var record = makeFoundationChainRecord(chainCount: 114)
        record.progress.cursor.actionIndex = 57

        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .idle)

        XCTAssertEqual(snapshot.actionTitle, "CH")
        XCTAssertEqual(snapshot.actionSequenceProgress, 58)
        XCTAssertEqual(snapshot.actionSequenceTotal, 114)
        XCTAssertEqual(snapshot.stitchProgress, 0)
        XCTAssertEqual(snapshot.targetStitches, 113)
    }

    func testSnapshotOmitsActionSequenceForStandaloneAction() async throws {
        let record = try await makeImageRecord()

        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .idle)

        XCTAssertNil(snapshot.actionSequenceProgress)
        XCTAssertNil(snapshot.actionSequenceTotal)
    }

    func testSnapshotShowsRoundCompletionStateWhilePreparingNextRound() async throws {
        let baseRecord = try await makeImageRecord()
        var progress = baseRecord.progress

        for _ in 0..<7 {
            progress = ExecutionEngine.apply(.forward, to: progress, in: baseRecord.project, source: .phoneButton)
        }

        let record = ProjectRecord(project: baseRecord.project, progress: progress)
        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .parsingNextRound)

        XCTAssertEqual(snapshot.roundTitle, "Round 1")
        XCTAssertEqual(snapshot.actionTitle, "Complete")
        XCTAssertEqual(snapshot.actionHint, "Tap Enter Next Round when you're ready.")
        XCTAssertEqual(snapshot.nextActionTitle, "SC")
        XCTAssertEqual(snapshot.stitchProgress, 6)
        XCTAssertEqual(snapshot.targetStitches, 6)
        XCTAssertEqual(snapshot.executionState, .ready)
        XCTAssertNil(snapshot.statusMessage)
        XCTAssertTrue(snapshot.canAdvance)
    }

    func testForwardCompletesProjectImmediatelyOnFinalRound() async throws {
        let record = try await makeImageRecord()
        var progress = record.progress
        let finalPartID = record.project.parts[1].id
        progress.cursor = ExecutionCursor(
            partID: finalPartID,
            roundIndex: 0,
            actionIndex: 0
        )

        for _ in 0..<7 {
            progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)
        }

        let cursor = cursorState(for: progress)
        XCTAssertEqual(cursor.partID, finalPartID)
        XCTAssertEqual(cursor.roundIndex, 0)
        XCTAssertEqual(cursor.actionIndex, 7)
        XCTAssertNotNil(completionDate(for: progress))
    }

    func testExecutionViewShowsRegenerateButtonForDeferredRound() {
        let round = PatternRound(
            title: "Round 4",
            rawInstruction: "(sc 2, inc) x 3. (12)",
            summary: "Can regenerate.",
            targetStitchCount: 12,
            atomizationStatus: .ready,
            atomizationError: nil,
            atomicActions: [
                AtomicAction(semantics: .stitchProducing, actionTag: "sc", stitchTag: "sc", instruction: "sc", producedStitches: 1, sequenceIndex: 0)
            ]
        )

        XCTAssertTrue(
            ExecutionView.shouldShowRegenerateButton(
                sourceType: .web,
                round: round
            )
        )
    }

    func testExecutionViewHidesRegenerateButtonForImageRound() {
        let round = PatternRound(
            title: "Round 4",
            rawInstruction: "(sc 2, inc) x 3. (12)",
            summary: "Image projects do not support regeneration.",
            targetStitchCount: 12,
            atomizationStatus: .ready,
            atomizationError: nil,
            atomicActions: [
                AtomicAction(semantics: .stitchProducing, actionTag: "sc", stitchTag: "sc", instruction: "sc", producedStitches: 1, sequenceIndex: 0)
            ]
        )

        XCTAssertFalse(
            ExecutionView.shouldShowRegenerateButton(
                sourceType: .image,
                round: round
            )
        )
    }

    private func makeImageRecord() async throws -> ProjectRecord {
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                irResponse: SampleDataFactory.demoIRAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            logger: ConsoleTraceLogger()
        )
        return try await importer.importImagePattern(data: SampleDataFactory.sampleImageData, fileName: "sample.png")
    }

    private func makeWebRecord() async throws -> ProjectRecord {
        let session = URLSession(configuration: .ephemeral)
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                irResponse: SampleDataFactory.demoIRAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            session: session,
            logger: ConsoleTraceLogger()
        )
        return importer.makePreviewWebRecord()
    }

    private func makeFoundationChainRecord(chainCount: Int) -> ProjectRecord {
        let part = PatternPart(
            name: "Main",
            rounds: [
                PatternRound(
                    title: "Row 1",
                    rawInstruction: "Chain \(chainCount), then single crochet in the second chain from hook and each chain across.",
                    summary: "Chain \(chainCount), then single crochet in the second chain from hook and each chain across.",
                    targetStitchCount: max(chainCount - 1, 0),
                    atomizationStatus: .ready,
                    atomizationError: nil,
                    atomicActions: makeFoundationChainActions(chainCount: chainCount)
                )
            ]
        )
        let project = CrochetProject(
            title: "Quiet Tides Baby Blanket",
            source: PatternSource(
                type: .text,
                displayName: "Preview",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            ),
            materials: [],
            confidence: 1,
            abbreviations: [],
            parts: [part],
            activePartID: part.id,
            createdAt: .now,
            updatedAt: .now
        )
        return ProjectRecord(project: project, progress: .initial(for: project))
    }

    private func makeFoundationChainActions(chainCount: Int) -> [AtomicAction] {
        let chains = (0..<chainCount).map { index in
            AtomicAction(semantics: .stitchProducing, actionTag: "ch", stitchTag: "ch", instruction: "ch", producedStitches: 0, sequenceIndex: index)
        }
        let singleCrochets = (0..<max(chainCount - 1, 0)).map { offset in
            let sequenceIndex = chainCount + offset
            return AtomicAction(semantics: .stitchProducing, actionTag: "sc", stitchTag: "sc", instruction: "sc", producedStitches: 1, sequenceIndex: sequenceIndex)
        }
        return chains + singleCrochets
    }

    // Regression for the Round 7 "Complete + 0/0 + Next: SC" bug. When the LLM atomizes
    // a round but produces zero atomic actions (e.g. wraps every stitch in
    // note(emitAsAction=false), or packs the whole round into a single ambiguous node —
    // see docs/bad-cases/round7-mouse-cat-toy-notes-swallow-all.md), the round is marked
    // .ready with atomicActions == []. The engine must NOT treat this as "awaiting next
    // round"; otherwise the user is silently carried past the round without doing anything
    // and the declared target stitch count disappears from the UI.
    func testIsAwaitingNextRoundIsFalseForReadyRoundWithEmptyAtomicActions() {
        let emptyRound = PatternRound(
            title: "Round 7",
            rawInstruction: "sc (both loops), bend first ear forward ...",
            summary: "",
            targetStitchCount: 12,
            atomizationStatus: .ready,
            atomizationError: nil,
            atomizationWarning: "atomization_target_stitch_count_mismatch",
            atomicActions: []
        )
        let followUpRound = PatternRound(
            title: "Round 8",
            rawInstruction: "sc 12.",
            summary: "",
            targetStitchCount: 12,
            atomizationStatus: .ready,
            atomizationError: nil,
            atomicActions: [
                AtomicAction(semantics: .stitchProducing, actionTag: "sc", stitchTag: "sc", instruction: "sc", producedStitches: 1, sequenceIndex: 0)
            ]
        )
        let part = PatternPart(name: "Body", rounds: [emptyRound, followUpRound])
        let project = CrochetProject(
            title: "Empty Round Repro",
            source: PatternSource(
                type: .text,
                displayName: "Empty",
                sourceURL: nil,
                fileName: nil,
                fileSizeBytes: nil,
                importedAt: .now
            ),
            materials: [],
            confidence: 1,
            abbreviations: [],
            parts: [part],
            activePartID: part.id,
            createdAt: .now,
            updatedAt: .now
        )
        let record = ProjectRecord(project: project, progress: .initial(for: project))

        XCTAssertFalse(
            ExecutionEngine.isAwaitingNextRound(in: record.project, progress: record.progress),
            "A .ready round with empty atomicActions must not be treated as awaiting next round."
        )

        let snapshot = ExecutionEngine.snapshot(for: record, executionState: .idle)
        XCTAssertNotEqual(
            snapshot.actionTitle, "Complete",
            "Empty-action round must not surface the 'Complete' title."
        )
        XCTAssertFalse(
            snapshot.canAdvance,
            "User must not be able to silently skip an empty-action round."
        )
        XCTAssertEqual(
            snapshot.targetStitches, 12,
            "The declared targetStitchCount must still be visible to the user."
        )
    }

    private func cursorState(for progress: ExecutionProgress) -> (partID: UUID, roundIndex: Int, actionIndex: Int) {
        let cursor = progress.cursor
        return (cursor.partID, cursor.roundIndex, cursor.actionIndex)
    }

    private func completionDate(for progress: ExecutionProgress) -> Date? {
        progress.completedAt
    }

    private func awaitingNextRound(in project: CrochetProject, progress: ExecutionProgress) -> Bool {
        ExecutionEngine.isAwaitingNextRound(in: project, progress: progress)
    }
}

private extension PatternImportService {
    func makePreviewWebRecord() -> ProjectRecord {
        makePreviewWebRecord(
            from: SampleDataFactory.demoOutlineResponse,
            source: PatternSource(
                type: .web,
                displayName: "Preview",
                sourceURL: "https://example.com/pattern",
                fileName: nil,
                fileSizeBytes: 100,
                importedAt: .now
            )
        )
    }

    func makePreviewWebRecord(from payload: PatternOutlineResponse, source: PatternSource) -> ProjectRecord {
        let parts = payload.parts.map { part in
            PatternPart(
                name: part.name,
                rounds: part.rounds.map { round in
                    PatternRound(
                        title: round.title,
                        rawInstruction: round.rawInstruction,
                        summary: round.summary,
                        targetStitchCount: round.targetStitchCount,
                        atomizationStatus: .pending,
                        atomizationError: nil,
                        atomicActions: []
                    )
                }
            )
        }

        let project = CrochetProject(
            title: payload.projectTitle,
            source: source,
            materials: payload.materials,
            confidence: payload.confidence,
            abbreviations: [],
            parts: parts,
            activePartID: parts.first?.id,
            createdAt: .now,
            updatedAt: .now
        )
        return ProjectRecord(project: project, progress: .initial(for: project))
    }
}
