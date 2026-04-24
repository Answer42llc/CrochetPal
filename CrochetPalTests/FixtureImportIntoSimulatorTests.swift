import XCTest
@testable import CrochetPal

/// 可选的导入测试：读取 CrochetPalTests/Fixtures/LLM/ 下的全部 fixture，
/// 直接写入 CrochetPal App 的沙盒 `projects.json`。启动模拟器上的 App
/// 即可看到全部 12 个 fixture 的解析结果。
///
/// 使用方式（iPhone 17 Pro 模拟器示例）：
/// ```
/// touch /tmp/crochetpal-import-fixtures
/// xcodebuild test -project CrochetPal.xcodeproj -scheme CrochetPal \
///   -destination 'platform=iOS Simulator,id=D0C11D1A-A7FA-43EE-9D30-C3E99CB15AAB' \
///   -only-testing:CrochetPalTests/FixtureImportIntoSimulatorTests/testImportAllFixtures
/// rm /tmp/crochetpal-import-fixtures
/// ```
///
/// 没有触发文件 `/tmp/crochetpal-import-fixtures` 时，测试会 skip，
/// 不会影响日常全量测试（用文件而非环境变量作为开关——xcodebuild 不会
/// 把外部 shell env 传入模拟器内的测试进程，但 iOS Simulator 共享
/// macOS 文件系统，可以直接读到 /tmp）。
final class FixtureImportIntoSimulatorTests: XCTestCase {

    // MARK: - Fixture JSON schemas

    private struct FixtureManifest: Codable {
        var fixtures: [Entry]

        struct Entry: Codable {
            var name: String
            var title: String
            var sourceType: String
            var sourceFiles: [String]?
            var sourceURL: String?
        }
    }

    private struct AtomicRoundsFile: Codable {
        var rounds: [AtomicRound]
    }

    private struct AtomicRound: Codable {
        var title: String
        var sourceText: String
        var expectedProducedStitches: Int?
        var producedStitchCount: Int?
        var actions: [AtomicActionSnapshot]
    }

    private struct AtomicActionSnapshot: Codable {
        var semantics: CrochetIROperationSemantics
        var actionTag: String
        var stitchTag: String?
        var instruction: String?
        var producedStitches: Int
        var note: String?
        var sourceText: String?
        var sequenceIndex: Int
    }

    // MARK: - Test

    private static let triggerFilePath = "/tmp/crochetpal-import-fixtures"

    func testImportAllFixtures() throws {
        guard FileManager.default.fileExists(atPath: Self.triggerFilePath) else {
            throw XCTSkip("Touch \(Self.triggerFilePath) to import LLM fixtures into the app sandbox")
        }

        let manifest = try loadManifest()
        XCTAssertFalse(manifest.fixtures.isEmpty, "fixture manifest is empty")

        var records: [ProjectRecord] = []
        for entry in manifest.fixtures {
            let record = try buildRecord(for: entry)
            records.append(record)
        }

        let store = JSONFileStore()
        try store.save(records, to: "projects.json")

        let sandbox = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        print("[FixtureImport] wrote \(records.count) projects to \(sandbox.appendingPathComponent("projects.json").path)")
    }

    // MARK: - Builders

    private func loadManifest() throws -> FixtureManifest {
        let url = fixtureURL("Fixtures/LLM/fixture_manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureManifest.self, from: data)
    }

    private func buildRecord(for entry: FixtureManifest.Entry) throws -> ProjectRecord {
        let dir = "Fixtures/LLM/\(entry.name)"
        let outlineURL = fixtureURL("\(dir)/outline.json")
        let atomicURL = fixtureURL("\(dir)/atomic_rounds.json")

        let outlineData = try Data(contentsOf: outlineURL)
        let outline = try JSONDecoder().decode(PatternOutlineResponse.self, from: outlineData)

        let atomicData = try Data(contentsOf: atomicURL)
        let atomic = try JSONDecoder().decode(AtomicRoundsFile.self, from: atomicData)

        let flatOutlineCount = outline.parts.reduce(0) { $0 + $1.rounds.count }
        XCTAssertEqual(
            flatOutlineCount, atomic.rounds.count,
            "[\(entry.name)] outline round count (\(flatOutlineCount)) != atomic round count (\(atomic.rounds.count))"
        )

        var atomicIndex = 0
        let parts: [PatternPart] = outline.parts.map { oPart in
            let rounds: [PatternRound] = oPart.rounds.map { oRound in
                let atomicRound = atomicIndex < atomic.rounds.count ? atomic.rounds[atomicIndex] : nil
                atomicIndex += 1

                let actions: [AtomicAction] = (atomicRound?.actions ?? []).map { snapshot in
                    AtomicAction(
                        semantics: snapshot.semantics,
                        actionTag: snapshot.actionTag,
                        stitchTag: snapshot.stitchTag,
                        instruction: snapshot.instruction,
                        producedStitches: snapshot.producedStitches,
                        note: snapshot.note,
                        sourceText: snapshot.sourceText,
                        sequenceIndex: snapshot.sequenceIndex
                    )
                }

                let status: RoundAtomizationStatus = actions.isEmpty ? .failed : .ready
                let error: String? = actions.isEmpty ? "atomization produced no actions" : nil

                return PatternRound(
                    title: oRound.title,
                    rawInstruction: oRound.rawInstruction,
                    summary: oRound.summary,
                    targetStitchCount: oRound.targetStitchCount,
                    atomizationStatus: status,
                    atomizationError: error,
                    atomizationWarning: nil,
                    atomicActions: actions,
                    macroRepeatSourceIndex: nil,
                    macroRepeatGroupID: nil
                )
            }
            return PatternPart(name: oPart.name, rounds: rounds)
        }

        let sourceType: PatternSourceType
        switch entry.sourceType.lowercased() {
        case "web": sourceType = .web
        case "image": sourceType = .image
        default: sourceType = .text
        }

        let source = PatternSource(
            type: sourceType,
            displayName: entry.title,
            sourceURL: entry.sourceURL,
            fileName: entry.sourceFiles?.first,
            fileSizeBytes: nil,
            importedAt: Date()
        )

        let now = Date()
        let project = CrochetProject(
            title: entry.title,
            source: source,
            materials: outline.materials,
            confidence: outline.confidence,
            abbreviations: outline.abbreviations,
            parts: parts,
            activePartID: parts.first?.id,
            createdAt: now,
            updatedAt: now
        )
        let progress = ExecutionProgress.initial(for: project)
        return ProjectRecord(project: project, progress: progress)
    }

    // MARK: - Helpers

    private func fixtureURL(_ relativePath: String, file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
