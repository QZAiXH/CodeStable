---
doc_type: research
topic: loop-engineering
status: current
researched_at: 2026-06-14
audience: CodeStable maintainers and future feature developers
---

# Loop Engineering 研究与 CodeStable 开发指导

## 结论速读

Loop engineering 不是"多跑几轮 AI"。它是在 AI 编码流程外面设计一个可观测、可验证、可停止、可升级的控制回路，让系统承担低等级推进判断，让人只处理真正需要拍板的问题。

对 CodeStable 来说，`cs-loop` 的定位应该保持非常窄：它不是新的 feature / issue / refactor 流程，也不是通用 multi-agent 框架；它只是叠在 CodeStable 产物之上的控制层，用 `decision-codex` 做只读决策草案，用 `approval-codex` 做独立只读审批，用 `worker-codex` 做受限执行。

后续开发应坚持三个核心判断：

1. loop 的中心实体是软件工作流产物，不是 agent。
2. 自动化的对象是低风险推进判断，不是产品语义、架构、权限、安全、数据风险等高等级决策。
3. 低等级判断也不能由同一个 AI 会话自提自批；起草和审批必须拆成两个只读 Codex。
4. 每一轮必须留下状态、输入、输出、审批、验证、升级依据，不能依赖聊天上下文记忆。

## 概念来源

社区语境里的 loop engineering 近期主要指 Addy Osmani 在 2026-06-07 文章中提出的方向：从"写更好的 prompt"转向"设计可以持续替你提示、检查、修正 agent 的系统"。Codex 的 `codex exec`、Automations、Worktrees、Skills、Subagents、Sandbox / approvals 已经提供了这些原语。

CodeStable 的落地入口是 `README.md`、`cs/SKILL.md`、`cs-loop/SKILL.md`、`cs-loop/reference.md`、`cs-loop/tools/codex-loop.sh` 和 `cs-loop/tests/test-codex-loop.sh`：核心不是组织 agent 团队，而是给软件生命周期产物增加可恢复的控制回路。

## Loop Engineering 解决的问题

传统 AI 编码协作有三个常见断点：

1. 人要反复确认低等级步骤，例如"下一步跑哪个检查"、"是否进入下一条 checklist"。
2. agent 容易把上下文里的噪声当成权威，导致范围漂移或重复犯错。
3. 长任务靠会话记忆维持状态，一旦中断、换线程或模型压缩上下文，过程不可追溯。

Loop engineering 的目标是把这些断点工程化：

- 把状态放到文件里，而不是放在模型短期记忆里。
- 把"继续、升级、完成"做成显式状态机。
- 把执行任务切成可验证小步。
- 把人类拍板限定在语义、架构、风险和冲突类问题上。
- 把每一轮的决策依据、审批依据、worker brief、验证结果归档。

## CodeStable 中的具体定义

`cs-loop` 应定义为 CodeStable 之上的低等级决策控制层。

一个 loop 的基本流向：

```text
用户目标
  -> loop 控制层
      -> decision-codex：只读，起草继续 / 升级 / 完成
      -> approval-codex：只读，独立审批 / 退回 / 升级给人类
      -> worker-codex：可写，只按 worker-brief 执行
  -> CodeStable 产物：features / issues / refactors / compound / architecture
```

这和通用 agent orchestration 的区别很关键：

| 对比项 | 通用 agent 编排 | CodeStable loop engineering |
|---|---|---|
| 中心实体 | agent、角色、团队、消息流 | requirement、architecture、feature、issue、decision |
| 状态位置 | session、队列、memory | `.codestable/` 文件树 |
| 自动化目标 | 让 agent 更自治 | 让软件流程低风险连续推进 |
| 人的角色 | 越少介入越好 | 只处理高等级拍板和风险升级 |
| 完成标准 | agent 认为完成 | 有可检查证据和验证结果 |
| 多 agent 关系 | agent 彼此讨论和分工 | 起草 / 审批 / 执行是状态机 gate，不是自由讨论 |

## 核心角色边界

### decision-codex

权限应默认只读，典型命令是 `codex exec --sandbox read-only`。

它能起草：

- 选择 `active_workflow`：`cs-feat`、`cs-issue`、`cs-refactor`、`cs-audit`、`cs-explore`、`cs-decide`、`cs-learn`、`cs-trick`。
- 选择下一条 checklist / plan step。
- 根据既有 design、architecture、decision 排执行顺序。
- 判断 worker 是否按 brief 完成。
- 选择已有 lint / test / typecheck 命令作为验证动作。
- 把值得沉淀的经验路由到 `cs-learn` / `cs-trick` / `cs-decide`。

它不能做：

- 修改业务代码。
- 批准自己的 `CONTINUE` / `DONE` / `ESCALATE` 输出。
- 发明新的产品语义、默认策略或架构方向。
- 在缺少 CodeStable 产物边界时让 worker 直接写代码。
- 吞掉重复 blocker 或验证缺失。

