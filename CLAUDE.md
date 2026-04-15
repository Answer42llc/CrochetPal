# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CrochetPal is a SwiftUI iOS + watchOS companion app for tracking crochet pattern execution. Users import patterns (via web URL or photo), then step through them stitch-by-stitch on iPhone or Apple Watch (including wrist-motion gestures).

# 开发指南

## 严格禁止的操作

### Git 操作限制
- **绝对禁止执行 git reset、git revert、git rebase、git restore 等回滚工作的命令**
- **只允许使用 git logs、git status、git diff 等安全操作来对比文件变化以及恢复文件内容**
- **禁止删除或修改 .git 目录**
- **任何 git 操作前必须得到用户明确许可**

### 文件系统操作限制
- **绝对禁止执行 rm -rf 命令**
- **禁止删除目录，特别是项目根目录或重要目录**
- **删除文件前必须明确告知用户并得到许可**

## 沟通语言

**重要**：请使用中文与用户进行所有沟通和交流。包括：
- 所有对话和回复
- 代码注释（除非项目规范要求英文）
- 文档说明
- 错误提示和解释
- 任务计划和总结

## 理念

### 核心信念

- **渐进式进展优于大爆炸式改动** - 小改动，保证能编译通过并测试通过
- **从现有代码中学习** - 实施前先研究和规划
- **务实优于教条** - 适应项目实际情况
- **清晰的意图优于聪明的代码** - 保持无聊和明显
- **直击本质** - 排查问题时，通过分析和设计测试方案，找到产生问题的根本原因，从根本上修复问题，而不是通过治标不治本的解决方案事实上延缓或掩盖问题。
- **最直接证据** - 排查问题是优先寻找最直接的证据，比如在排查崩溃的时候，应该优先解析崩溃日志，找到具体的崩溃点，而不是根据现象来重复 “猜->改代码调试->再猜”的模式

### 简单意味着

- 每个函数/类单一职责
- 避免过早抽象
- 不要耍小聪明 - 选择无聊的解决方案
- 如果需要解释，那就太复杂了

## 流程

### 1. 规划与分阶段

将复杂工作分解为 3-5 个阶段。记录在 `IMPLEMENTATION_PLAN.md` 中：

```markdown
## 阶段 N: [名称]
**目标**: [具体交付物]
**成功标准**: [可测试的结果]
**测试**: [具体测试用例]
**状态**: [未开始|进行中|已完成]
```
- 进展时更新状态
- 所有阶段完成后删除文件

### 2. 实施流程

1. **理解** - 研究代码库中的现有模式
2. **测试** - 先写测试（红灯）
3. **实现** - 最少代码通过测试（绿灯）
4. **重构** - 在测试通过的情况下清理代码
5. **验证** - 确保编译通过且测试运行
6. **更新 TODO** - 标记已完成的任务并总结成就
7. **提交** - 使用清晰的消息链接到计划

**关键**: 代码编译成功后，始终要：
- 更新 TODO 列表标记已完成任务
- 添加完成内容的总结
- 规划下一步（如适用）
- 永远不要让 TODO 列表过时或停滞

### 3. 遇到困难时（尝试 3 次后）

**关键**: 每个问题最多尝试 3 次，然后停止。

1. **记录失败内容**：
   - 你尝试了什么
   - 具体的错误消息
   - 你认为失败的原因

2. **研究替代方案**：
   - 找到 2-3 个类似的实现
   - 记录使用的不同方法

3. **质疑根本问题**：
   - 这是正确的抽象级别吗？
   - 可以分解成更小的问题吗？
   - 有完全更简单的方法吗？

4. **尝试不同角度**：
   - 不同的库/框架功能？
   - 不同的架构模式？
   - 删除抽象而不是增加？

## 技术标准

### 架构原则

- **组合优于继承** - 使用依赖注入
- **接口优于单例** - 实现可测试性和灵活性
- **显式优于隐式** - 清晰的数据流和依赖
- **尽可能测试驱动** - 永不禁用测试，修复它们

### 代码质量

- **每次提交必须**：
  - 成功编译
  - 通过所有现有测试
  - 为新功能包含测试
  - 遵循项目格式化/代码检查规则

