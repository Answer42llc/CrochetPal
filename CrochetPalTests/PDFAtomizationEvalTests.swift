import XCTest
@testable import CrochetPal

/// 端到端验证 PDF 提取质量对下游原子化的影响。
///
/// **用法**：
/// 1. 先跑 `/tmp/pdf_eval/extract_pdfs.swift` 生成 `/tmp/pdf_eval/hybrid/*.txt`。
/// 2. 在 Xcode Scheme 的环境变量里设置 `RUN_PDF_ATOMIZATION_EVAL=1`。
/// 3. 在 `Config/Secrets.xcconfig` 或 Scheme 环境变量里配好 OPENAI_API_KEY 等。
/// 4. 运行 `testAtomizeAllHybridExtractions`，结果写到 `/tmp/pdf_eval/atomization/`。
///
/// 输出：每份 `.txt` 产出一份 `.json`（包含 Project + 所有 round 的原子化结果）
/// 或 `.error.json`（失败）。之后可交给 Opus 4.7 subagent 做统一评估。
@MainActor
final class PDFAtomizationEvalTests: XCTestCase {

    private static let inputDir = "/tmp/pdf_eval/hybrid"
    private static let outputDir = "/tmp/pdf_eval/atomization"

    /// 采样：只跑这 5 份覆盖典型失败模式的 PDF。减少跑时。
    /// 来自 15 份综合评估后挑选的代表性案例。
    private static let sampledBaseNames: Set<String> = [
        "Worry_Worm_-_a_Bluebell_Moon_Crochet_Pattern_1",      // 扫描型，OCR 主导
        "Evergranny_Tote_Bags_Crochet_Pattern_by_Kami_Crochet", // 字内碎片
        "Mochi_Bear_Crochet_Pattern_",                          // 多列 + 干净 textLayer
        "Dragon_Scale_Gloves_Adult_pattern_v2",                 // 干净、复合针法
        "Huawei__Freebods__airpod_case"                         // 多列小字、关键数字
    ]

    override func setUp() {
        super.setUp()
        // 放宽 XCTest 对单个测试方法的时间上限；否则默认上限在 LLM 多分钟响应下会被触发。
        executionTimeAllowance = 1800 // 30 min per test method
    }

    // 每份 PDF 一个测试方法，隔离失败、避免单方法运行过长。
    func test01_DragonScaleGloves() async throws {
        try await runAtomizationEval(baseName: "Dragon_Scale_Gloves_Adult_pattern_v2")
    }

    func test02_HuaweiAirpodCase() async throws {
        try await runAtomizationEval(baseName: "Huawei__Freebods__airpod_case")
    }

    func test03_WorryWorm() async throws {
        try await runAtomizationEval(baseName: "Worry_Worm_-_a_Bluebell_Moon_Crochet_Pattern_1")
    }

    func test04_EvergrannyTote() async throws {
        try await runAtomizationEval(baseName: "Evergranny_Tote_Bags_Crochet_Pattern_by_Kami_Crochet")
    }

    func test05_MochiBear() async throws {
        try await runAtomizationEval(baseName: "Mochi_Bear_Crochet_Pattern_")
    }

    // MARK: - 共享的单份运行逻辑

    private func runAtomizationEval(baseName: String) async throws {
        // 触发文件：`touch /tmp/run-pdf-atomize-eval` 之后跑才会执行。
        guard FileManager.default.fileExists(atPath: "/tmp/run-pdf-atomize-eval") else {
            throw XCTSkip("执行 `touch /tmp/run-pdf-atomize-eval` 后才运行。")
        }
        let configuration: RuntimeConfiguration
        do {
            configuration = try RuntimeConfiguration.load()
        } catch {
            throw XCTSkip("缺少 LLM 配置（OPENAI_API_KEY 等），跳过。错误：\(error.localizedDescription)")
        }
        let logger = StdoutTraceLogger()
        let client = OpenAICompatibleLLMClient(configuration: configuration, logger: logger)
        let importer = PatternImportService(
            parserClient: client,
            extractor: HTMLExtractionService(),
            pdfExtractor: PDFExtractionService(),
            logger: logger
        )

        try? FileManager.default.createDirectory(
            atPath: Self.outputDir,
            withIntermediateDirectories: true
        )

        let file = "\(baseName).txt"
        let inputPath = "\(Self.inputDir)/\(file)"
        guard FileManager.default.fileExists(atPath: inputPath) else {
            XCTFail("缺少输入文件：\(inputPath)")
            return
        }
        print("\n===== Processing \(baseName) =====")
        let text = try String(contentsOfFile: inputPath, encoding: .utf8)

        // Heartbeat：每 10 秒打印一行，避免 XCTest 认为测试 hang 而重启。
        let heartbeat = Task.detached { [baseName] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                ticks += 10
                print("  [\(baseName)] heartbeat \(ticks)s")
            }
        }
        defer { heartbeat.cancel() }

