import XCTest
@testable import CrochetPal

/// 调试 LLM 原子化提示词的测试。
///
/// 使用方式：
/// 1. 在 `Config/Secrets.xcconfig` 或 Scheme 环境变量里配好：
///    `OPENAI_API_KEY`、`OPENAI_BASE_URL`、`TEXT_MODEL_ID`、`VISION_MODEL_ID`
///    （可选 `ATOMIZATION_MODEL_ID`，未设置时会回退到 `TEXT_MODEL_ID`）。
/// 2. 直接修改下面 `debugSystemPrompt` / `debugUserPrompt` 等字符串常量来调试提示词。
///    用 `atomizeTextRoundsWithCustomPrompts` 发请求，绕开 `PromptFactory`。
/// 3. 在 Xcode Test Navigator 中单独运行本文件中的某个测试方法。
/// 4. Test Report 控制台里查看打印出来的原始 JSON 结果，
///    对照 `bad_case.md` 的期望行为判断提示词改动是否生效。
///
/// 说明：直接命中真实 LLM，没有 Mock。未配置 API Key 时会自动 `XCTSkip`。
///
/// 输出结构：继续走生产的 `PromptFactory.atomizationResponseFormat()`（rounds/segments），
/// 本文件的 `debugSystemPrompt()` = 生产版 system prompt + 新模板里真正有增量价值的规则段
/// （Repeat Count Convention、omit/instead 修饰词处理、前置实例 + "repeat N times" 的计数等）。
/// 目的：保留原有输出形状，只强化模型对 bad_case.md 里那类修饰语的处理能力。
@MainActor
final class LLMAtomizationDebugTests: XCTestCase {

    // MARK: - ✏️ 模型与推理参数（可直接在这里修改）

    /// 覆盖使用的模型 ID。
    /// 传 `nil` 使用 `RuntimeConfiguration.atomizationModelID`（即 Secrets.xcconfig 里配置的值）。
    /// 例：`"openai/gpt-4o"` / `"anthropic/claude-opus-4-7"` / `"openai/o3-mini"` 等。
    private static let overrideModelID: String? = "deepseek/deepseek-v3.2"

    /// 覆盖 reasoning 配置。OpenRouter 的 `effort` 档位和 `max_tokens` 预算是二选一：
    /// - `.effort("low" / "medium" / "high")` 档位式
    /// - `.maxTokens(N)` 指定可用于推理的最大 token 数
    /// - `.disabled` 请求里不附带 `reasoning` 字段（适用于不支持推理的模型或想走默认行为）
    private static let overrideReasoning: AtomizationReasoningConfig = .disabled

    // MARK: - ✏️ System 提示词（可直接在这里修改）