- **提交前**：
  - 运行格式化器/代码检查器
  - 自我审查更改
  - 确保提交消息解释"为什么"

### 错误处理

- 快速失败并提供描述性消息
- 包含调试上下文
- 在适当级别处理错误
- 永远不要默默吞掉异常

### 编译错误处理

**基本原则**：永远不要删除代码来绕过编译错误。修复根本原因。

遇到编译错误时：

1. **永远不要这样做**：
   - 删除有问题的方法/代码
   - 注释掉错误行
   - 使用占位符实现（TODO，抛出 NotImplemented）
   - 修改业务逻辑以匹配错误假设

2. **始终这样做**：
   - 理解错误发生的原因
   - 研究实际的数据模型/API
   - 修复你的代码以匹配现实，而不是相反
   - 如果属性不存在，找出：
     - 正确的属性名是什么？
     - 应该向模型添加此属性吗？
     - 有替代方法吗？

3. **错误解决流程**：
   ```
   错误发生 → 理解根本原因 → 研究正确解决方案 → 修复实际问题
   ```
   而不是：
   ```
   错误发生 → 删除有问题的代码 → 编译通过 ❌
   ```

4. **常见陷阱和解决方案**：
   - **属性名称不匹配**：研究实际模型，使用正确名称
   - **缺少功能**：基于实际能力实现，而不是假设
   - **类型不兼容**：理解类型，正确转换
   - **缺少依赖**：添加所需的导入/包

5. **质量优于速度**：
   - 工作的部分实现 > 破损的完整实现
   - 正确的实现 > 快速编译
   - 理解问题 > 绕过问题

**记住**：删除错误代码是在逃避问题，而不是解决问题。每个错误都是更好理解系统的机会。

## 决策框架

当存在多个有效方法时，基于以下选择：

1. **可测试性** - 我能轻松测试这个吗？
2. **可读性** - 6 个月后有人能理解这个吗？
3. **一致性** - 这与项目模式匹配吗？
4. **简单性** - 这是最简单的可行解决方案吗？
5. **可逆性** - 以后改变有多难？

## 项目集成

### 学习代码库

- 找到 3 个类似的功能/组件
- 识别常见模式和约定
- 尽可能使用相同的库/工具
- 遵循现有的测试模式

### 工具

- 使用项目现有的构建系统
- 使用项目的测试框架
- 使用项目的格式化器/代码检查器设置
- 没有强有力的理由不要引入新工具
- **可以并且更多的使用已安装的 agents** - 充分利用各种专门的 agents 来提高效率和质量

## 质量门槛

### 完成的定义

- [ ] 测试编写并通过
- [ ] 代码遵循项目约定
- [ ] 没有代码检查器/格式化器警告
- [ ] 提交消息清晰
- [ ] 实现与计划匹配
- [ ] 没有不带问题编号的 TODO

### 测试指南

- 测试行为，而不是实现
- 尽可能每个测试一个断言
- 清晰的测试名称描述场景
- 使用现有的测试工具/帮助器
- 测试应该是确定性的

## 重要提醒

**永远不要**：
- 使用 `--no-verify` 绕过提交钩子
- 禁用测试而不是修复它们
- 提交不能编译的代码
- 做假设 - 用现有代码验证
- 删除代码只为通过编译
- 使用 TODO 或占位符绕过实现
- 修改正确的业务逻辑以匹配错误的代码

**始终**：
- 增量提交工作代码
- 随时更新计划文档
- 从现有实现中学习
- 3 次失败尝试后停止并重新评估
- 从根本原因修复编译错误
- 在修复前理解错误发生的原因
- 确保实现完整且功能正常


## 编译检查
- 完成任务后，请自行进行编译并解决编译错误。你可以把存在的 target device 列出来，然后选择一个进行编译。
- 使用 asc-cli 是操作 app store connect，只要不涉及代码文件的修改，就不需要编译检查。

## 沟通语言
**重要**：请使用中文与用户进行所有沟通和交流。包括：
- 所有对话和回复
- 代码注释（除非项目规范要求英文）
- 文档说明
- 错误提示和解释
- 任务计划和总结



## Build & Test

Open `CrochetPal.xcodeproj` in Xcode. There are no external dependencies — only native Apple frameworks.

