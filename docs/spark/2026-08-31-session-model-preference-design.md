# Session 模型与推理强度持久化 · 设计稿

- **Issue:** memohai/Memoh#879 — [Web] Chat session 模型切换未持久化,刷新后回退 bot 默认模型
- **状态:** 设计已拍板(2026-08-25 ~ 08-31),未实现
- **参照:** lobe-chat PR #15933 / #18178(独立同构演化,见 §8)

## 1. 问题

模型与 reasoning effort(下称 effort)的选择只存在于 ChatPane 组件实例的本地 ref(`chat-pane.vue:1008-1012`)。生命周期 = 一个 pane 实例的生命周期,产生两个用户可见症状:

- **症状 1:** session 内选了非默认模型,二次请求切回老模型 —— pane 重建(刷新/关 tab 重开/ephemeral 被顶/切 bot)后重新从 bot 默认播种。
- **症状 2:** 进入历史 session 带着 welcome 页选的模型 —— dockview repoint 不重挂载,只清 `userPickedModel` flag 不清值(`chat-pane.vue:2138-2140`),残留值随每条消息显式发出,顶掉后端本可走的 session 历史 fallback。

后端现状:能收(WS/REST 每轮 override)、会用(当轮)、**不存**(`bot_sessions` 无相关列,139 个增量迁移无一涉及)。composer 永远显式发 `model_id`,后端 session 历史 fallback(`service_model_selection.go:24`)是死路。

## 2. 目标

1. 一个 session 的模型/effort 是这个 session 的属性:换 pane、刷新、关 tab、换设备,都不变。
2. welcome 的选择只跟随它创建的新 session,不漂进任何已存在的 session;发出去之后不丢。
3. 未主动选择过的值,行为与今天逐字节一致(bot 默认;IM 渠道零改动)。
4. 服务端是唯一真相源;picker 显示 = 服务端解析结果。
5. 任何时刻发出的消息,用的模型 = picker 当时显示的值。

## 3. 核心机制

### 3.1 存储

`bot_sessions` 加两列(schedule 0130 真实列先例):

```sql
preferred_chat_model_id     UUID REFERENCES models(id)  -- NULL = 从未主动选择
preferred_reasoning_effort  TEXT                        -- NULL 同上
```

- NULL = 跟随解析链,行为与今天一致。写回只发生在"请求显式携带 model_id"的 turn(web/REST 每条消息都带;渠道请求从不带)——因此 **IM 渠道的 session 行 preference 恒 NULL,零代码隔离**;web session 在首次发送后被写回(惰性快照,见 §3.3)。
- 写入时服务端 reconcile(档位对模型合法性),DB 永不存非法档位。
- `bot_history_messages` 补 `reasoning_effort` 列(现在每轮 effort 无记录)。

### 3.2 每轮解析链(在既有两级间插一级)

```
request override > session preference > bot 默认 > 历史 fallback(现状保留)
```

改动点仅 `selectChatModel` / `resolveReasoningConfig` 两处。

### 3.3 持久化时机:picker 纯乐观,落库靠服务端写回

```
picker 切到 X   → 纯乐观,秒切,永不阻塞、永不回滚
PATCH(尽力而为) → 提前持久化;失败静默,不弹错、不回滚
发送消息        → 消息本身带 model_id(现状),turn 完成后服务端把
                 实际用的模型/effort 写回 preference   ← 持久化兜底
```

- 弱网路径:能切、能看,发不出去是"发消息"被网限制,不是"换模型"被限制;任何一条消息发出去,X 就永久落库。
- 唯一退化窗口:切了 X、PATCH 失败、一条没发就刷新 → 回旧值(用户已接受:"网很卡,我能理解")。不加重试队列,下一次发送就是重试。
- **preference = 最近实际使用值**(服务端写回维护)。这一条同时替代了"创建即快照"(C4)与方向①的"last-used seed":web session 首次发送即被写回(事实快照);老 session 在下一次发送后获得 preference,此前打开时按播种链显示历史消息模型;未选过且未发过的 session 保持 NULL 跟随 bot 默认 —— 三个机制合成一个。
- 写回范围:仅当请求显式携带 model_id/effort 时写回(web/REST 行为;渠道请求不带,不写)。

### 3.4 播种链(打开 session / welcome 显示,低 → 高)

```
平台默认模型
< bot 默认(bots.chat_model_id)
< 最近活跃 native session 的 preference(查询,非存储;subagent pin / ACP 不计入)
< localStorage 未发送草稿(按 bot 维度,首发即清)
```

effort 同链,最底层换成模型自身默认档。

- welcome 语义:未发的选择草稿兜着(本设备);发了的跟着"最近在用"走(多设备同步);bot 默认只服务 IM 渠道 + 首次使用 —— web 不再以它为起点。
- 已存在的 session 打开时:preference > subagent pin > 历史消息模型 > bot 默认;repoint 时**重新播种**(修症状 2)。
- 运行中 turn 不受 picker 影响(发送瞬间捕获,现状不变):picker 是"下一发的模型"。

### 3.5 ACP(Codex/CC)