    /// 基于生产版 `PromptFactory.roundAtomizationSystemPrompt()`，在尾部追加新模板里真正
    /// 对 bad_case.md 有帮助的增量规则。输出 schema 仍然是生产版的 rounds/segments。
    ///
    /// 追加的核心规则：
    /// 1. Repeat Count Convention —— "[X] repeat N times" 前面已经写过一遍时，总次数 = N+1。
    /// 2. Repeat Modifications —— "omit the final X, instead work Y" 这类末尾替换的落地方式。
    /// 3. Round-Start ch3 —— "Ch3 (count as 1dc), 1dc in same st" 如何处理起头和首个 dc inc。
    /// 4. Wolf Granny Square 原例 —— 显式给模型一个完整 golden case，防止它再次输出"重复 3
    ///    次 + 追加 ch3"这种错误展开。
    private static func debugSystemPrompt() -> String {
        
        let supportedTypes = CrochetTermDictionary.supportedAtomicActionTypes
            .map(\.rawValue)
            .joined(separator: ", ")
        let controlKinds = ControlSegmentKind.allCases.map(\.rawValue).joined(separator: ", ")

        return """
        You are a crochet master. Convert each crochet round into structured summary segments that a deterministic program can expand into final atomic actions.
        Segment kinds:
        - stitchRun: one stitch type repeated count times
        - repeat: a repeated sequence of segments
        - control: a non-stitch control action such as turning the work
        
        You MUST work following the steps:
        

        Rules:
        - Return one JSON object only.
        - rawInstruction is the source of truth. Use summary only to improve note clarity.
        - Each input round represents exactly one round of work. The title field identifies which single round it is. If rawInstruction still contains a multi-round range prefix like "Rounds 9-10", treat the instruction body as applying to just this single round — do not wrap it in a repeat segment for the number of rounds in the range. The range notation means the same instruction was used for multiple consecutive rounds, each sent to you independently.
        - stitchRun.type must be exactly one enum value from this list: \(supportedTypes).
        - control.kind must be exactly one enum value from this list: \(controlKinds).
        - Never use custom or control as an escape hatch for stitch-like content.
        - Never output descriptive terms such as blo, flo, front loop only, back loop only, or color-change text as stitchRun.type.
        - Never output natural-language stitch names such as "magic loop", "magic ring", "slip stitch", or "fasten off" as stitchRun.type.
        - Do not collapse derived stitch abbreviations into their base stitch. For example, fpdc must stay fpdc, not dc with a "front post" note.
        - Compress consecutive identical stitches into one stitchRun. "7sc" must become one stitchRun with type sc and count 7.
        - Use repeat when the source expresses repeated structure. "(sc 2, inc) x 3" should become one repeat segment whose sequence is [sc x2, inc x1] and whose times is 3.
        - Only use repeat kind when the source contains an explicit repetition count (×3, x3, "3 times", "4x", etc.). A parenthesized or bracketed stitch group WITHOUT a ×N suffix is NOT a repeat — it means multiple stitches worked into the same stitch or stitch space. Common non-repeat groups: "(hdc, 2 dc, hdc)" (ear/peak into one st), "(3 dc in same st)" (shell/fan), "[dc, ch 1, dc] in corner" (V-stitch), "(yo, insert, pull up loop)" technique descriptions. Expand these as consecutive stitchRun segments with notes indicating they share the same stitch. If the source contains specific instructions regarding a particular repetition, such as changes in the procedure or adjustments in dosage, separate this repetition from those that come before or after it in the output.
        - times must always be a concrete positive integer when kind=repeat. Never output kind=repeat with times=null. If you cannot determine a concrete integer for times, do not use kind=repeat — flatten the contents as individual stitchRun segments instead.
        - Preserve the original stitch order after expansion.
        - stitchRun.note must be short, readable context. Use notePlacement to say whether the note applies to the first stitch, last stitch, or every stitch in that run.
        - For stitchRun, notePlacement must never be null. If stitchRun.note is null, use notePlacement=first as the default placeholder.
        - Use notePlacement=first for leading placement guidance such as "in the 2nd ch from the hook".
        - Use notePlacement=last for trailing follow-up guidance such as "change color".
        - Use notePlacement=all for context that applies to the whole run such as yarn color or FLO/BLO placement.
        - For stitchRun, producedStitches must be null. The app already calculates stitch contribution from stitchRun.type.
        - Every segment object must include every schema key. When a field does not apply to that segment kind, set it to null instead of omitting it.
        - Contextual modifiers such as color, loop placement, round references, and placement guidance should stay in note, not control.
        - control is only for standalone control steps that should remain separate after expansion, such as turn or skip (skipping one or more stitches).
        - If control.kind is custom, instruction must contain the exact control wording to preserve.
        - Instruction-only rounds (rounds with no stitch content, such as "Add stuffing" or "Finish off and sew closed") must produce exactly one control segment with kind=custom. The instruction field must contain the full instruction text.
        - Only include instruction when the default instruction would be misleading.
        - Every segment must include verbatim with the exact source snippet that the segment came from.
        - previousRoundStitchCount tells you how many stitches are available to work into from the previous round. It is a hard physical constraint — you cannot work into stitches that do not exist.
        - ALWAYS use previousRoundStitchCount (when provided) to verify and correct explicit repeat counts. This applies regardless of whether targetStitchCount is null or not. When targetStitchCount is null, previousRoundStitchCount is the ONLY available constraint and becomes even more critical.
        - Conflict resolution: calculate consumedPerRepeat (sum of stitches each action consumes). If previousRoundStitchCount / consumedPerRepeat gives an integer that differs from the explicit repeat count, use previousRoundStitchCount / consumedPerRepeat. This rule applies whether targetStitchCount is present or null.
        - For "around" instructions (e.g., "sc around", "dc around") with no explicit count: when previousRoundStitchCount is provided, the count equals previousRoundStitchCount (one stitch per available stitch from the previous round).

        Repeat uniformity rule (HARD):
        - A `repeat` segment means every one of the N iterations is IDENTICAL. If the source text says that one or more specific iterations differ from the others — e.g. "omit the final X", "instead work Y", "except on the last repeat", "the first time …", "on the 3rd repeat …", or any other per-iteration exception — you MUST NOT use a single `repeat(times=N)` segment. Flatten it instead.
        - Flattening procedure: emit each iteration as its own independent sequence of stitchRun/control segments, in order, writing out the full body every time. For the iterations that differ, replace/add/remove segments exactly as the source describes. Do not combine the "normal" iterations into a smaller `repeat` while dangling the different iteration outside — just flatten all N iterations. (You may still use `repeat` for truly identical sub-structures that sit inside one iteration.)
        - When the exception is "omit the final X" or "instead of the last X, do Y", the last flattened iteration must reflect exactly that: drop X and append Y. Do NOT first emit a full repeat and then append Y after it — that double-counts X.
        """
    }

