## 阶段 1: DeepSeek strict mode 适配确认
**目标**: 基于官方文档确认 `/beta` strict tool mode 的请求形态和 schema 限制。
**成功标准**: 明确不再使用 `response_format: json_schema`，改用 `tools[].function.strict=true`。
**测试**: 检查本地 DeepSeek 官方 key 是否存在，并记录缺失时无法实测。
**状态**: 已完成

## 阶段 2: strict tool runner 实现
**目标**: 新增 DeepSeek 官方 strict tool mode 专用 runner，复用现有 prompt/schema 与 IR compiler。
**成功标准**: runner 能生成 DeepSeek strict tool schema，支持 outline 与 sampled atomization。
**测试**: 编译 runner，并执行 dry-run schema 输出。
**状态**: 已完成

## 阶段 3: 可用性验证
**目标**: 若配置了 `DEEPSEEK_API_KEY`，用 `deepseek-v4-flash` 与 `deepseek-v4-pro` 跑 smoke/full 测试。
**成功标准**: 成功写出 run_index，或明确记录官方 API 返回的阻塞原因。
**测试**: 先单 fixture smoke，再按全部 fixture 执行。
**状态**: 已完成

## 阶段 4: 编译检查与收尾
**目标**: 运行 Swift 编译与 Xcode build 检查，整理最终结论。
**成功标准**: runner 编译通过，主工程构建通过或阻塞原因明确。
**测试**: `xcrun swiftc` + `xcodebuild build`。
**状态**: 已完成

## 阶段 5: deepseek-v4-pro atomization 补跑
**目标**: 复用已有 outline，单独补跑 `deepseek/deepseek-v4-pro` 的 atomization 样本。
**成功标准**: 成功写出 pro atomization snapshot，或明确记录失败原因。
**测试**: 使用同一结果目录、`concurrency=1` 重跑 pro，并汇总 run_index。
**状态**: 已完成
