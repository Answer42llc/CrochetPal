# Bad case: Round 7 of Mouse Cat Toy — LLM 用 `note(emitAsAction=false)` 吞掉整圈

## 摘要

| 项 | 值 |
|---|---|
| 图样 | Mouse Cat Toy |
| Round | Body · Round 7 |
| 模型 | `deepseek/deepseek-v3.2`（通过 OpenRouter via Cloudflare Gateway）|
| 时间 | 2026-04-20 10:07:19Z（请求）→ 10:08:03Z（响应），耗时 44.1s |
| 预期针数 | 12 |
| 实际展开针数 | 0 |
| 编译器行为 | `atomicActions = []`，触发 `atomization_target_stitch_count_mismatch` 警告 |
| UI 观感 | 显示 `Current Action: Complete` + `Stitch progress: 0/0` + `Next: SC`，用户误以为本圈已完成 |
| 用户截图 | iPhone 17 Pro 模拟器，执行界面 Round 7 |

## 失败模式

LLM 把 Round 7 切成 5 个片段，**每一个都包成 `note(emitAsAction=false)`**——包括 `sc (both loops)`、`sc 3 (both loops)`、`sc 6 (both loops)` 这三段本该是明确 stitch 节点的内容。

由于 `note(emitAsAction=false)` 在 [CrochetIRCompiler.swift:80-83](../../CrochetPal/Shared/Services/CrochetIRCompiler.swift#L80) 里被直接 `return ([], [])`（不产生任何 action、不产生 warning），整圈的 12 针全部"静默消失"。

这是 LLM 绕开 prompt 里 "Use ambiguous ONLY when no supported stitch type can be identified..." 规则的一种方式——prompt 对 `ambiguous` 设了约束，但对 `note(emitAsAction=false)` 没有对等约束，于是模型找到了另一个"逃生舱"。

---

## 输入

### 发送给 LLM 的 round payload（系统提示词省略，完整请求见 `/tmp/round7_full_request.json` 或参考 [OpenAICompatibleLLMClient.swift:671](../../CrochetPal/Shared/Services/OpenAICompatibleLLMClient.swift#L671) `roundIRAtomizationSystemPrompt`）

```
Project title: Mouse Cat Toy
Materials: Worsted/aran (#4) weight yarn in your choice of color, 3.75 mm crochet hook, ...

Input rounds JSON:
[
  {
    "partName": "Body",
    "previousRoundStitchCount": 18,
    "rawInstruction": "Round 7: sc (both loops), bend first ear forward and sc in blo of st from round 5, sc 3 (both loops), bend second ear forward and sc in blo of st from round 5, sc 6 (both loops). (12)",
    "targetStitchCount": 12,
    "title": "Round 7"
  }
]
```

### 文本结构拆解

| 片段 | 原文 | 应当的展开 | 针数 |
|---|---|---|---|
| 1 | `sc (both loops)` | 1 × sc，note="both loops" | 1 |
| 2 | `bend first ear forward and sc in blo of st from round 5` | 1 × sc，note="bend first ear forward; in blo of st from round 5" | 1 |
| 3 | `sc 3 (both loops)` | 3 × sc，note="both loops" | 3 |
| 4 | `bend second ear forward and sc in blo of st from round 5` | 1 × sc，note="bend second ear forward; in blo of st from round 5" | 1 |
| 5 | `sc 6 (both loops)` | 6 × sc，note="both loops" | 6 |
| 合计 | — | — | **12** ✓ |

---

## 输出（LLM 原始返回）

模型：`deepseek/deepseek-v3.2` · duration 44.1s · HTTP 200

```json
{
  "rounds": [
    {
      "title": "Round 7",
      "sourceText": "Round 7: sc (both loops), bend first ear forward and sc in blo of st from round 5, sc 3 (both loops), bend second ear forward and sc in blo of st from round 5, sc 6 (both loops). (12)",
      "expectedProducedStitches": 12,
      "nodes": [
        {
          "kind": "note",
          "note": {
            "message": "sc (both loops)",
            "sourceText": "sc (both loops)",
            "emitAsAction": false
          },
          "stitch": null, "repeat": null, "conditional": null,
          "control": null, "ambiguous": null
        },
        {
          "kind": "note",
          "note": {
            "message": "bend first ear forward and sc in blo of st from round 5",
            "sourceText": "bend first ear forward and sc in blo of st from round 5",
            "emitAsAction": false
          },
          "stitch": null, "repeat": null, "conditional": null,
          "control": null, "ambiguous": null
        },
        {
          "kind": "note",
          "note": {
            "message": "sc 3 (both loops)",
            "sourceText": "sc 3 (both loops)",
            "emitAsAction": false
          },
          "stitch": null, "repeat": null, "conditional": null,
          "control": null, "ambiguous": null
        },
        {
          "kind": "note",
          "note": {
            "message": "bend second ear forward and sc in blo of st from round 5",
            "sourceText": "bend second ear forward and sc in blo of st from round 5",
            "emitAsAction": false
          },
          "stitch": null, "repeat": null, "conditional": null,
          "control": null, "ambiguous": null
        },
        {
          "kind": "note",
          "note": {
            "message": "sc 6 (both loops)",
            "sourceText": "sc 6 (both loops)",
            "emitAsAction": false
          },
          "stitch": null, "repeat": null, "conditional": null,
          "control": null, "ambiguous": null
        }
      ]
    }
  ]
}
```

**注意**：`expectedProducedStitches=12` 是 LLM 自己填写的，和实际展开的 0 针矛盾——模型"知道目标是 12"，但还是把所有识别出的 sc 写进了 note。

---

## 编译器推导出的下游状态

| 字段 | 值 |
|---|---|
| `CrochetIRCompiler.expand` → `atomicActions` | `[]` |
| `CrochetIRCompiler.expand` → `producedStitchCount` | `0` |
| `CrochetIRCompiler.expand` → `warnings` | `[{ code: "atomization_target_stitch_count_mismatch", message: "Expected 12 produced stitches, but expanded to 0." }]` |
| `AtomizedRoundUpdate.resolvedTargetStitchCount` | `0` |
| `PatternRound.targetStitchCount`（覆写后） | `0`（原本从 `(12)` 提取的 12 被覆盖） |
| `PatternRound.atomizationStatus` | `.ready`（因为"没抛错"，只有 warning） |
| `PatternRound.atomizationWarning` | `"atomization_target_stitch_count_mismatch"` |
| `ExecutionEngine.isAwaitingNextRound` | `true`（因为 `actionIndex=0 == atomicActions.count=0`） |
| `snapshot.actionTitle` | `"Complete"` |
| `snapshot.stitchProgress / targetStitches` | `0 / 0` |
| `snapshot.nextActionTitle` | `"SC"`（探到 Round 8 的首个动作） |

---

## 5 次重跑对比（同一请求，换模型 / 重采样）

同样的请求 payload 直接打 OpenRouter，模型分别为 `deepseek/deepseek-v3.2` 和 `openai/gpt-5.4`。

| 运行 | 模型 | 耗时 | 结果 | 节点结构 | 失败模式 |
|---|---|---|---|---|---|
| 原始（本 bad case） | deepseek/deepseek-v3.2 | 44.1s | ❌ 0/12 | 5× `note(emit=false)` | "整圈吞入 note" |
| ds-a | deepseek/deepseek-v3.2 | 35.4s | ✅ 12/12 | 5 stitch + 5 note（冗余但对） | — |
| ds-b | deepseek/deepseek-v3.2 | 21.1s | ❌ 0/12 | 1× `ambiguous` 包整圈 | "整圈放弃为 ambiguous" |
| gpt-a | openai/gpt-5.4 | 8.1s | ✅ 12/12 | 5 stitch + 2 note | 干净 |
| gpt-b | openai/gpt-5.4 | 10.4s | ✅ 12/12 | 5 stitch + 3 control（bend 作 custom control） | 结构最工整 |
| gpt-c | openai/gpt-5.4 | 8.0s | ❌ 0/12 | 1× `ambiguous` 包整圈 | "整圈放弃为 ambiguous" |

**成功率**：DeepSeek V3.2 = 1/3 · GPT-5.4 = 2/3

### `ds-b` / `gpt-c` 的共同失败响应（ambiguous 整圈打包）

```json
{
  "rounds": [
    {
      "title": "Round 7",
      "sourceText": "Round 7: sc (both loops), bend first ear forward and sc in blo of st from round 5, ...",
      "expectedProducedStitches": 12,
      "nodes": [
        {
          "kind": "ambiguous",
          "ambiguous": {
            "reason": "Complex placement instruction requiring diagram or spatial awareness (bend ear forward / st from round 5)...",
            "sourceText": "Round 7: sc (both loops), bend first ear forward and sc in blo of st from round 5, sc 3 (both loops), ...",
            "safeInstruction": null
          },
          "stitch": null, "repeat": null, "conditional": null, "control": null, "note": null
        }
      ]
    }
  ]
}
```

### `gpt-b` 的**理想**响应形状（供参考）

```json
{
  "rounds": [
    {
      "title": "Round 7",
      "expectedProducedStitches": 12,
      "nodes": [
        { "kind": "stitch",  "stitch":  { "type": "sc", "count": 1, "note": "both loops", "notePlacement": "all" } },
        { "kind": "control", "control": { "kind": "custom", "instruction": "bend first ear forward" } },
        { "kind": "stitch",  "stitch":  { "type": "sc", "count": 1, "note": "in blo of st from round 5", "notePlacement": "all" } },
        { "kind": "stitch",  "stitch":  { "type": "sc", "count": 3, "note": "both loops", "notePlacement": "all" } },
        { "kind": "control", "control": { "kind": "custom", "instruction": "bend second ear forward" } },
        { "kind": "stitch",  "stitch":  { "type": "sc", "count": 1, "note": "in blo of st from round 5", "notePlacement": "all" } },
        { "kind": "stitch",  "stitch":  { "type": "sc", "count": 6, "note": "both loops", "notePlacement": "all" } }
      ]
    }
  ]
}
```

---

## 现象观察

- **模型能力差距**：GPT-5.4 成功率 67%（结构更干净、耗时更短），DeepSeek V3.2 成功率 33%。
- **共同失败模式**：两个模型都会出现"整圈放弃"，只是逃生舱不同——DeepSeek 倾向用 `note(emitAsAction=false)`，GPT-5.4 倾向用 `ambiguous`。两者都违反了 prompt 的精神（不该丢针），但都不违反 prompt 的字面规则。
