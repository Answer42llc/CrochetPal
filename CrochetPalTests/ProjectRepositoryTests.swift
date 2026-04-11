import XCTest
@testable import CrochetPal

@MainActor
final class ProjectRepositoryTests: XCTestCase {
    func testPrepareExecutionAtomizesFirstTwoPendingRounds() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        await repository.prepareExecution(projectID: record.project.id)

        let updated = try XCTUnwrap(repository.records.first)
        let statuses = updated.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(statuses, [.ready, .ready, .pending])
        XCTAssertEqual(importer.atomizeRequestCounts, [2])
    }

    func testPrepareExecutionDoesNotRebootstrapWhenCurrentRoundIsAlreadyReady() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        await repository.prepareExecution(projectID: record.project.id)
        await repository.prepareExecution(projectID: record.project.id)

        let updated = try XCTUnwrap(repository.records.first)
        let statuses = updated.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(statuses, [.ready, .ready, .pending])
        XCTAssertEqual(importer.atomizeRequestCounts, [2])
    }

    func testContinueExecutionAtomizesNextPendingRoundBeforeAdvance() async throws {
        let importer = FakePatternImporter(record: makePendingWebRecord())
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importWebPattern(from: "https://example.com/pattern")
        await repository.prepareExecution(projectID: record.project.id)
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)
        await repository.continueExecution(projectID: record.project.id, source: .phoneButton)

        let updated = try XCTUnwrap(repository.records.first)
        let statuses = updated.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(statuses, [.ready, .ready, .ready])
        XCTAssertEqual(updated.progress.cursor.partID, updated.project.parts[1].id)
        XCTAssertEqual(updated.progress.cursor.roundIndex, 0)
        XCTAssertEqual(updated.progress.cursor.actionIndex, 0)
        XCTAssertEqual(importer.atomizeRequestCounts, [2, 1])
    }

    func testPrepareExecutionAtomizesFirstTwoPendingRoundsForTextProject() async throws {
        let importer = FakePatternImporter(record: makePendingRecord(sourceType: .text))
        let repository = ProjectRepository(
            importer: importer,
            storage: JSONFileStore(directoryURL: tempDirectory()),
            logger: ConsoleTraceLogger()
        )

        let record = try await repository.importTextPattern(from: "Mouse Cat Toy\nRound 1: In a MR, sc 6. (6)")
        await repository.prepareExecution(projectID: record.project.id)

        let updated = try XCTUnwrap(repository.records.first)
        let statuses = updated.project.parts.flatMap(\.rounds).map(\.atomizationStatus)
        XCTAssertEqual(updated.project.source.type, .text)
        XCTAssertEqual(statuses, [.ready, .ready, .pending])
        XCTAssertEqual(importer.atomizeRequestCounts, [2])
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makePendingWebRecord() -> ProjectRecord {
        makePendingRecord(sourceType: .web)
    }

    private func makePendingRecord(sourceType: PatternSourceType) -> ProjectRecord {
        let parts = SampleDataFactory.demoOutlineResponse.parts.map { part in
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
            title: SampleDataFactory.demoOutlineResponse.projectTitle,
            source: PatternSource(
                type: sourceType,
                displayName: sourceType == .text ? "Pasted Pattern" : "Preview",
                sourceURL: sourceType == .web ? "https://example.com/pattern" : nil,
                fileName: nil,
                fileSizeBytes: 128,
                importedAt: .now
            ),
            materials: SampleDataFactory.demoOutlineResponse.materials,
            confidence: SampleDataFactory.demoOutlineResponse.confidence,
            parts: parts,
            activePartID: parts.first?.id,
            createdAt: .now,
            updatedAt: .now
        )

        return ProjectRecord(project: project, progress: .initial(for: project))
    }
}

private final class FakePatternImporter: PatternImporting {
    private let record: ProjectRecord
    private(set) var atomizeRequestCounts: [Int] = []

    init(record: ProjectRecord) {
        self.record = record
    }

    func importWebPattern(from urlString: String) async throws -> ProjectRecord {
        record
    }

    func importImagePattern(data: Data, fileName: String) async throws -> ProjectRecord {
        record
    }

    func importTextPattern(from rawText: String) async throws -> ProjectRecord {
        record
    }

    func atomizeRounds(in project: CrochetProject, targets: [RoundReference]) async throws -> [AtomizedRoundUpdate] {
        atomizeRequestCounts.append(targets.count)
        return targets.map { target in
            AtomizedRoundUpdate(
                reference: target,
                atomicActions: [
                    AtomicAction(type: .sc, instruction: "sc", producedStitches: 1, sequenceIndex: 0)
                ]
            )
        }
    }
}