**Targets:** CrochetPal (iOS), CrochetPalWatchApp (watchOS), CrochetPalTests, CrochetPalUITests

```bash
# Build iOS app
xcodebuild -project CrochetPal.xcodeproj -scheme CrochetPal -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run unit tests
xcodebuild -project CrochetPal.xcodeproj -scheme CrochetPal -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run UI tests (uses -ui-testing flag and fixture data)
xcodebuild -project CrochetPal.xcodeproj -scheme CrochetPal -destination 'platform=iOS Simulator,name=iPhone 16' test -only-testing:CrochetPalUITests
```

## Configuration

Build settings flow through xcconfig files in `Config/`:
- `Secrets.xcconfig` (gitignored) — holds `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `TEXT_MODEL_ID`, `VISION_MODEL_ID`
- `Secrets.example.xcconfig` — documents required keys
- `Common.xcconfig` includes Secrets and maps keys to Info.plist entries
- `RuntimeConfiguration` loads these at runtime from Info.plist

## Architecture

**MVVM with Service Layer**, protocol-driven for testability.

### Data flow

```
View (@EnvironmentObject) → ProjectRepository → Services → Models → JSONFileStore (disk)
                                    ↕
                          WatchSyncCoordinator → Watch app
```

### Key layers

- **App/** — `CrochetPalApp` (entry point), `AppBootstrapper` (test-env detection), `AppContainer` (DI service locator via static `make()`)
- **Features/** — Feature views: `ProjectListView`, `ProjectDetailView`, `ExecutionView`, `RoundEditorView`, `ImportSheet`, `DebugLogView`
- **Shared/Models/** — Value-type structs: `CrochetProject`, `ExecutionProgress`, `PatternParseResponse`, `StitchActionType` enum
- **Shared/Services/** — `ProjectRepository` (state + persistence), `ExecutionEngine` (pure static logic for step-through), `PatternImportService` (orchestrates import pipeline), `OpenAICompatibleLLMClient` (LLM parsing with prompt engineering), `HTMLExtractionService` (web content scoring/filtering), `WatchSyncCoordinator` (WatchConnectivity bridging), `TraceLogger` (structured logging)

### Watch app

`CrochetPalWatchApp/` — `WatchCompanionStore` bridges sync coordinator + `WatchMotionInput` (CoreMotion roll detection). Receives `ProjectSnapshot` from iPhone, sends `ExecutionCommand` back. Motion detection uses roll threshold (0.9) with cooldown (1.2s).

### Import pipeline

Web/image → `PatternImportService` → `HTMLExtractionService` (web only) → `OpenAICompatibleLLMClient` (LLM parse to JSON) → `CrochetProject` + `ExecutionProgress` → persisted via `ProjectRepository`

## Testing patterns

- Unit tests use protocol-based test doubles (e.g., `FixturePatternParsingClient` for LLM)
- Test fixtures live in `CrochetPalTests/Fixtures/` (HTML, images, mocks)
- UI tests use `-ui-testing` launch argument + `UITestURLProtocol` for URL mocking
- `AppContainer` supports test/UI-test modes with fixture services

## Design Principles

- 高复用，低耦合 (high reuse, low coupling)
- All services are protocol-backed for substitution
- Models are structs (value types); mutations via repository indices
- `@MainActor` on ObservableObjects; Combine `@Published` for reactivity
- `ExecutionEngine` is a pure enum of static methods — no state, easy to test


# 必须遵守
- 不要针对特定的 Pattern 产生的问题客制化 LLM 提示词，要从特定情况推导出一般情况，给出更加通用的解决方案。你的解决方案应该是能够解决这一类问题，而不是只对特定的 Pattern 中的写法有用
- 避免通过正则表达式对 LLM 生成的内容进行清洗，因为这样的话最终会演变成不断增加正则表达式的复杂度来适配各种各样的情况。优先方案应该是想办法去约束 LLM 的输出，从而让 LLM 生成的内容更加符合预期。

# 历史数据
- 现在产品处于早期研发阶段，还没有上线，没有真实用户，所有涉及存储结构的改动，比如改动数据模型等，都不需要考虑历史数据的兼容性问题。