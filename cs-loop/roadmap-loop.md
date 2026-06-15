# cs-loop roadmap 编排规则

本文件只在 loop 目标可能超过单 feature 时读取。它补充 `reference.md`，不替代 `cs-roadmap` / `cs-feat` 的原流程。

## 1. size routing

decision-codex 第一轮先判断任务大小，不能直接默认 `cs-feat`。

走 `cs-feat` 的信号：

- 一个 design 能讲清全部名词、编排、验收契约
- 实现步骤虽多，但最终只交付一个可独立验收的能力
- 不需要先定义多个 feature 共享的接口契约
- 不需要依赖 DAG，最多是同一 feature 内的 checklist 顺序

走 `cs-roadmap` 的信号：

- 用户说的是一个系统 / 中心 / 平台 / 长期能力集合
- 明显有多个可独立上线或验收的子能力
- 涉及多个模块，且需要先约定接口契约 / 共享协议 / 数据结构
- 子能力之间有技术依赖，适合写成 DAG
- 第一条做完只能提供最小闭环，后续还要继续扩展

判断不出时不要让 worker 写代码。可以让 worker 做 `cs-brainstorm` / `cs-roadmap` 草稿，或让 approval-codex 升级给人类。

## 2. roadmap 阶段状态

roadmap loop 使用这些状态字段辅助追踪：

```yaml
active_workflow: cs-roadmap | cs-feat
active_roadmap: "{roadmap slug}" | null
active_roadmap_item: "{item slug}" | null
roadmap_stage: routing | roadmap-draft | roadmap-review | feature-design | feature-impl | feature-accept | completed
last_subtask_summary: "{one-line summary}" | null
```

decision-codex 在输出中写同名元数据行，脚本会同步到 `state.yaml`。

## 3. roadmap 拆解轮

首次选择 `cs-roadmap` 时，worker brief 必须限定为规划产物：

- `Active Workflow`: `cs-roadmap`
- `Roadmap`: `{slug}`
- `Roadmap stage`: `roadmap-draft`
- `Allowed Changes`: `.codestable/roadmap/{slug}/{slug}-roadmap.md`、`{slug}-items.yaml`、必要 drafts
- `Do Not Change`: 业务代码、feature 目录、requirements、architecture
- `Verification`: `validate-yaml.py --file ... --yaml-only`

worker 只执行 `cs-roadmap new/update` 的落盘动作，不启动任何子 feature。

## 4. 拆解审核

approval-codex 审核 roadmap 拆解时，按 `cs-roadmap` 的退出条件检查：

- 模块拆分是否能一句话讲清每个模块职责
- 第 4 节接口契约是否具体到签名 / 字段 / 错误码，或明确无跨模块接口
- items.yaml 是否是 DAG，无自依赖和循环依赖
- 每条 item 是否能独立走完 `cs-feat`，不是半个实现步骤
- `minimal_loop: true` 是否唯一，且真能跑通最窄端到端路径
- 依赖理由是否具体到前置产物，不是"先做 A 再做 B"
- 技术依赖之外的产品优先级是否被 AI 偷偷决定

结果规则：

- 可通过改文档修正：`REVISE`
- 需要人类选择产品优先级、架构方向、范围取舍：`ESCALATE`
- 拆解合理且边界清楚：`APPROVED`

`APPROVED` 不代表直接写代码，只代表下一轮可以从 items.yaml 选择第一条可启动 item。

## 5. 选择下一条 item

decision-codex 每轮只启动一条 item。

选择顺序：

1. 读取 `{roadmap}-items.yaml`
2. 过滤 `status: planned`
3. 确认 `depends_on` 全部为 `done`
4. 优先选择 `minimal_loop: true`
5. 其余按技术依赖顺序；产品优先级不清楚时升级

不得跳过未完成依赖。不得同时启动两条 item。

## 6. 进入 cs-feat

启动 item 的 worker brief 必须使用 `cs-feat-design` 的"从 roadmap 条目起头"入口：

- `Active Workflow`: `cs-feat`
- `Roadmap`: `{roadmap slug}`
- `Roadmap item`: `{item slug}`
- `Roadmap stage`: `feature-design`
- `Inputs`: roadmap 主文档、items.yaml、目标 item、相关 req / arch、当前代码
- `Allowed Changes`: 目标 feature 目录和 items.yaml 的该 item 状态字段

之后同一 item 继续按 `feature-design → feature-impl → feature-accept` 推进。`cs-feat-accept` 完成并回写 roadmap 后，才允许选择下一条 item。

## 7. 子任务上下文隔离

每次开始新的 roadmap item，必须把上一条 item 的完整上下文切断。

worker brief 必须有两节：

```md
## Context Boundary

This is a fresh roadmap item. Read only the inputs listed in this brief, the target roadmap docs/items, target feature artifacts, relevant architecture/requirements, and current code. Do not read previous feature directories, old worker outputs, or prior conversation context unless explicitly listed below.

## Previous Subtask Summary

- 完成了 `{previous item}`，产物在 `{acceptance path}`
- 稳定契约变化：{1-2 bullets}
- 验证证据：{command / acceptance result}
- 留给本 item 的约束：{1-2 bullets}
```

摘要只保留会影响下一条 item 的稳定事实：

- 已完成能力的可观察结果
- 已写入 architecture / roadmap 的接口契约变化
- 验证命令和结果
- 仍需遵守的约束或未决问题

不要传：

- 上一轮完整聊天记录
- worker 原始输出全文
- 上一条 feature 的内部实现细节
- 已被 acceptance 吸收进 architecture / roadmap 的重复解释

## 8. 完成判断

roadmap loop 只有在以下条件同时满足时才能 `DONE`：

- items.yaml 所有条目都是 `done` 或 `dropped`
- roadmap 主文档状态已同步为 `completed`，或明确有 `paused` 的人类决策
- 每个 `done` item 都有 feature acceptance 报告
- acceptance 已完成 roadmap 回写和必要 architecture / req 回写
- 最终验证证据覆盖 loop 的 stop condition

只完成当前 item 时不能 `DONE` 整个 loop，只能回到 decision-codex 选择下一条 item。
