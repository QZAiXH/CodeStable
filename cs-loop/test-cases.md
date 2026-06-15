---
doc_type: test-plan
slug: cs-loop-test-cases
component: cs-loop
status: current
summary: cs-loop loop engineering 控制层的完整测试用例设计
last_reviewed: 2026-06-15
---

# cs-loop 测试用例

本文档覆盖 `cs-loop` 的脚本行为、角色边界、状态机、CodeStable 产物契约和端到端验收场景。用例来源：

- `CodeStable/README.md`
- `CodeStable/cs-loop/SKILL.md`
- `CodeStable/cs-loop/reference.md`
- `CodeStable/cs-loop/tools/codex-loop.sh`
- `CodeStable/cs-loop/tests/test-codex-loop.sh`

## 测试目标

`cs-loop` 的核心风险不是单个算法，而是控制层契约是否稳定。测试重点是：

1. CodeStable 骨架和目录契约正确。
2. decision-codex / approval-codex / worker-codex 三个角色的权限边界正确。
3. loop 状态机在 `CONTINUE` / `DONE` / `ESCALATE` / `REVISE` / `UNPARSEABLE` 下正确流转。
4. 每一轮都有可追溯产物，不依赖会话记忆。
5. 高风险或证据不足场景必须升级给人类，不能让 worker 自行决策。
6. 大需求能先走 `cs-roadmap` 拆解和审核，再隔离上下文逐条进入 `cs-feat`。

## A. CLI 与前置条件

| ID | 场景 | 前置 | 操作 | 期望 |
|---|---|---|---|---|
| A01 | 缺少 `--loop-dir` | 任意目录 | 执行 `codex-loop.sh` | exit `2`，输出 `--loop-dir is required` |
| A02 | 未接入 CodeStable | 无 `.codestable/` | 指定 `--loop-dir` 执行 | exit `3`，提示先 `cs-onboard` |
| A03 | `.codestable` 骨架不完整 | 缺 `attention.md` / `system-overview.md` / `shared-conventions.md` 任一文件 | 执行 | exit `4`，准确提示缺失文件 |
| A04 | 未安装 `codex` | PATH 中无 `codex` | 执行正常 loop | exit `127`，输出 `codex command not found` |
| A05 | loop 目录不存在 | 有 `.codestable`，但目标 loop-dir 不存在 | 执行 | 自动创建 `runs/` 和日志类文件；父路径不可写时失败清晰 |
| A06 | 查看帮助 | 任意 | 执行 `--help` | exit `0`，显示 usage |
| A07 | 未知参数 | 任意 | 执行 `--bad` | exit `2`，显示 unknown argument 和 usage |
| A08 | 空 human decision | 已有 loop | 执行 `--human-decision ""` | exit `2`，不调用 Codex，不写空决策 |

## B. 初始化产物

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| B01 | 首次运行创建 state | loop 目录无 `state.yaml` | 生成 `doc_type: loop-state`、`status: active`、`iteration: 0`、`next_actor: decision-codex` |
| B02 | 首次运行创建空日志 | loop 目录缺日志文件 | 创建 `decision-log.md`、`approval-log.md`、`worker-brief.md`、`human-escalation.md`、`human-decision.md`、`subtask-summary.md` |
| B03 | 保留已有 state | state 已存在且 `iteration: 3` | 不重置已有 state，仅按本轮流转更新必要字段 |
| B04 | 创建 runs 目录 | 无 `runs/` | 创建并写入 `*-decision-codex.md` / `*-approval-codex.md` / `*-worker-codex.md` |
| B05 | 更新日期字段 | 任一路径执行 | `state.yaml.updated` 更新为当天日期 |
| B06 | YAML 字符串转义 | human decision 或路径含引号、反斜杠 | `state.yaml` 中被合法双引号转义 |
| B07 | roadmap 状态字段 | 首次运行 | 初始化 `active_roadmap` / `active_roadmap_item` / `roadmap_stage` / `last_subtask_summary` |
| B08 | init 模式 | `--init --objective` | 生成完整 `loop.md` / state / log / brief 控制文件，不运行 Codex |

## C. Human Decision 模式

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| C01 | 记录人工决策 | `--human-decision "Choose Option A"` | 写入 `human-decision.md`，状态改为 `active`，`next_actor: decision-codex` |
| C02 | 不运行 Codex | human-decision 模式 | decision / approval / worker 均不调用 |
| C03 | 清除阻塞原因 | 原状态 `waiting-human` 或 `blocked` | `blocked_reason: null` |
| C04 | 记录决策指针 | human-decision 写入后 | `last_human_decision` 指向 `.codestable/loops/.../human-decision.md#STAMP` |
| C05 | 多次人工决策追加 | 连续执行两次 | `human-decision.md` 追加两条，不覆盖历史 |

