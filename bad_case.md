# 原子化解析 Bad Case 档案

本文件记录 LLM 原子化（`atomizeTextRounds`）阶段出现过的错误解析案例，作为后续改进和回归测试的用例积累。

## 记录格式

每个 case 使用以下 5 部分：

- **Pattern 来源**：项目名 / round 标题
- **Raw instruction**：原文
- **输入上下文**：`targetStitchCount`、`previousRoundStitchCount` 等
- **期望行为**：正确的语义理解
- **实际错误**：LLM 当前的错误输出 + 错在哪

---

## Case 1：Wolf Granny Square / Squaring — 漏掉 "omit final ch3" 修饰语

- **Pattern 来源**：Wolf Granny Square，part "Squaring"，round title "Squaring"
- **Raw instruction**：
  > Third loop only. With grey stitches on top, join new yarn to the 4th grey stitch from the right. Ch3 (count as 1dc), 1dc in the same st to complete the first dc inc, 8hdc, dc inc, ch3; [dc inc, 8hdc, dc inc, ch3] repeat 3 times, omit the final ch3. Instead, work ch1, then 1hdc into the top of the first ch3.
- **输入上下文**：
  - `targetStitchCount`: 48
  - `previousRoundStitchCount`: （来自上一轮的目标值，运行时读取）
  - `summary`: "Work in the third loop only to create the square base."
- **期望行为**：
  - 识别出 `[dc inc, 8hdc, dc inc, ch3]` 是一个重复 3 次的 block，但**第 3 次重复时末尾的 ch3 不做**，改为 ch1 + 1hdc into the top of the first ch3。
  - 正确做法：要么拆成 `repeat(times=2) + 一次摊平的 block（去掉末尾 ch3）+ ch1 + hdc`，要么完全摊平为 3 次独立的 block。
  - 总针数应为 48。
- **实际错误**：
  - LLM 输出了 `repeat(times=3, sequence=[dc inc, 8hdc, dc inc, ch3])` 完整执行 3 次，然后**又追加**了 `ch1 + 1hdc`。
  - 相当于把 "omit the final ch3. Instead, work ch1 + hdc" 理解成了"3 次完整重复之后再额外做 ch1 + hdc"——漏掉了"替代末次 ch3"的语义。
  - 结果：多了 1 个 ch3（3 针），展开后总针数与 `targetStitchCount` 不一致。
- **问题类型**：修饰语/例外（modifier/exception）丢失——当 repeat 中某一次迭代有特殊行为时，LLM 倾向于把 repeat 保留为整块而忽略例外。

---

## Case 2：Mary's Moment Floral Crochet Square / Round 4 —— popcorn 被错映射为 FO

- **Pattern 来源**：Mary's Moment Floral Crochet Square，part "Square"，round title "Round 4"
- **Raw instruction**：
  > (FPhdc around the FPhdc, ch 4, make a Popcorn in the next ch-2 sp, ch 4) 6 times. Join to the first FPhdc with a sl st. {6 FPhdc, 6 Popcorns, and 12 ch-4 sps}
- **输入上下文**：
  - `previousRoundStitchCount`: 42
  - `summary`: "Work front post half double crochets and popcorns separated by chain-4 spaces."
- **期望行为**：
  - popcorn 那一步输出 `stitchRun(type=popcorn, count=1, ...)`，执行界面显示 "Popcorn"。
- **实际错误**：
  - LLM 把 popcorn 输出成 `stitchRun(type=fo, ...)`，执行界面显示 "FO"（fasten off）。
  - 直接证据（trace_logs.jsonl，metadata.assistantContent）：
    ```json
    {"type": "fo", "verbatim": "make a Popcorn in the next ch-2 sp", "note": "popcorn stitch"}
    ```
- **问题类型**：枚举缺失导致 LLM 乱选——`StitchActionType` enum 历史上没有 popcorn / puff / bobble 这些"产出恒定 1 针"的特殊装饰针法 case；prompt 又禁止用 `custom` 作为逃逸出口（质量闸）。LLM 被迫在 supported 列表里瞎选一个合法 rawValue，选了短的 `fo`。由于 `fo` 是合法枚举值，后续 `isAtomicActionType` 校验也通过，问题静默落盘。
- **修复**：把 `popcorn / puff / bobble` 加进 `StitchActionType` 枚举，并在 `CrochetTermDictionary` 里把 `pc / ps / bo` 条目关联到新 case + `producedStitches=1`；prompt 中加一条专门规则和 Golden example 指引 LLM 正确映射。