### approval-codex

权限应默认只读，典型命令也是 `codex exec --sandbox read-only`，但必须是独立会话。

它能做：

- 独立读取 loop 目录、decision 输出、CodeStable 产物、git diff 和验证证据。
- 判断 decision proposal 是否低风险、证据充分、scope 清楚、能交给 worker。
- 输出 `APPROVED`、`REVISE` 或 `ESCALATE`。
- `REVISE` 时把问题退回 decision-codex，不打扰人类。
- `ESCALATE` 时写给人类的简要上下文报告。

它不能做：

- 修改业务代码或 CodeStable 产物。
- 自己发明替代方案并直接批准。
- 把产品语义、架构方向、长期约束、安全 / 权限 / 数据风险当成低等级问题放行。
- 因为 decision-codex 的语气自信而跳过证据检查。

### worker-codex

权限应默认 `workspace-write`，只能执行 `worker-brief.md`。

它能做：

- 在 brief 指定范围内改代码和相关 CodeStable 产物。
- 跑 brief 指定的验证命令。
- 汇报 changed files、verification result、blockers、suggested next decision。

它不能做：

- 自行扩大 scope。
- 自行改变产品语义、架构、长期约束。
- 在 brief 缺少 `active_workflow` 或 CodeStable 产物路径时继续执行。
- 把超出 brief 的问题"顺手修掉"。

### human

人只处理 approval-codex 升级后的报告。升级报告必须像高级秘书的汇报一样短而可拍板，包含：

- 上下文摘要。
- 需要拍板的问题。
- 可选方案。
- 推荐方案。
- 证据。
- 如果不决策会阻塞什么。

## 产物结构
每个 loop 应放在：

```text
.codestable/loops/{YYYY-MM-DD}-{slug}/
├── loop.md
├── state.yaml
├── decision-log.md
├── approval-log.md
├── worker-brief.md
├── human-escalation.md
├── human-decision.md
└── runs/
```

文件职责：

- `loop.md`：目标、范围、停止条件、角色权限。
- `state.yaml`：状态机当前值，例如 `status`、`iteration`、`next_actor`、`last_decision`、`last_approval`。
- `decision-log.md`：每轮 decision-codex 的判断草案和证据索引。
- `approval-log.md`：每轮 approval-codex 的审批结论和理由。
- `worker-brief.md`：worker-codex 本轮唯一任务单。
- `human-escalation.md`：approval-codex 写给人类拍板的报告。
- `human-decision.md`：人类拍板后的落盘记录，下一轮 decision-codex 必须读取。
- `runs/`：每轮原始输出归档。

重要约束：

- `loops/` 只存控制层状态，不存 feature / issue / refactor 正文产物。
- feature / issue / refactor 仍然必须落在各自目录。
- worker brief 必须指向具体 CodeStable 产物路径。
- 完成必须有验证证据，不能只写"看起来完成"。

## 状态机

`decision-codex` 每轮只允许输出三种 proposal 状态：

```text
LOOP_DECISION: CONTINUE
LOOP_DECISION: ESCALATE
LOOP_DECISION: DONE
```

含义：

- `CONTINUE`：已写出下一轮 worker brief，worker 可以执行。
- `ESCALATE`：需要人类决策，写入 `human-escalation.md` 后停止。
- `DONE`：完成证据充分，loop 结束。

`approval-codex` 随后只允许输出三种审批状态：

```text
LOOP_APPROVAL: APPROVED
LOOP_APPROVAL: REVISE
LOOP_APPROVAL: ESCALATE
```

含义：

- `APPROVED`：decision proposal 可以落地。若 decision 是 `CONTINUE`，才允许 worker 执行。
- `REVISE`：proposal 有缺口但不需要人类判断，退回 decision-codex 重写。
- `ESCALATE`：涉及重大决定或 approval 也无法判断，写 `human-escalation.md` 等人类拍板。

无法解析的 decision 输出优先交给 approval-codex 判断能否 `REVISE`；无法解析的 approval 输出才进入人类升级路径。

## 适用与不适用

适用：

- 已有 `.codestable/`，且工作目标、范围、停止条件明确。
- feature / issue / refactor 已经有足够产物支撑下一步。
- 用户想让 Codex 连续推进低等级步骤，但仍保留高等级拍板权。
- 需要对"为什么继续"、"为什么停下来"留痕。

不适用：

- 项目还没有 CodeStable 骨架。
- 用户目标本身还不清楚。
- 停止条件或验证方式完全缺失。
- 涉及无人值守发布、数据迁移、权限变更、安全策略变更。
- 想让多个 agent 自由讨论方案。

## 与 Codex 原语的映射

