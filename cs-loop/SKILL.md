---
name: cs-loop
description: 搭建和运行 CodeStable 上的 loop engineering 控制层，用 decision-codex 起草低等级推进判断、approval-codex 独立审批、worker-codex 实际执行。触发：用户说 loop engineering、自动循环、多个 Codex 配合、低等级决策代理、让 Codex 自己推进但保留人类拍板。
---

# cs-loop

## 启动必读

开始任何判断或动作前，先读取 `.codestable/attention.md`；缺失则视为骨架不完整，提示先运行 `cs-onboard`。再读取 `.codestable/reference/system-overview.md` 和本技能 `reference.md`。

`cs-loop` 是 CodeStable 之上的控制层，不替代 `cs-feat` / `cs-issue` / `cs-refactor`。它只解决一个问题：把原本需要用户反复做的低等级推进判断，交给只读的 decision-codex 起草，再交给独立只读的 approval-codex 审批；把实际改代码、跑验证交给 worker-codex。

```
用户目标
  -> loop 控制层
      -> decision-codex：只读，起草下一步 / 完成判断 / 升级草案
      -> approval-codex：只读，独立审批 decision 输出 / 生成给人类的上下文报告
      -> worker-codex：可写，只按 brief 执行，不自作产品或架构决定
  -> CodeStable 产物：features / issues / refactors / compound
```

## 适用场景

- 用户希望 Codex 能连续推进任务，但不想每个小判断都手动确认
- 已有 CodeStable 流程太依赖用户 checkpoint，想把低风险 checkpoint 自动化
- 需要把"AI 为什么继续做 / 为什么停下来问人"留成可追溯记录
- 希望一个 Codex 起草推进判断、一个 Codex 独立审批、另一个 Codex 当执行工程师

不适用：

- 用户想完全无人值守上线 / 发版 / 数据迁移
- 项目还没有 `.codestable/`
- 没有明确目标、停止条件或验证方式
- 希望多个 agent 自由讨论方案；`approval-codex` 只做审批，不和 decision 自由辩论

## 与 CodeStable skills 的绑定

本技能不是通用 multi-agent 编排器。每一轮都必须先落到 CodeStable 现有 workflow 上，再让三个 Codex 按"起草 → 审批 → 执行"协作。

decision-codex 必须先选一个 `active_workflow`：

| 场景 | workflow |
|---|---|
| 新功能 / 需求变更 | `cs-feat`，必要时前置 `cs-brainstorm` / `cs-roadmap` |
| bug / 异常 / 文档错误 | `cs-issue` |
| 行为不变的结构优化 | `cs-refactor` |
| 主动扫描风险但不定修 | `cs-audit` |
| 调研问题并沉淀证据 | `cs-explore` |
| 长期约束 / 技术选型 | `cs-decide` |
| 踩坑经验 / 复用处方 | `cs-learn` / `cs-trick` |

worker brief 必须写明：

- `active_workflow`
- 本轮对应的 CodeStable 产物路径，例如 feature design / checklist、issue analysis / fix-note
- 本轮只允许执行哪一个阶段
- 本轮完成后要回写哪个 CodeStable 产物

如果没有足够的 CodeStable 产物支撑执行，decision-codex 不能让 worker 直接写代码。它只能先让 worker 补齐对应流程的文档草稿，或升级给用户。

approval-codex 必须在 worker-codex 运行前独立检查 decision-codex 的输出。它不能改代码，也不能把自己的新方案直接交给 worker；它只能输出：

- `APPROVED`：decision 输出是低风险、边界清楚、证据充分，可以按原决定继续
- `REVISE`：decision 输出有遗漏但仍属于低等级问题，退回 decision-codex 重写，不打扰用户
- `ESCALATE`：涉及重大决定、证据冲突、自己也无法判断，写一份给人类拍板的简要上下文报告

## 角色边界

### decision-codex

权限：只读。建议用 `codex exec --sandbox read-only`。

能起草的低等级判断：

