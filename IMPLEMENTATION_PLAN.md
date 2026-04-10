## 阶段 1: 定位失败态按钮缺失原因
**目标**: 确认执行页在 `Blocked` 状态下为何没有展示重试入口。
**成功标准**: 明确按钮判定条件与失败态来源不一致的根因。
**测试**: 阅读 `ExecutionView`、`ProjectRepository`、`ExecutionEngine`。
**状态**: 已完成

## 阶段 2: 调整重试按钮展示条件
**目标**: 让当前圈解析失败时稳定显示重试按钮。
**成功标准**: 即使全局 `executionState` 已回到 `idle`，只要当前圈是 `failed` 仍能重试。
**测试**: 增加执行页失败态判定测试。
**状态**: 已完成

## 阶段 3: 验证与编译检查
**目标**: 确认相关测试通过，并完成一次模拟器构建验证。
**成功标准**: 相关单测通过，`xcodebuild build` 成功。
**测试**: `xcodebuild test`、`xcodebuild build`。
**状态**: 已完成

## 完成总结
- 已将执行页重试按钮的展示条件改为同时覆盖 `executionState.failed` 和“当前圈 `atomizationStatus == .failed`”。
- 已把按钮文案调整为更直接的 `Retry`，并继续复用现有的 `retryRoundAtomization` 流程。
- 已补充回归测试，覆盖“当前圈失败但全局状态 idle 时仍显示重试按钮”的场景。
- 已在 `iPhone 17 Pro (iOS 26.3)` 上完成 `ExecutionEngineTests` 和整包 `build` 验证。
