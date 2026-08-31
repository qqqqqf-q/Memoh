# Session 模型与推理强度持久化 · 设计稿

- **Issue:** memohai/Memoh#879 — [Web] Chat session 模型切换未持久化,刷新后回退 bot 默认模型
- **状态:** 设计已拍板(2026-08-25 ~ 08-31),未实现
- **参照:** lobe-chat PR #15933 / #18178(独立同构演化,见 §8)
- **读法:** §1.1 修复前路径 / §1.2 修复后路径 是本稿的骨架,机制(§3-§5)只服务于路径;§7 定义三层验证。

## 1. 问题

模型与 reasoning effort(下称 effort)的选择只存在于 ChatPane 组件实例的本地 ref(`chat-pane.vue:1008-1012`)。生命周期 = 一个 pane 实例的生命周期,产生两个用户可见症状:

- **症状 1:** session 内选了非默认模型,二次请求切回老模型 —— pane 重建(刷新/关 tab 重开/ephemeral 被顶/切 bot)后重新从 bot 默认播种。
- **症状 2:** 进入历史 session 带着 welcome 页选的模型 —— dockview repoint 不重重挂载,只清 `userPickedModel` flag 不清值(`chat-pane.vue:2138-2140`),残留值随每条消息显式发出,顶掉后端本可走的 session 历史 fallback。

后端现状:能收(WS/REST 每轮 override)、会用(当轮)、**不存**(`bot_sessions` 无相关列,139 个增量迁移无一涉及)。composer 永远显式发 `model_id`,后端 session 历史 fallback(`service_model_selection.go:24`)是死路。

### 1.1 修复前的用户路径(现状,逐条可复现)

以下路径按"今天会发生什么"记录,是本设计要消灭的行为。**P1/P2 是投诉原文(xhe 2026-08-14、Go 2026-07-29),其余从代码推出。**

| # | 用户动作 | 今天实际发生 |
|---|---|---|
| P1 | 在 session 里把模型切到 2,发消息,刷新页面 | composer 变回模型 1(bot 默认);下一条消息**静默用模型 1 发出**(用户以为还在用 2) |
| P2 | welcome 页选了模型 2 不发;打开上周用模型 3 的历史 session | composer 显示模型 2,并且**发出的每条都带 model_id=2**,session 被迫用错模型 |
| P3 | 手机/另一台电脑打开"模型 2"那个 session | 显示模型 1(值只在本机 pane 内存里) |
| P4 | 关 tab 重开、ephemeral tab 被顶后重开、切 bot 再切回 | 同 P1,回模型 1 |
| P5 | ACP(Codex/CC)会话 effort 选 max,发对话或刷新 | 回退 medium(Go 2026-08-18 实测) |
| P6 | effort 切到不支持推理的模型再切回 | 原档位丢失,不恢复(此条**保留**,非目标) |
| P7 | 弱网下切模型 | 能切(乐观 ref),但刷新即丢 |

### 1.2 修复后的目标用户路径(同一批场景,验收基准)

**P1′ 刷新不丢:** session 内切到模型 2 → picker 立即显示 2(PATCH 异步落库)→ 刷新 → 仍显示 2 → 发消息用 2。

**P2′ 会话隔离:** welcome 选 2 不发 → 打开历史 session(它上次用的是 3)→ composer 显示 **3**;回到 welcome 仍显示 2(草稿)。welcome 选 2 发首条 → 新 session = 2;回 welcome 仍显示 2(此时 2 = 该 bot 最近 session 的 preference,多设备一致)。

**P3′ 跨设备:** 桌面把某 session 切到模型 2(正常网络)→ 手机打开该 session → 显示 2 → 不碰 picker 直接发 → 用 2。**换设备场景自此与刷新同权**,preference 在服务端。

**P4′ pane 生命周期无关:** 关 tab 重开 / ephemeral 被顶后重开 / 切 bot 再切回 → 播种链重新解析,session 显示自己的值。

**P5′ ACP 不回退:** effort 选 max,刷新/重开/进程重建 → 仍 max(DB 双写 + 冷启动 replay)。