- 在 `cs-feat` / `cs-issue` / `cs-refactor` / `cs-audit` 之间路由
- 选择下一条 checklist / plan step
- 基于既有 design、decision、architecture 选择实现顺序
- 判断 worker 是否按 brief 完成，是否可以进入下一轮
- 选择已有测试 / lint / typecheck 命令作为验证动作
- 把重复踩坑沉淀建议路由到 `cs-learn` / `cs-trick` / `cs-decide`
- 拒绝没有 `active_workflow` 和 CodeStable 产物路径的 worker brief

decision-codex 的输出默认只是 proposal。即使它输出 `CONTINUE` / `DONE` / `ESCALATE`，也必须先经过 approval-codex 审批，不能批准自己的方案。

必须升级给用户：

- 产品语义、用户可见行为、默认策略没有被文档定义
- 技术选型、架构方向、长期约束需要新拍板
- 可能破坏数据、权限、安全、隐私、兼容性
- 现有 CodeStable 文档互相冲突，或文档与代码冲突
- worker 连续两轮卡在同一失败点
- 验证命令缺失且不能从项目文档合理推断

### approval-codex

权限：只读。建议用 `codex exec --sandbox read-only`，最好使用独立模型配置或独立会话。

职责：

- 独立读取 loop 目录、decision 输出、相关 CodeStable 产物、git diff 和验证证据
- 检查 decision 是否有证据、是否绑定 `active_workflow`、是否把 scope 约束进 CodeStable 产物路径
- 检查 worker brief 是否完整、可执行、不会让 worker 自行拍产品 / 架构 / 安全 / 数据决定
- 对 `DONE` 检查验证证据是否足够；没有证据只能 `REVISE` 或 `ESCALATE`
- 对 `ESCALATE` 生成面向人类的上下文报告，像高级秘书一样把问题、选项、建议和阻塞点压缩清楚

不能做：

- 修改代码或 CodeStable 产物
- 自己重写一个新方案并直接批准
- 把产品语义、架构方向、技术选型、权限 / 安全 / 数据风险当成低等级问题放行
- 因为 decision-codex 看起来自信就跳过证据检查

### worker-codex

权限：可写。建议用 `codex exec --sandbox workspace-write`。

职责：

- 只执行 `worker-brief.md` 指定范围
- 优先使用对应 CodeStable 子流程产物
- 如果 brief 没有 `active_workflow` 或没有指向 CodeStable 产物路径，停止并报 blocker
- 小步修改，跑 brief 指定验证
- 不能自行改变目标、范围、架构或产品语义
- 遇到超出 brief 的问题，写 blocker，交回 decision-codex

### 用户

用户只处理 approval-codex 升级后的报告，不处理低等级推进判断。升级报告必须包含：上下文摘要、需要拍板的问题、可选方案、推荐方案、证据、如果不决策的后果。

## loop 产物

每个 loop 一个目录：