    // MARK: - ✏️ User 提示词构造（可直接在这里修改）

    /// 把我们现有的 `AtomizationRoundInput` 数据填入模板结尾的 `<input>...</input>`。
    /// 模板一次只处理一个 round，所以这里只取 rounds 的第一条；
    /// 同时把 targetStitchCount / previousRoundStitchCount 这类辅助上下文以注释形式附在 input 顶部，
    /// 方便 LLM 做 stitch-count 自检（对应模板里的 declared_stitch_count 校验）。
    private static func debugUserPrompt(
        projectTitle: String,
        materials _: [String],
        rounds: [AtomizationRoundInput]
    ) -> String {
        guard let round = rounds.first else {
            return """
            <input>
            </input>
            """
        }

        // 上下文提示（target / previous / title 等）以紧凑注释头的形式放在 <input> 里面，
        // 模板没有专门字段承接，但同时又明确要求把它们当 warning/self-check 依据。
        var header: [String] = []
        header.append("// project: \(projectTitle)")
        header.append("// part: \(round.partName)")
        header.append("// title: \(round.title)")
        if let target = round.targetStitchCount {
            header.append("// declared_stitch_count (from pattern): \(target)")
        } else {
            header.append("// declared_stitch_count: null")
        }
        if let prev = round.previousRoundStitchCount {
            header.append("// previous_round_stitch_count: \(prev)")
        } else {
            header.append("// previous_round_stitch_count: null")
        }
        if !round.summary.isEmpty {
            header.append("// summary: \(round.summary)")
        }

        let headerBlock = header.joined(separator: "\n")

        return """
        <input>
        \(headerBlock)
        \(round.rawInstruction)
        </input>
        """
    }

    // MARK: - 冒烟用例

    /// 最简单的一个 round：确认提示词 + 模型能返回可解析的 JSON。
    func testAtomizeSimpleRound() async throws {
        let client = try makeClient()

        let rounds = [
            AtomizationRoundInput(
                partName: "squaring",
                title: "Squaring",
                rawInstruction: "Third loop only. With grey stitches on top, join new yarn to the 4th grey stitch from the right. Ch3 (count as 1dc), 1dc in the same st to complete the first dc inc, 8hdc, dc inc, ch3; [dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3. Instead, work ch1, then 1hdc into the top of the first ch3.",
                summary: "Working in the third loop only to create the square base",
                targetStitchCount: 48,
                previousRoundStitchCount: 40
            )
        ]

        let response = try await client.atomizeTextRoundsWithCustomPrompts(
            systemPrompt: Self.debugSystemPrompt(),
            userPrompt: Self.debugUserPrompt(
                projectTitle: "LLM Debug — Simple Round",
                materials: ["2.5mm crochet hook", "worsted weight yarn"],
                rounds: rounds
            ),
            context: makeContext(),
            modelID: Self.overrideModelID,
            reasoning: Self.overrideReasoning
        )

        printResponse(response, label: "Simple Round")

        XCTAssertEqual(response.rounds.count, 1, "应当只返回 1 个 round")
        XCTAssertFalse(response.rounds[0].segments.isEmpty, "round 必须包含至少一个 segment")
    }

    // MARK: - 实际调试用例（来自 bad_case.md Case 1）