**P6′ 保留 P6:** 切到不支持推理的模型,effort 落到该模型合法档(不报错);切回不恢复原档。

**P7′ 弱网:** 切模型 → picker 立即变,永不回滚;PATCH 静默失败;任何一条消息发出去 → 模型 2 永久落库,之后刷新/换设备都是 2。残余窗口:切了但一条没发就刷新 → 回旧值(网卡,可理解,已接受)。

**不变路径(回归基准):** Telegram 等渠道对话逐字节不变;subagent pin、retry/edit 语义不变;运行中 turn 不受 picker 影响(发送时捕获,现状保留)。

### 1.3 路径与机制的映射(每条症状指向哪个机制)

| 路径 | 依赖机制 | 章节 |
|---|---|---|
| P1′/P3′/P4′ | preference 两列 + 服务端写回 + 播种链 | §3.1/3.2/3.3/3.4 |
| P2′ | repoint 重播种 + 草稿 + 最近 session 种子 | §3.4、§4-2/3/4 |
| P5′ | ACP 双写 + replay | §3.5 |
| P7′ | 纯乐观 + 写回兜底 | §3.3 |
| 不变路径 | 渠道请求不带 model_id → preference 恒 NULL | §3.1 |

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
- 换设备打开 session(用户核心场景:桌面为难题切了模型 2,手机打开):正常网络下切换即 PATCH 落库,手机播种链第一级命中 → 显示模型 2,不碰 picker 直接发也用 2。与刷新同权。
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

## 7. 验证:问题证明 → 路径正确性 → 执行正确性

验证分三层,各答一个问题:**问题是真的吗** / **修完的路径对吗** / **spec 被正确执行了吗**。AI 负责前两层的可自动化部分与全部证据准备;第三层的 happy path 由人类 QA 终审(§7.4)。

### 7.1 问题证明(修复前,可先做)

在当前 main 上按 §1.1 逐条复现并留证:每条路径记录"用户动作 → 观察到的错误值 + 证据"(截图/网络面板里 WS payload 的 model_id/服务端日志解析出的模型)。P1/P2/P5 已有群聊实测记录,此步是把剩余路径补齐并统一成证据包。**这同时是 §7.3 回归对比的基线。**

### 7.2 路径正确性(设计本身的证明)

设计级断言,实现前即可评审:

- 播种链的每一级有唯一所属(草稿=本设备未发送、最近 session=服务端已发送、bot 默认=渠道与首次、平台默认=兜底),四级互斥且穷尽"值从哪来"——**P1′–P7′ 每条都能沿链推出唯一确定值**,不存在推不出的路径;
- NULL 语义使渠道行为与 today 逐字节一致(渠道请求不带 model_id → 不写回 → 解析链与现状同形);
- 弱网退化窗口显式且有界(§3.3),不存在"picker 自己弹回"的路径。

### 7.3 执行正确性(实现与 spec 的一致性)

- **机制级测试(AI 写,可自动):** 解析链优先级(selectChatModel 插级后的四级顺序);PATCH reconcile(非法档位 → 默认档,不落非法值);写回仅在请求带 model_id 时发生;播种链各级回退;pending-writes 对账(PATCH 未确认时 refetch 不回滚);ACP 冷启动 replay 携带 DB 值。
- **路径级脚本(AI 跑,对照 §1.2):** 每条 P′ 路径写成可重复步骤(含弱网:devtools 断 PATCH;跨设备:两个浏览器 profile),输出"composer 显示值 + WS payload model_id + DB preference 值"三元组,三者一致才通过——**显示、发送、落库三处对齐**是本设计的核心不变量。
- **回归对照(§7.1 基线):** P6 保留不变;渠道路径在修复前后输出逐字节一致。

### 7.4 人类 QA(终审,不可代理)

§1.2 全部 P′ 路径 + 不变路径,由人走真实 happy path(真手机换设备、真 Telegram 会话)。通过标准:每条路径的 composer 显示 = 消息实际使用模型 = 换端后的显示,三处一致且符合 §1.2 预期。AI 的 §7.3 结果作为输入材料,不替代本层。

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