        let started = Date()
        do {
            let record = try await importer.importTextPattern(from: text)
            let targets: [RoundReference] = record.project.parts.flatMap { part in
                part.rounds.map { round in
                    RoundReference(partID: part.id, roundID: round.id)
                }
            }
            let updates: [AtomizedRoundUpdate]
            if targets.isEmpty {
                updates = []
            } else {
                updates = try await importer.atomizeRounds(in: record.project, targets: targets)
            }
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            let partsCount = record.project.parts.count
            let roundsCount = record.project.parts.flatMap(\.rounds).count
            print("  [OK] parts=\(partsCount) rounds=\(roundsCount) atomized=\(updates.count) duration=\(duration)ms")

            try writeSuccessOutput(
                baseName: baseName,
                file: file,
                record: record,
                updates: updates,
                durationMS: duration
            )
        } catch {
            let duration = Int(Date().timeIntervalSince(started) * 1000)
            print("  [FAIL] \(error) duration=\(duration)ms")
            writeErrorOutput(baseName: baseName, file: file, error: error, durationMS: duration)
            throw error
        }
    }

    // MARK: - Output writers

    private func writeSuccessOutput(
        baseName: String,
        file: String,
        record: ProjectRecord,
        updates: [AtomizedRoundUpdate],
        durationMS: Int
    ) throws {
        // Build a diagnostic structure by matching updates back to their rounds.
        var roundDiagnostics: [RoundDiagnostic] = []
        for part in record.project.parts {
            for round in part.rounds {
                let reference = RoundReference(partID: part.id, roundID: round.id)
                let update = updates.first(where: { $0.reference == reference })
                roundDiagnostics.append(RoundDiagnostic(
                    partName: part.name,
                    roundTitle: round.title,
                    rawInstruction: round.rawInstruction,
                    summary: round.summary,
                    declaredTargetStitchCount: round.targetStitchCount,
                    status: roundStatus(round.atomizationStatus),
                    atomicActions: (update?.atomicActions ?? round.atomicActions).map { action in
                        AtomicActionSummary(
                            type: action.stitchTag ?? action.actionTag,
                            instruction: action.instruction ?? "",
                            producedStitches: action.producedStitches
                        )
                    },
                    producedStitchCount: update?.producedStitchCount ?? round.resolvedStitchCount,
                    warning: update?.warning
                ))
            }
        }

        let summary = ProjectSummary(
            title: record.project.title,
            materials: record.project.materials,
            parts: record.project.parts.map { part in
                PartSummary(
                    name: part.name,
                    roundCount: part.rounds.count
                )
            }
        )

        let encodable = EvalResult(
            file: file,
            status: "success",
            durationMS: durationMS,
            summary: summary,
            rounds: roundDiagnostics,
            error: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(encodable)
        try data.write(to: URL(fileURLWithPath: "\(Self.outputDir)/\(baseName).json"))
    }

    private func writeErrorOutput(
        baseName: String,
        file: String,
        error: Error,
        durationMS: Int
    ) {
        let encodable = EvalResult(
            file: file,
            status: "failed",
            durationMS: durationMS,
            summary: nil,
            rounds: [],
            error: String(describing: error)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(encodable) {
            try? data.write(to: URL(fileURLWithPath: "\(Self.outputDir)/\(baseName).error.json"))
        }
    }

    private func roundStatus(_ status: RoundAtomizationStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

// MARK: - Diagnostic value types

private struct EvalResult: Encodable {
    var file: String
    var status: String
    var durationMS: Int
    var summary: ProjectSummary?
    var rounds: [RoundDiagnostic]
    var error: String?
}

private struct ProjectSummary: Encodable {
    var title: String
    var materials: [String]
    var parts: [PartSummary]
}

private struct PartSummary: Encodable {
    var name: String
    var roundCount: Int
}

private struct RoundDiagnostic: Encodable {
    var partName: String
    var roundTitle: String
    var rawInstruction: String
    var summary: String?
    var declaredTargetStitchCount: Int?
    var status: String
    var atomicActions: [AtomicActionSummary]
    var producedStitchCount: Int
    var warning: String?
}

private struct AtomicActionSummary: Encodable {
    var type: String
    var instruction: String
    var producedStitches: Int
}

/// 测试专用 logger：把 LogEvent 关键字段打到 stdout，便于从 xcodebuild 输出里观察进度。
/// 对 llm_response_payload 事件额外把 assistantContent 写到 /tmp/pdf_eval/raw_responses/ 以便审查。
private struct StdoutTraceLogger: TraceLogging {
    func log(_ event: LogEvent) {
        var parts: [String] = []
        parts.append("[\(event.level)] \(event.stage)/\(event.decision)")
        if !event.reason.isEmpty {
            parts.append(":: \(event.reason)")
        }
        if let d = event.durationMS {
            parts.append("(\(d)ms)")
        }
        print(parts.joined(separator: " "))

        // 对 llm_response_payload 写入原始响应内容到文件，便于事后审查。
        if event.stage == "llm_response_payload",
           let content = event.metadata["assistantContent"] {
            let dir = "/tmp/pdf_eval/raw_responses"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            let filename = "\(dir)/\(ts)_\(event.decision).txt"
            try? content.write(toFile: filename, atomically: true, encoding: .utf8)
            print("  [raw-dump] \(event.decision) → \(filename) (bytes=\(content.count))")
        }
    }
}