```
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

含义：

- `loop.md`：目标、范围、停止条件、角色权限
- `state.yaml`：当前状态、下一执行者、迭代次数、最近验证结果
- `decision-log.md`：decision-codex 的每次判断草案
- `approval-log.md`：approval-codex 的每次审批结论
- `worker-brief.md`：worker-codex 本轮任务单
- `human-escalation.md`：approval-codex 写给用户拍板的上下文报告
- `human-decision.md`：用户拍板后的落盘记录，下一轮 decision-codex 必须读取
- `runs/`：每轮原始输出归档

## 工作流

### 1. 初始化 loop

如果 `.codestable/loops/` 不存在，创建它。为本次目标创建 `YYYY-MM-DD-{slug}` 目录，并按 `reference.md` 模板写入五个文件。

初始化时必须写清楚：

- objective：最终要达成什么
- scope：允许动什么，不允许动什么
- stop_condition：什么证据算完成
- verification：最小验证命令；不知道就写 `TBD` 并让 decision-codex 第一轮查
- escalation_policy：本技能的升级规则，可追加项目特有规则

### 2. decision-codex 产出 decision proposal

decision-codex 读取 loop 目录、相关 `.codestable/` 产物、代码现状，只起草三种状态之一：

- `CONTINUE`：写入下一轮 `worker-brief.md`
- `ESCALATE`：写入 `human-escalation.md`，等待用户
- `DONE`：说明完成证据，loop 结束

decision-codex 不修改业务代码。

### 3. approval-codex 审批 proposal

approval-codex 读取 decision 输出和同一组证据，只输出三种状态之一：

- `APPROVED`：允许执行 decision 输出
- `REVISE`：退回 decision-codex 重写；本轮不运行 worker，也不打扰用户
- `ESCALATE`：写入 `human-escalation.md`，等待用户

approval-codex 不负责想新方案。它只回答：这个 proposal 能不能在当前 CodeStable 证据下被低风险放行。

### 4. 用户拍板后恢复

当状态停在 `waiting-human` 时，用户的回答必须先写入 `human-decision.md`，再交回 decision-codex。脚本支持：

```bash
bash <skill-dir>/tools/codex-loop.sh \
  --loop-dir .codestable/loops/YYYY-MM-DD-slug \
  --human-decision "用户选择 Option A，先更新需求文档"
```

这一步只落盘人类决策并把 `state.yaml` 改回 `status: active` / `next_actor: decision-codex`，不会运行 Codex。下一次正常运行 loop 时，decision-codex 读取 `human-decision.md`，把人类拍板转换成新的低等级 proposal，再交给 approval-codex 审批。

### 5. worker-codex 执行

worker-codex 读取 `worker-brief.md`，执行其中的步骤。它可以改代码和 CodeStable 产物，但只能在 brief 范围内改。完成后在最终输出里写：

- changed files
- verification result
- blockers
- suggested next decision

### 6. 迭代

worker 结束后回到 decision-codex。decision-codex 根据代码 diff、验证结果和 loop state 起草下一步，再由 approval-codex 审批。

## 可选脚本

本技能带一个单轮驱动脚本：

```bash
bash <skill-dir>/tools/codex-loop.sh \
  --loop-dir .codestable/loops/YYYY-MM-DD-slug \
  --objective "一句话目标"
```

它会按顺序运行：

1. `codex exec --sandbox read-only` 作为 decision-codex
2. `codex exec --sandbox read-only` 作为 approval-codex
3. approval 输出 `APPROVED` 且 decision 输出 `CONTINUE` 时，运行 `codex exec --sandbox workspace-write` 作为 worker-codex

脚本只跑一轮，适合手动或外部调度器重复调用。模型可用环境变量指定：

```bash
CS_LOOP_DECISION_MODEL=gpt-5.4-mini
CS_LOOP_APPROVAL_MODEL=gpt-5.4
CS_LOOP_WORKER_MODEL=gpt-5.4
CS_LOOP_WORKER_SANDBOX=workspace-write
```

## 验证本技能

修改脚本后跑离线测试：

```bash
bash cs-loop/tests/test-codex-loop.sh
```

它用假的 `codex exec` 覆盖 `DONE` / `ESCALATE` / `CONTINUE` / 无法解析等分支，不消耗模型调用。

## 守护规则

1. loop 只做控制层，不把 feature / issue / refactor 产物塞进 `loops/`
2. decision-codex 只起草，不许批准自己的方案
3. approval-codex 宁可 `REVISE` / `ESCALATE`，不许替用户拍高风险决策
4. worker-codex 只按已审批 brief 执行，不许扩大范围
5. 每轮都要有可追溯记录，不能只靠会话记忆
6. 连续两轮同一 blocker 必须升级
7. 完成必须有验证证据，不能只说"看起来完成"

## 退出条件

- [ ] loop 目录已初始化，或已有 loop 已被读取
- [ ] decision-codex / approval-codex / worker-codex 的下一步已明确
- [ ] 如果需要用户，`human-escalation.md` 已给出可拍板报告
- [ ] 如果完成，`decision-log.md` 和 `approval-log.md` 已记录完成证据和审批结论