    /// Wolf Granny Square / Squaring —— "omit final ch3" 修饰语用例。
    /// 期望：LLM 把末次 ch3 替换为 ch1 + 1hdc，而不是"3 次完整重复后追加"。
    /// 不做严格业务断言，只要求返回可解析，由开发者人工比对打印结果。
    func testAtomizeWolfGrannyBadCase() async throws {
        let client = try makeClient()

        let rounds = [
            AtomizationRoundInput(
                partName: "Squaring",
                title: "Squaring",
                rawInstruction: """
                Third loop only. With grey stitches on top, join new yarn to the 4th grey \
                stitch from the right. Ch3 (count as 1dc), 1dc in the same st to complete \
                the first dc inc, 8hdc, dc inc, ch3; [dc inc, 8hdc, dc inc, ch3] repeat 3 \
                times, omit the final ch3. Instead, work ch1, then 1hdc into the top of \
                the first ch3.
                """,
                summary: "Work in the third loop only to create the square base.",
                targetStitchCount: 48,
                previousRoundStitchCount: 40
            )
        ]

        let response = try await client.atomizeTextRoundsWithCustomPrompts(
            systemPrompt: Self.debugSystemPrompt(),
            userPrompt: Self.debugUserPrompt(
                projectTitle: "LLM Debug — Wolf Granny Square",
                materials: ["4mm crochet hook", "worsted weight yarn"],
                rounds: rounds
            ),
            context: makeContext(),
            modelID: Self.overrideModelID,
            reasoning: Self.overrideReasoning
        )

        printResponse(response, label: "Wolf Granny Square / Squaring")

        XCTAssertEqual(response.rounds.count, 1, "应当只返回 1 个 round")
        XCTAssertFalse(response.rounds[0].segments.isEmpty, "round 必须包含至少一个 segment")
    }

    // MARK: - Helpers

    private func makeClient() throws -> OpenAICompatibleLLMClient {
        let configuration: RuntimeConfiguration
        do {
            configuration = try RuntimeConfiguration.load()
        } catch {
            throw XCTSkip("缺少 LLM 配置（OPENAI_API_KEY 等），跳过真实 LLM 调试测试。错误：\(error.localizedDescription)")
        }
        return OpenAICompatibleLLMClient(
            configuration: configuration,
            logger: PrintingTraceLogger()
        )
    }

    private func makeContext() -> ParseRequestContext {
        ParseRequestContext(
            traceID: UUID().uuidString,
            parseRequestID: UUID().uuidString,
            sourceType: .text
        )
    }

    /// 包一层方便 catch 错误时顺带把关键上下文（label）打出来。
    /// `PrintingTraceLogger` 已经会把 `assistantContent` / `contentPreview`
    /// 等关键元数据打到 stdout，所以这里只需要把 error 本身露出来。
    private func runAtomization(
        label: String,
        rounds: [AtomizationRoundInput],
        projectTitle: String
    ) async throws -> RoundAtomizationResponse {
        let client = try makeClient()
        do {
            return try await client.atomizeTextRoundsWithCustomPrompts(
                systemPrompt: Self.debugSystemPrompt(),
                userPrompt: Self.debugUserPrompt(
                    projectTitle: projectTitle,
                    materials: [],
                    rounds: rounds
                ),
                context: makeContext(),
                modelID: Self.overrideModelID,
                reasoning: Self.overrideReasoning
            )
        } catch {
            print("\n=== LLM 原子化请求失败 (\(label)) ===")
            print("error: \(error)")
            print("=== END (\(label)) ===\n")
            throw error
        }
    }

    private func printResponse(_ response: RoundAtomizationResponse, label: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonString: String
        if let data = try? encoder.encode(response),
           let string = String(data: data, encoding: .utf8) {
            jsonString = string
        } else {
            jsonString = "<编码失败>"
        }
        print("\n=== LLM 原子化返回 (\(label)) ===")
        print(jsonString)
        print("=== END (\(label)) ===\n")
    }
}

/// 不受 XCTest 环境静默策略限制的 logger —— 把每条 `LogEvent` 直接打到 stdout。
/// 生产的 `ConsoleTraceLogger` 在 `XCTestConfigurationFilePath` 存在时会直接
/// return 跳过打印，导致测试里看不到 LLM 原始返回和解码失败预览；本 logger
/// 专用于本测试文件，绕过该限制。
private struct PrintingTraceLogger: TraceLogging {
    func log(_ event: LogEvent) {
        var lines: [String] = []
        lines.append("[\(event.level)] \(event.stage) / \(event.decision) :: \(event.reason)")
        if let duration = event.durationMS {
            lines.append("  durationMS=\(duration)")
        }
        // 大段内容单独多行打出来，避免一行太长看不清
        let bulkyKeys: Set<String> = ["requestJSON", "responseEnvelopeJSON", "assistantContent", "contentPreview"]
        let metadata = event.metadata
        for key in metadata.keys.sorted() where !bulkyKeys.contains(key) {
            lines.append("  \(key)=\(metadata[key] ?? "")")
        }
        for key in bulkyKeys where metadata[key] != nil {
            lines.append("  --- \(key) ---")
            lines.append(metadata[key] ?? "")
            lines.append("  --- end \(key) ---")
        }
        print(lines.joined(separator: "\n"))
    }
}
