# Bad case: Round 3 of Mouse Cat Toy — LLM 把 `sc around. (9)` 当作 `ambiguous`

## 摘要

| 项 | 值 |
|---|---|
| 图样 | Mouse Cat Toy |
| Round | Body · Round 3 |
| 模型 | IR 原子化阶段（`configuration.atomizationModelID`） |
| 预期针数 | 9 |
| 实际展开针数 | 0 |
| 编译器行为 | `atomicActions = [1 × custom(producedStitches=0)]`，触发 `ir_ambiguous_source` + `atomization_target_stitch_count_mismatch` 两条警告 |
| UI 观感 | 执行界面显示 `Current Action: Work 1 single crochet into each stitch around.` + `Stitch progress: 0/0` + 橙色警告 `目标针数与实际展开不一致，已按指令展开`，用户无法逐针推进 |
| 用户截图 | iPhone 17 Pro 模拟器，Round 3 执行界面 |

## 失败模式

LLM 把 `sc around.`（明确单一针法 + 已知前圈 9 针 + 明确目标 9 针）整段塞进一个 `ambiguous` 节点，而不是展开为 `stitch(type=sc, count=9)`。这是 prompt 里 ambiguous 规则过宽导致的漂移——原规则把 `work evenly around` 和 `<stitch> around` 都当成候选的 "ambiguous" 表述，模型在 `<stitch> around` 这种本可确定展开的输入上也会套用。

同一 pattern 内 Round 5/9/10/12/13/15/16/17 相同形式的 `sc around. (N)` 都被正常展开为 N 条 sc，证明这是 LLM 非确定性漂移，不是规则缺失。

---

## 输入

### 发送给 LLM 的 round payload（系统提示词见 [OpenAICompatibleLLMClient.swift:671](../../CrochetPal/Shared/Services/OpenAICompatibleLLMClient.swift#L671) `roundIRAtomizationSystemPrompt`）

```
Project title: Mouse Cat Toy
Materials: Worsted/aran (#4) weight yarn, 3.75 mm crochet hook, ...

Input rounds JSON:
[
  {
    "partName": "Body",
    "title": "Round 3",
    "rawInstruction": "Round 3: sc around. (9)",
    "targetStitchCount": 9,
    "previousRoundStitchCount": 9
  }
]
```

### 文本结构拆解

| 片段 | 原文 | 应当的展开 | 针数 |
|---|---|---|---|
| 1 | `sc around` | 9 × sc（来自 `previousRoundStitchCount=9` 或 `targetStitchCount=9`） | 9 |
| 合计 | — | — | **9** ✓ |

---

## 输出（LLM 返回的 IR，反推自持久化状态）

无法直接从 trace_logs.jsonl 读到本次 Round 3 的原始 LLM 响应（该日志文件对应其他图样的 atomization 请求），但可以从 [projects.json](../.) 里持久化下来的 `atomicActions`、`atomizationWarning` 结合 [CrochetIRCompiler.swift:84-101](../../CrochetPal/Shared/Services/CrochetIRCompiler.swift#L84) 的 ambiguous→custom 展开规则反推出 LLM 必定返回了如下结构：

```json
{
  "rounds": [
    {
      "title": "Round 3",
      "sourceText": "Round 3: sc around. (9)",
      "expectedProducedStitches": 9,
      "nodes": [
        {
          "kind": "ambiguous",
          "ambiguous": {
            "reason": "The instruction 'sc around' is a common p...（持久化层截断）",
            "sourceText": "sc around.",
            "safeInstruction": "Work 1 single crochet into each stitch around."
          },
          "stitch": null, "repeat": null, "conditional": null,
          "control": null, "note": null
        }
      ]
    }
  ]
}
```

反推依据：
- 编译后得到 1 条 `type=custom, producedStitches=0` 的 atomic action，且 `instruction="Work 1 single crochet into each stitch around."`；
- [CrochetIRCompiler.swift:91](../../CrochetPal/Shared/Services/CrochetIRCompiler.swift#L91) 里 ambiguous 的 instruction 填充逻辑是 `ambiguous.safeInstruction ?? ambiguous.sourceText`，可见 `safeInstruction` 非空，且值等于 `Work 1 single crochet into each stitch around.`；
- UI 截图里 `Current Action` 下方长条灰字 `The instruction 'sc around' is a common p...` 正是 `note` 字段（即 `ambiguous.reason`）的截断渲染，来自 [CrochetIRCompiler.swift:96](../../CrochetPal/Shared/Services/CrochetIRCompiler.swift#L96) `note: ambiguous.reason`；
- 警告码包含 `ir_ambiguous_source`（[CrochetIRCompiler.swift:98](../../CrochetPal/Shared/Services/CrochetIRCompiler.swift#L98)）与 `atomization_target_stitch_count_mismatch`（[CrochetIRCompiler.swift:18](../../CrochetPal/Shared/Services/CrochetIRCompiler.swift#L18)），证明既走了 ambiguous 分支、expected=9 又和 producedStitchCount=0 冲突。

---

## 编译器推导出的下游状态

| 字段 | 值 |
|---|---|
| `CrochetIRCompiler.expand` → `atomicActions` | `[AtomicAction(type=custom, instruction="Work 1 single crochet into each stitch around.", producedStitches=0, note="The instruction 'sc around' is a common ...")]` |
| `CrochetIRCompiler.expand` → `producedStitchCount` | `0` |
| `CrochetIRCompiler.expand` → `warnings` | `[{code:"ir_ambiguous_source"}, {code:"atomization_target_stitch_count_mismatch", message:"Expected 9 produced stitches, but expanded to 0."}]` |
| `AtomizedRoundUpdate.resolvedTargetStitchCount` | `0`（= `expansion.producedStitchCount`） |
| `PatternRound.targetStitchCount`（覆写后） | `0`（原本从 `(9)` 提取的 9 被覆盖）|
| `PatternRound.atomizationStatus` | `.ready` |
| `PatternRound.atomizationWarning` | `"ir_ambiguous_source;atomization_target_stitch_count_mismatch"` |
| `snapshot.stitchProgress / targetStitches` | `0 / 0` |
| UI 橙色警告 | `目标针数与实际展开不一致，已按指令展开` |

---

## 正确展开参照

同 pattern Round 5 `sc around. (12)`、Round 9/10 `sc around. (18)` 等都被正确处理为：

```json
{
  "kind": "stitch",
  "stitch": {
    "type": "sc",
    "count": <targetStitchCount 或 previousRoundStitchCount>,
    "instruction": null,
    "producedStitches": null,
    "note": null,
    "notePlacement": "first",
    "sourceText": "sc around"
  },
  "repeat": null, "conditional": null, "control": null, "note": null, "ambiguous": null
}
```

---

## 现象观察

- 同一 pattern 内 Round 5 `sc around. (12)`、Round 9/10 `sc around. (18)`、Round 12/13 `sc around. (21)`、Round 15/16/17 `sc around. (24)` 全部被正常展开为对应针数的 sc 节点，只有 Round 3 漂移。证明这是 LLM 非确定性漂移，不是 prompt 根本缺失该语义——同一条请求在样本内就存在成功/失败两种输出。
- IR 原子化提示词中对 `ambiguous` 的描述（`Use ambiguous instead of inventing stitch counts for phrases such as work evenly around, continue as established, or assembly instructions that require a diagram.`）把 `<stitch> around` 和 `work evenly around` 并列，模型可能会把前者视为同类候选；前者实际有明确的单一针法类型 + 已知 `previousRoundStitchCount`，是确定性展开的场景。
