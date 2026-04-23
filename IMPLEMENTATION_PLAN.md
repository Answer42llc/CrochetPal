## 阶段 1: 评估链路设计
**目标**: 梳理 `rawInstruction`、IR、atomic actions 的数据模型与现有 LLM/repair 能力，确定评估 subagent 的输入输出契约。
**成功标准**: 明确评估结果的数据结构、接入层级，以及测试如何消费该结果。
**测试**: 人工核对评估模型输入覆盖 `rawInstruction`、IR `sourceText`、atomic actions；为新类型补最小单测。
**状态**: 已完成

## 阶段 2: 实现评估 subagent
**目标**: 新增一个专门判断“原子化结果是否与 `rawInstruction` 匹配”的评估 subagent/LLM 客户端入口。
**成功标准**: 能对单个 round 输出结构化评估结论，包括是否匹配、问题分类和解释。
**测试**: 新增针对 prompt/schema/client 的单元测试，覆盖成功与 malformed repair 场景。
**状态**: 已完成

## 阶段 3: 数据集评估与回归测试
**目标**: 对现有 LLM fixture 数据集运行评估 subagent，并把结果持久化为可回归的测试数据。
**成功标准**: 每个 Pattern 的每个 round/row 都有评估结果；测试能校验覆盖、结果一致性，并输出汇总。
**测试**: 运行新增评估捕获测试与离线回归测试。
**状态**: 已完成

## 阶段 4: 验证与收尾
**目标**: 运行相关测试与编译检查，确认新增评估链路不破坏工程。
**成功标准**: 相关测试通过，项目在选定 target device 上编译成功。
**测试**: `xcodebuild test` + `xcodebuild build`
**状态**: 已完成