## D. Decision 输出解析

| ID | 场景 | decision 输出 | 期望 |
|---|---|---|---|
| D01 | 标准 `CONTINUE` | 首行 `LOOP_DECISION: CONTINUE` | 解析为 `CONTINUE`，进入 approval |
| D02 | 标准 `DONE` | 首行 `LOOP_DECISION: DONE` | 解析为 `DONE`，仍需 approval 审批 |
| D03 | 标准 `ESCALATE` | 首行 `LOOP_DECISION: ESCALATE` | 解析为 `ESCALATE`，仍需 approval 审批 |
| D04 | 缺首行 | 任意文本 | `last_decision: "UNPARSEABLE"`，approval 自动走 revision 或后续阻塞 |
| D05 | 首行拼写错误 | `LOOP_DECISION: Continue` | 视为 `UNPARSEABLE` |
| D06 | 多个状态行 | 先 `CONTINUE` 后 `DONE` | 只取第一个合法状态 |
| D07 | active workflow 普通格式 | `Active workflow: cs-feat` | `state.active_workflow: "cs-feat"` |
| D08 | active workflow 反引号格式 | `Active workflow chosen: \`cs-issue\`` | 正确提取 `cs-issue` |
| D09 | active workflow 列表格式 | `- Active workflow: \`cs-refactor\`` | 正确提取 `cs-refactor` |
| D10 | 无 active workflow | `CONTINUE` 但无 workflow | approval 应 `REVISE`，不运行 worker |
| D11 | roadmap 元数据 | `Roadmap` / `Roadmap item` / `Roadmap stage` / `Previous subtask summary` | 同步写入 `state.yaml`，`null` 保持 YAML null |
| D12 | roadmap 元数据列表 / snake_case 格式 | `- active_roadmap:` / `- roadmap_item:` / `- previous_subtask_summary:` | 正确提取并写入 `state.yaml`，摘要中的引号和反斜杠合法转义 |

## E. Approval 输出解析

| ID | 场景 | approval 输出 | 期望 |
|---|---|---|---|
| E01 | `APPROVED` | 首行 `LOOP_APPROVAL: APPROVED` | 允许执行后续状态分支 |
| E02 | `REVISE` | 首行 `LOOP_APPROVAL: REVISE` | exit `22`，`status: needs-revision`，`next_actor: decision-codex` |
| E03 | `ESCALATE` | 首行 `LOOP_APPROVAL: ESCALATE` | exit `20`，`status: waiting-human`，`next_actor: human` |
| E04 | approval 不可解析 | 缺首行 | exit `23`，`status: blocked`，复制输出到 `human-escalation.md` |
| E05 | approval 多状态行 | 先 `REVISE` 后 `APPROVED` | 只取第一个合法状态 |
| E06 | approval 审批 decision 的 `ESCALATE` | decision=`ESCALATE`，approval=`APPROVED` | 仍进入 `waiting-human`，`human-escalation.md` 使用 approval 输出 |

## F. 状态机主路径

| ID | 场景 | 期望 |
|---|---|---|
| F01 | `DONE + APPROVED` | exit `0`，`status: done`，`next_actor: null`，不运行 worker |
| F02 | `ESCALATE + APPROVED` | exit `20`，`status: waiting-human`，`next_actor: human`，不运行 worker |
| F03 | `CONTINUE + APPROVED` | 复制 decision 输出到 `worker-brief.md`，运行 worker，完成后 `next_actor: decision-codex` |
| F04 | `CONTINUE + REVISE` | 不运行 worker，`status: needs-revision` |
| F05 | `CONTINUE + ESCALATE` | 不运行 worker，`human-escalation.md` 写入 approval 报告 |
| F06 | `UNPARSEABLE decision + APPROVED` | exit `21`，`status: blocked`，不运行 worker |
| F07 | `UNPARSEABLE decision + REVISE` | exit `22`，回 decision 修订 |
| F08 | worker 完成 | `iteration + 1`，`last_worker_result` 指向 runs 文件 |
| F09 | worker 失败 | exit 为 worker 状态，`status: blocked`，记录 `blocked_reason`，保留 worker 输出 |
| F10 | worker 输出 blocker | worker exit 0 但 `blockers` 非 none | exit 25，`status: blocked`，记录 blocker 签名和验证摘要 |
| F11 | 连续两轮同 blocker | 相同 blocker signature 连续出现 | 自动写 `human-escalation.md`，`status: waiting-human`，`next_actor: human` |