| 原语 | 对 `cs-loop` 的意义 | 使用建议 |
|---|---|---|
| `codex exec` | 脚本化单轮 decision / approval / worker | 保持 prompt 可复现，输出落盘 |
| Sandbox | 区分只读决策、只读审批和可写执行 | decision / approval 用 read-only，worker 用 workspace-write |
| Skills | 固化 workflow 规则 | `cs-loop` 是控制层 skill，不要替代子 workflow |
| Automations | 定时重复唤醒 loop | 先手动验证 prompt，再考虑计划任务 |
| Worktrees | 隔离后台 loop 改动 | 长任务或自动化建议跑在 worktree |
| Subagents | 并行读多写少探索 | 谨慎用于写代码，避免冲突 |
| External state | 保留可恢复状态 | 以 `.codestable/loops/` 为权威状态 |

## 后续开发原则

1. 先验证状态机，再扩展功能。任何新能力都应能落到 decision 的 `CONTINUE` / `ESCALATE` / `DONE` 和 approval 的 `APPROVED` / `REVISE` / `ESCALATE`。
2. 先约束 brief，再提升 worker 能力。worker 的自由度越高，loop 越容易失控。
3. 任何自动推进都必须绑定 `active_workflow` 和具体产物路径。
4. 缺少验证命令不是 worker 自行决定的问题，应由 decision 查文档，再由 approval 审批或升级。
5. 连续两轮同一 blocker 必须升级给用户。
6. 脚本不要吞掉 Codex 原始输出；原始输出要进 `runs/`。
7. 自动化默认不使用 `danger-full-access`；需要时应由用户明确创建受控环境。
8. worktree 支持应作为增强项，不应成为本地手动 loop 的前置条件。
9. `cs-loop` 文档更新时必须同步 `README.md`、`README.en.md`、`cs/SKILL.md`、`cs-onboard/reference/*` 中的路由和目录说明。
10. 单个 Markdown 文件不超过 300 行；超过就拆成主文档和 reference。

## 当前实现评估
当前实现已经从"最小闭环"推进到可用的 P0 控制层：

- `cs-loop/SKILL.md` / `reference.md` 明确角色、升级策略、产物结构、模板和 prompt skeleton。
- `tools/codex-loop.sh` 能跑 decision → approval → worker，并检查 `.codestable/attention.md`、`system-overview.md`、`shared-conventions.md`。
- 脚本支持 `--init` 完整初始化 loop 控制文件，校验 approved worker brief 必填字段，校验 human escalation 模板。
- worker 输出会提取 `verification result` 写入 `last_verification`，同一 blocker 连续两轮会升级给人类。
- 脚本测试用假的 `codex exec` 覆盖 DONE、ESCALATE、CONTINUE、APPROVED、REVISE、UNPARSEABLE、缺 brief 字段、连续 blocker，不消耗模型调用。

仍需长期改进：

- `ACTIVE_WORKFLOW` 解析依赖文本 grep，长期应考虑结构化输出或 schema。
- `decision-log.md` / `approval-log.md` 已有摘要和证据索引，但还不是机器可验证 schema。
- `runs/` 仍主要保存最终消息，尚未拆分 prompt、stdout、stderr 或 JSONL 事件。

## 建议的开发路线

### P0：把控制层跑稳

- 已完成：`--init`、worker brief 必填字段校验、ESCALATE 模板校验、`blocker_count` / `last_blocker_signature`、`last_verification` 提取、缺字段和连续 blocker 测试。
- 保持要求：后续每次改脚本都要补离线测试，不能让 P0 gate 回退。

### P1：提高可追溯性

- 把 decision 输出拆分为 decision summary、evidence、next action。
- `approval-log.md` 每轮记录审批关注点和是否发现自提自批风险。
- `decision-log.md` 每轮记录本轮读到的关键产物路径。
- `runs/` 下区分 prompt、stdout、stderr 或 JSONL 事件。
- 为 `human-escalation.md` 增加固定模板校验，尤其是面向人类的 Context Brief。

### P2+：自动化与工程化接口

后续再接 Automations / worktree 隔离、CI 权限基线、`codex exec --json` 或输出 schema、开发者调试指南，以及把 shell 状态更新逻辑抽成更可测的小模块。

## 开发检查清单
每次改 `cs-loop` 前检查：

- 这次改动是在控制层，还是不小心改了 feature / issue / refactor 语义？
- decision 是否仍然只读且不能自批？
- approval 是否仍然只读且先于 worker？
- worker 是否仍然只能按 brief 执行？
- 是否所有继续执行都能指向 `active_workflow` 和具体产物路径？
- 是否有明确停止条件和验证证据？
- 是否保留了用户拍板边界？
- 是否新增了脚本测试？
- 是否同步了共享路由文档？

参考资料：Addy Osmani 的 loop engineering 文章、OpenAI Codex 的 non-interactive / automations / worktrees / skills / subagents / sandbox 文档，以及本地源码 `README.md`、`cs/SKILL.md`、`cs-loop/*`。
