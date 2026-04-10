import XCTest
@testable import CrochetPal

final class ExecutionEngineTests: XCTestCase {
    func testForwardAdvancesAcrossReadyRounds() async throws {
        let record = try await makeImageRecord()

        var progress = record.progress
        progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)
        XCTAssertEqual(progress.cursor.roundIndex, 0)
        XCTAssertEqual(progress.cursor.actionIndex, 1)

        for _ in 0..<6 {
            progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)
        }

        XCTAssertEqual(progress.cursor.roundIndex, 1)
        XCTAssertEqual(progress.cursor.actionIndex, 0)
        XCTAssertNil(progress.completedAt)
    }

    func testUndoReturnsToPreviousCursor() async throws {
        let record = try await makeImageRecord()
        var progress = record.progress
        progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)
        progress = ExecutionEngine.apply(.forward, to: progress, in: record.project, source: .phoneButton)

        let undone = ExecutionEngine.apply(.undo, to: progress, in: record.project, source: .phoneButton)
        XCTAssertEqual(undone.cursor.actionIndex, 1)
        XCTAssertNil(undone.completedAt)
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

    func testExecutionViewShowsRetryButtonWhenCurrentRoundFailedEvenIfExecutionStateIsIdle() {
        let round = PatternRound(
            title: "Round 4",
            rawInstruction: "(sc 2, inc) x 3. (12)",
            summary: "Retry needed.",
            targetStitchCount: 12,
            atomizationStatus: .failed,
            atomizationError: "The network connection was lost.",
            atomicActions: []
        )

        XCTAssertTrue(
            ExecutionView.shouldShowRetryButton(
                executionState: .idle,
                round: round
            )
        )
    }

    func testExecutionViewHidesRetryButtonForReadyRoundInIdleState() {
        let round = PatternRound(
            title: "Round 4",
            rawInstruction: "(sc 2, inc) x 3. (12)",
            summary: "No retry needed.",
            targetStitchCount: 12,
            atomizationStatus: .ready,
            atomizationError: nil,
            atomicActions: [
                AtomicAction(type: .sc, instruction: "sc", producedStitches: 1, sequenceIndex: 0)
            ]
        )

        XCTAssertFalse(
            ExecutionView.shouldShowRetryButton(
                executionState: .idle,
                round: round
            )
        )
    }

    private func makeImageRecord() async throws -> ProjectRecord {
        let importer = PatternImportService(
            parserClient: FixturePatternParsingClient(
                outlineResponse: SampleDataFactory.demoOutlineResponse,
                imageResponse: SampleDataFactory.demoImageParseResponse,
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
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
                atomizationResponse: SampleDataFactory.demoAtomizationResponse
            ),
            extractor: HTMLExtractionService(),
            session: session,
            logger: ConsoleTraceLogger()
        )
        return importer.makePreviewWebRecord()
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
            parts: parts,
            activePartID: parts.first?.id,
            createdAt: .now,
            updatedAt: .now
        )
        return ProjectRecord(project: project, progress: .initial(for: project))
    }
}