- 同两列;picker 切换时双写:活体进程 `session/set_model` + DB PATCH。
- agent 进程冷启动(spawn/resume/e2b 重建)时经 `applyPromptConfig` 把 DB 值 replay 给新进程 —— 治 2026-08-18 反馈的 effort 回退 medium。
- 真相方向:agent 在线时 agent 自报为真相(CLI `/model` 改了以它为准)、回填 DB;DB 只做冷启动种子。永不解冲突。

## 4. 前端改动清单

1. picker 切换 → 乐观 ref + best-effort PATCH(复用 session PATCH 端点,加两字段)。
2. repoint / 打开已有 session → 按播种链重新播种,替换现"只清 flag"逻辑;顺手删 `chat-list.ts:184-185` 死 ref。
3. welcome 草稿:模型/effort 两个字段进 `useComposerDrafts` 同机制,首发即清。
4. welcome 种子:最近 native session preference 查询(服务端出一条轻量接口或复用 session list 投影)。
5. 新 session 首发创建时写入当前值(PATCH 即写,不等发送完成)。
6. PATCH 未确认期间,任何 refetch 不得回滚显示值(pending-writes 对账,lobe 同坑已验)。

## 5. 后端改动清单

1. 迁移:两列 + `bot_history_messages.reasoning_effort`;同步更新 `0001_init.up.sql` 全量定义。
2. session PATCH 接受两字段,写入时 reconcile(非法档位 → 该模型默认档,静默)。
3. 解析链插级(§3.2)。
4. turn 完成后写回实际模型/effort 到 preference。
5. welcome 种子查询(最近活跃 native session 的 preference)。
6. ACP:PATCH acp-runtime 双写 DB;`applyPromptConfig` replay(§3.5)。

## 6. 非目标(本期不做)

- 多 tab ws 实时模型同步(刷新后一致即通过)
- 逐条消息模型/effort 的 UI 投影展示
- IM 渠道 `/model` 命令写 session preference
- composer 改"仅显式选择才发 model_id"
- effort per-(user, model) 全局偏好层(lobe 式第二张表)
- effort 跨不兼容模型切换后的恢复记忆(D2:不恢复,与今天一致)

## 7. QA 验收路径

1. 会话内换模型连发两条 → 都用所选
2. 换模型后刷新 → 保持
3. 关 tab 重开同 session → 保持
4. welcome 选不发,开老会话 → 老会话显示自己的
5. welcome 选并发首条 → 新会话记住;**回 welcome 仍显示它**(最近 session 种子)
6. welcome 选直接刷新 → 保持(仅本设备,草稿)
7. 换设备开同 session → 保持
8. Telegram 等渠道照常 → 零变化
9. ACP effort 选 max 刷新 → 保持,不回 medium
10. 弱网(断 PATCH)切模型 → picker 立刻生效不回滚;消息发出后刷新仍保持
11. 老 session(无 preference,历史是 Claude)打开 → 显示 Claude
12. effort 切到不支持推理的模型 → 落到合法值且不报错(none/Close 类 400 永不再现)

## 8. 取舍记录

| 决策点 | 采纳 | 否决及其原因 |
|---|---|---|
| 主方向(#879 三选一) | ②preference 列 + PATCH | ①last-used seed 只治一半(effort 无历史可 seed);③ACP 那套本身不落库 |
| welcome 选择语义 | 草稿 + 最近 session 种子链 | lobe 式写 agent 默认 = channel 地狱(bot 默认被 IM 每轮实时消费);新造"前端默认模型"实体 = 概念负担 |
| effort 层级 | per-session 与模型同构 | lobe 式 per-(user,model) 全局层 = 第二张表、两套解析,ACP 的 effort 仍得 per-session,两套并存 |
| 弱网 PATCH 失败 | 纯乐观 + 服务端写回兜底 | "失败回滚" = 网卡时不让换模型,最差路径(用户原话:"5 秒后改回去,这很逆天") |
| ACP | 双写 + 冷启动 replay | lobe 式"CLI 自报不落库" = cloud/e2b 重启丢 agent 文件后无记录,治不了 8/18 的回退 |
| C4 快照语义(默认,随 §3.3 消解) | 写回即事实快照,不做创建时快照 | lobe 创建时快照会给"从未选择也从未发送"的 session 也定死值;写回方案下未发过的 session 保持 NULL 跟随 bot 默认,少一次写,行为差异仅在"从未发送的空 session"上 |
| D2 effort 恢复(默认) | 不恢复 | 与今天一致,不引入 per-model 记忆 |
| E3 ACP 真相(默认) | agent 在线赢,DB 冷启动种子 | 不写冲突解决逻辑 |

**lobe 参照结论:** PR #15933(arvinxx,2026-06-16 创建/07-22 合并)。模型 per-topic pin(创建快照 + topic 内切换 UPDATE)与本设计同构;分歧在 effort 层级(他们 per-user-model)与 welcome 语义(他们写 agent 默认)。异构 agent 他们不存模型、CLI per-run 自报,我们不抄(见上表)。其 pending-writes 对账(乐观写防 refetch 冲掉)直接采纳。

## 9. 实现顺序

1. DB 迁移 + sqlc
2. session PATCH(reconcile)+ 解析插级 + 写回
3. welcome 种子查询
4. 前端:乐观 PATCH、repoint 重播种、草稿两字段、pending-writes 对账
5. ACP 双写 + replay
6. QA §7 全表