## G. 角色权限与调用参数

| ID | 场景 | 期望 |
|---|---|---|
| G01 | decision 调用 | `codex exec --sandbox read-only` |
| G02 | approval 调用 | `codex exec --sandbox read-only` |
| G03 | worker 调用 | 默认 `--sandbox workspace-write` |
| G04 | 自定义 worker sandbox | `CS_LOOP_WORKER_SANDBOX=read-only` 时 worker 使用该 sandbox |
| G05 | 自定义模型 | 设置 `CS_LOOP_DECISION_MODEL` / `CS_LOOP_APPROVAL_MODEL` / `CS_LOOP_WORKER_MODEL` 后三次调用分别带对应 `--model` |
| G06 | DONE 不调用 worker | Codex 调用次数为 2 |
| G07 | ESCALATE 不调用 worker | Codex 调用次数为 2 |
| G08 | REVISE 不调用 worker | Codex 调用次数为 2 |
| G09 | CONTINUE 调用 worker | Codex 调用次数为 3 |

## H. Prompt 内容契约

| ID | 检查对象 | 期望包含 |
|---|---|---|
| H01 | decision prompt | `.codestable/attention.md`、loop 目录、state、decision-log、approval-log、human-decision、worker-brief |
| H02 | decision prompt | 明确 `read-only`、不能批准自己、必须选择 `active_workflow` |
| H03 | decision prompt | 高风险升级规则：产品语义、架构、技术栈、安全、数据、冲突文档、缺验证、重复 blocker |
| H04 | approval prompt | 最新 decision 输出路径、parsed decision status |
| H05 | approval prompt | 只能 `APPROVED / REVISE / ESCALATE`，不能重写新方案直接给 worker |
| H06 | worker prompt | 只执行 `worker-brief.md`，缺 active workflow 或 artifact path 要停 |
| H07 | objective 透传 | 传 `--objective` 时 decision / approval prompt 包含该目标 |
| H08 | 无 objective | prompt 指示读取 `loop.md` |
| H09 | roadmap prompt | decision 做 size routing；approval 审核拆解；worker 遵守 Context Boundary / Previous Subtask Summary |

## I. CodeStable 绑定与产物边界

| ID | 场景 | 期望 |
|---|---|---|
| I01 | 新功能目标 | decision 选择 `cs-feat`，worker brief 指向 `.codestable/features/...` |
| I02 | bug 目标 | decision 选择 `cs-issue`，worker brief 指向 `.codestable/issues/...` |
| I03 | 重构目标 | decision 选择 `cs-refactor`，worker brief 指向 `.codestable/refactors/...` |
| I04 | 审计目标 | decision 选择 `cs-audit`，不直接修代码，只产出 audit 发现 |
| I05 | 探索目标 | decision 选择 `cs-explore`，产出 explore 证据到 `compound/` |
| I06 | 需要技术决策 | decision 不让 worker 写代码，升级或路由 `cs-decide` |
| I07 | 缺少 feature design/checklist | 不允许 worker 直接实现，应先补 CodeStable 文档草稿或升级 |
| I08 | loop 目录边界 | `loops/` 只存控制层文件，不存 feature / issue / refactor 正文产物 |
| I09 | worker brief 边界 | 必须含 `Task`、`Active Workflow`、`Inputs`、`Allowed Changes`、`Verification`、`Return Format` 和具体 CodeStable 产物路径 |
| I10 | worker 越界修改 | 端到端验收中检查 diff，超出 `Allowed Changes` 应由下一轮 decision/approval 阻断 |
| I11 | 大需求 size routing | 多子能力 / 跨模块契约 / DAG 目标先走 `cs-roadmap`，不直接进 `cs-feat` 写代码 |
| I12 | roadmap 拆解审核 | approval 检查模块边界、接口契约、items DAG、依赖理由和最小闭环，不合理则 `REVISE` |
| I13 | 子任务上下文隔离 | 新 item worker brief 缺 `Context Boundary` 或 `Previous Subtask Summary` 时 `REVISE` |

## J. 人类升级报告质量

