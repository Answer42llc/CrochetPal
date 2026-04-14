## 阶段 1: 锁定问题边界
**目标**: 添加回归测试，证明多轮次批量 atomize 会引入跨轮次串扰风险，并约束为单轮独立请求。
**成功标准**: 新测试能验证一次只向 LLM 发送一个 round 的 atomization 输入。
**测试**: 运行 `CrochetPalTests/PatternImportServiceTests.swift` 中新增的 atomization 调用形态测试。
**状态**: 进行中

## 阶段 2: 调整 atomization 策略
**目标**: 修改 `PatternImportService`，对每个目标 round 单独发起 atomization 请求，并保持更新结果顺序稳定。
**成功标准**: 同时请求多个 round 时，不再共享一个 LLM prompt。
**测试**: 运行 `CrochetPalTests/PatternImportServiceTests.swift` 相关测试。
**状态**: 未开始

## 阶段 3: 验证回归
**目标**: 运行相关测试，确认计数逻辑与现有执行视图行为保持一致。
**成功标准**: 相关测试全部通过，无新增失败。
**测试**: 运行 `CrochetPalTests/PatternImportServiceTests.swift` 与 `CrochetPalTests/ExecutionEngineTests.swift`。
**状态**: 未开始