| ID | 场景 | 期望 |
|---|---|---|
| J01 | 产品语义不明确 | `human-escalation.md` 包含 Context Brief、Question、Options、Recommendation、If Not Decided |
| J02 | 架构方向冲突 | 升级 human，说明冲突文档和可选方案 |
| J03 | 安全 / 权限 / 隐私 / 数据风险 | 必须升级，不进入 worker |
| J04 | 验证命令缺失且无法推断 | `REVISE` 或 `ESCALATE`，不能 `DONE` |
| J05 | CodeStable 文档互相冲突 | 升级 human，不让 approval 自行拍板 |
| J06 | worker 连续两轮同一失败点 | 升级 human，报告 blocker 和证据 |
| J07 | ESCALATE 模板缺章节 | approval 输出缺 Context Brief 等必填章节 | exit 24，状态 blocked/human，不运行 worker |

## K. 可追溯性

| ID | 场景 | 期望 |
|---|---|---|
| K01 | 每轮 decision | `decision-log.md` 追加时间戳、runs 输出路径、Status、Decision summary、Evidence index |
| K02 | 每轮 approval | `approval-log.md` 追加时间戳、runs 输出路径、Reviewed decision、Status、Approval rationale、Evidence index |
| K03 | worker 输出 | `runs/*-worker-codex.md` 保留原始输出 |
| K04 | `worker-brief.md` | `CONTINUE` 时提取 `# Worker Brief` 正文并通过脚本必填字段校验 |
| K05 | `human-escalation.md` | ESCALATE 或不可解析 approval 时写入可读上下文 |
| K06 | 运行多轮 | 历史 log 追加，不覆盖旧记录 |
| K07 | 时间戳唯一性 | run 文件名带 UTC 时间和 PID，避免同秒同进程外的常见覆盖风险 |

## L. 端到端场景

| ID | 场景 | 流程 |
|---|---|---|
| L01 | 简单 feature 自动推进到完成 | 第 1 轮 `CONTINUE` 写文件，第 2 轮 `DONE`，最终 `status: done` |
| L02 | bug 修复流程 | 先补 issue report / analysis，再 brief worker 修复，再 acceptance / done |
| L03 | 缺设计文档的新功能 | decision 让 worker 只创建 design 草稿，不直接改业务代码 |
| L04 | approval 驳回过宽 brief | decision 给出过宽 `Allowed Changes`，approval `REVISE` |
| L05 | 人类拍板后恢复 | decision `ESCALATE` -> human decision -> 下一轮 decision 读取 `human-decision.md` 后继续 |
| L06 | worker 报 blocker | worker 输出 blocker，下一轮 decision 根据 blocker 决定 revise / escalate |
| L07 | worker 完成但验证失败 | 下一轮不能 `DONE`，应继续修或升级 |
| L08 | worker 完成且验证通过 | approval 对 `DONE` 检查证据后批准完成 |
| L09 | roadmap 自动推进 | `cs-roadmap` 拆解通过后，逐条启动 planned 且依赖已 done 的 item 进入 `cs-feat` |
| L10 | item 完成后切换上下文 | 上一 item acceptance 回写 roadmap 后，下一 item brief 只携带短摘要，不携带上一轮完整上下文 |

## 现有测试覆盖情况

当前 `CodeStable/cs-loop/tests/test-codex-loop.sh` 已覆盖：

- A01-A03
- B08
- C01-C04
- D01-D12 的主要解析分支和 roadmap 元数据同步
- E01-E04 和 J07
- F01-F11
- G01-G09
- H09 prompt 合约
- I09、I11-I13 的脚本级约束，包含缺 `Return Format`、缺 `Context Boundary` 和缺 `Previous Subtask Summary` 分支

这些测试使用假的 `codex exec` 覆盖 `DONE` / `ESCALATE` / `CONTINUE` / 无法解析等分支，不消耗模型调用。

## 建议优先补充

建议优先把下列用例补成自动化测试：

1. 真实模型对 roadmap 拆解质量的前向验收：拆错粒度、循环依赖、接口契约含糊时是否会 `REVISE`。
2. 多轮 roadmap 闭环：`roadmap-draft -> item design -> impl -> accept -> next item -> DONE`。
3. 高风险场景的端到端模型验收：产品语义、架构、安全、数据风险必须升级 human。
4. 多轮普通 loop 的真实闭环：`CONTINUE -> worker -> decision -> DONE`。
5. `codex exec --json` / schema 输出接入后替换文本 grep 的兼容测试。

## 运行现有测试

```bash
bash CodeStable/cs-loop/tests/test-codex-loop.sh
```

期望输出：

```text
All cs-loop tests passed.
```
