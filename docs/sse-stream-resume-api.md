# EasyAccounts — SSE 对话断点续传（中改）接口说明

面向：后端 Agent / easyaccount-agent 开发  
客户端：EasyAccount iOS (Swift)  
文档日期：2026-07-29  
状态：设计稿（待实现）  
关联：现有 `POST /api/chat` SSE；账户 / 分类 / 概览 REST 不变

---

## 0. 目标与非目标

### 目标

用户在 **打字机输出过程中** 将 App 切到后台（连接断开），再回到前台时：

1. 已输出的文字不丢失  
2. 能从断点继续收到后续 `message_delta`，恢复打字机效果  
3. 最终仍收到一次 `message_end`（或 `error`）

### 非目标

- 不改变鉴权方式（仍为 `Authorization: Bearer`）  
- 不要求客户端在断线期间保持长连接  
- 不做多端同时观看同一条流的复杂同步（可后续扩展）  
- 本阶段可不做「清空记忆」产品 API

---

## 1. 环境与通用约定

| 项 | 说明 |
|----|------|
| Base URL（本机） | `http://127.0.0.1:8088` |
| Base URL（公网） | `http://118.25.46.207:6088` |
| 鉴权 | `Authorization: Bearer <token>` |
| Content-Type（JSON 请求） | `application/json` |
| SSE | `Content-Type: text/event-stream` |
| 错误体（非流式） | `{ "message": "..." }`（无统一 code 信封） |
| 时区 | Asia/Shanghai |

**兼容策略：**

- 旧客户端只调 `POST /api/chat`、忽略未知字段 → 仍可用  
- 新客户端使用 `streamId` + `eventId` + 续传接口  

---

## 2. 概念模型

### 2.1 Stream（一轮对话生成）

| 字段 | 类型 | 说明 |
|------|------|------|
| `streamId` | string | 本轮流唯一 ID，建议 `s-` + ulid/uuid |
| `userId` | string/long | 归属用户 |
| `status` | enum | `running` \| `completed` \| `failed` \| `cancelled` |
| `fullText` | string | 截至当前已生成的完整助手文本 |
| `lastEventId` | long | 已发出的最大事件序号（从 1 递增；`started` 可为 0 或 1） |
| `createdAt` | datetime | 创建时间 |
| `updatedAt` | datetime | 最后写入时间 |
| `expireAt` | datetime | 过期时间，建议创建后 30 分钟 |

可选：持久化 `events[]`（每条 delta 一份）以便精确重放；也可只存 `fullText`，续传时对「客户端已有长度」之后的文本做切片补推（见 5.3）。

### 2.2 eventId

- 同一 `streamId` 内单调递增的整数  
- 同时建议在 SSE 帧上写标准字段 `id: <eventId>`，便于通用客户端  
- 客户端本地保存 `lastEventId`，续传时带 `afterEventId`

### 2.3 断线语义（关键）

| 场景 | 服务端行为 |
|------|------------|
| HTTP/SSE 连接断开（App 进后台、网络闪断） | **不**视为用户取消；生成任务继续，结果写入 Stream buffer |
| 客户端调用取消接口 | 停止生成，`status=cancelled`，释放用户 busy |
| 生成正常结束 | `status=completed`，保留 Stream 至 `expireAt` 供晚到的续传补齐 |
| 生成异常 | `status=failed`，可续传拿到 `error` 事件 |

---

## 3. 接口一览

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/api/chat` | 开始新一轮对话（扩展现有接口） |
| `GET` | `/api/chat/streams/{streamId}` | 按游标续传 / 补齐 SSE |
| `POST` | `/api/chat/streams/{streamId}/cancel` | 显式取消本轮生成 |
| `GET` | `/api/chat/streams/{streamId}`（非 SSE） | **可选** 查询流状态（JSON） |

---

## 4. POST /api/chat（开始一轮，兼容扩展）

### 4.1 请求

```http
POST /api/chat
Authorization: Bearer <token>
Content-Type: application/json
Accept: text/event-stream
```

```json
{
  "content": "今天午饭花了 35 元，记到微信"
}
```

字段与现网一致；**客户端无需传 streamId**。

### 4.2 成功：HTTP 200 + SSE

`Content-Type: text/event-stream;charset=UTF-8`

事件顺序仍为：

`started` → 若干 `message_delta` → `message_end`  
或中途 / 末尾 `error`

#### 4.2.1 帧格式（推荐同时带 SSE `id:`）

```text
id: 1
event: started
data: {"type":"started","content":"ok","streamId":"s-01HZX...","eventId":1}

id: 2
event: message_delta
data: {"type":"message_delta","content":"已","streamId":"s-01HZX...","eventId":2}

id: 3
event: message_delta
data: {"type":"message_delta","content":"记","streamId":"s-01HZX...","eventId":3}

id: 10
event: message_end
data: {"type":"message_end","content":"已记账：午餐 35.00 元…","streamId":"s-01HZX...","eventId":10}
```

#### 4.2.2 data JSON 字段

| 事件 | 必填字段 | 说明 |
|------|----------|------|
| `started` | `type`, `content`, `streamId`, `eventId` | `content` 固定 `"ok"` |
| `message_delta` | `type`, `content`, `streamId`, `eventId` | `content` 为增量文本 |
| `message_end` | `type`, `content`, `streamId`, `eventId` | `content` 为完整回复（全部 delta 拼接） |
| `error` | `type`, `message`, `streamId`, `eventId` | 本轮失败；HTTP 可能仍为 200 |

`type` 必须与 `event:` 名一致。

### 4.3 非流式 HTTP 错误（推流前）

与现网一致：

| HTTP | body | 场景 |
|------|------|------|
| 400 | `{ "message":"消息不能为空" }` | content 空 |
| 401 | `{ "message":"未登录或会话已失效" }` | token 无效 |
| 409 | `{ "message":"上一条消息仍在处理中" }` | 同用户已有 **其它** `running` 流 |

**409 细化（中改要求）：**

- 对**同一** `streamId` 的续传 **不得** 返回 409  
- 仅当用户已有 `running` 流且客户端又发起**新的** `POST /api/chat` 时返回 409  
- 可选增强：409 时 body 附带当前流，便于客户端改走续传：

```json
{
  "message": "上一条消息仍在处理中",
  "streamId": "s-01HZX...",
  "lastEventId": 12,
  "status": "running"
}
```

### 4.4 服务端实现要点（POST）

1. 创建 Stream，`status=running`，分配 `streamId`  
2. 占用用户 busy（与现网一致）  
3. 先发 `started`（含 `streamId`）  
4. 模型产出时：追加 `fullText`、递增 `eventId`、推 `message_delta`，并写入可重放存储  
5. **客户端断开连接时：不要取消模型任务**，继续写 buffer  
6. 结束时发 `message_end` 或 `error`，更新 `status`，释放 busy  
7. 超时：建议生成超时仍约 300s；Stream 记录保留约 30 分钟  

---

## 5. GET /api/chat/streams/{streamId}（续传 SSE）

### 5.1 请求

```http
GET /api/chat/streams/{streamId}?afterEventId=12
Authorization: Bearer <token>
Accept: text/event-stream
```

| 参数 | 位置 | 必填 | 说明 |
|------|------|------|------|
| `streamId` | path | 是 | POST 时 `started` 下发的 ID |
| `afterEventId` | query | 否 | 客户端已成功处理的最大 `eventId`；默认 `0` 表示从最早可重放点开始 |
| `Last-Event-ID` | header | 否 | 与 `afterEventId` 二选一；若都传，**以 query 为准** |

鉴权：Bearer；禁止用 query `?token=`。

### 5.2 成功：HTTP 200 + SSE

续传连接上推送的事件类型与 POST 相同：`message_delta` / `message_end` / `error`。

**不要求**再发 `started`（客户端已有 `streamId`）。若实现方便，允许发一个：

```text
event: resume
data: {"type":"resume","streamId":"s-...","afterEventId":12,"serverLastEventId":18,"status":"running"}
```

客户端可忽略未知事件名 `resume`。

#### 行为矩阵

| Stream.status | 服务端行为 |
|---------------|------------|
| `running` | 先补推 `eventId > afterEventId` 的已缓冲事件；若仍在生成则继续实时推；结束时 `message_end` 或 `error` |
| `completed` | 补推缺失的 delta（或等价文本切片），最后推 `message_end`（完整 `content`），然后结束连接 |
| `failed` | 若有未送达的 error，推 `error`；否则推 `{ "type":"error", "message":"生成失败" }` |
| `cancelled` | 推 `error`：`{"type":"error","message":"已取消"}`，结束连接 |

### 5.3 补推策略（两种实现，选一种即可）

**方案 A — 事件日志（推荐，精确）**

存储每个已发出事件：

```text
(streamId, eventId, eventName, dataJson)
```

续传：`WHERE eventId > afterEventId ORDER BY eventId ASC` 重放，再订阅后续 live 事件。

**方案 B — 全文切片（实现快）**

只存 `fullText` + `lastEventId`。续传时：

1. 若 `afterEventId >= lastEventId` 且 `completed`：直接发 `message_end`（完整文本）  
2. 若客户端同时上传已收文本长度（可选扩展，见 5.5）：对 `fullText` 未发送后缀切成一个或若干 `message_delta`，再 `message_end`  
3. 若仍 `running`：先按已知 `fullText` 与客户端长度差补 delta，再挂 live  

方案 B 在「客户端本地已拼接文本」与服务端 `fullText` 不一致时可能重复，**优先方案 A**。

### 5.4 非流式错误

| HTTP | body | 场景 |
|------|------|------|
| 401 | `{ "message":"未登录或会话已失效" }` | token 无效 |
| 403 | `{ "message":"无权访问该流" }` | stream 不属于当前用户 |
| 404 | `{ "message":"流不存在或已过期" }` | 无此 stream / 已清理 |
| 400 | `{ "message":"afterEventId 非法" }` | 负数等 |

### 5.5 可选扩展 query（非必须）

```http
GET /api/chat/streams/{streamId}?afterEventId=12&clientTextLength=120
```

仅当采用方案 B 时有用：用客户端已展示字符数辅助切片。中改有方案 A 时可忽略。

### 5.6 并发续传

- 同一 `streamId` 允许 **一个** 活跃续传连接；新续传可顶替旧续传连接  
- 续传 **不** 占用「新对话」busy；不阻碍对**同一** stream 的续传  
- 若用户对**另一**问题 `POST /api/chat`，仍按 409 处理（存在 running 流时）  

---

## 6. POST /api/chat/streams/{streamId}/cancel（显式取消）

### 6.1 请求

```http
POST /api/chat/streams/{streamId}/cancel
Authorization: Bearer <token>
```

无 body，或 `{}`。

### 6.2 响应

**200**

```json
{
  "streamId": "s-01HZX...",
  "status": "cancelled"
}
```

| HTTP | 说明 |
|------|------|
| 200 | 已取消，或本来就是 cancelled（幂等） |
| 401 | 未登录 |
| 403 | 非本人 |
| 404 | 不存在 / 过期 |

### 6.3 行为

1. 停止模型生成（若仍在跑）  
2. `status=cancelled`  
3. 释放用户 busy  
4. 若仍有挂着的 SSE 连接，推送 `error`（message: 已取消）后关闭  

**注意：** App 进后台 **不应** 调用 cancel；仅用户点「停止」时调用（若产品需要停止按钮）。

---

## 7. 可选：GET 流状态（JSON，非 SSE）

便于客户端诊断，非续传必需。

```http
GET /api/chat/streams/{streamId}/status
Authorization: Bearer <token>
```

**200**

```json
{
  "streamId": "s-01HZX...",
  "status": "running",
  "lastEventId": 18,
  "contentLength": 256,
  "expireAt": "2026-07-29T06:00:00+08:00"
}
```

也可用同一 path 通过 `Accept: application/json` 协商；若实现成本高可不做。

---

## 8. Busy / 会话记忆

| 项 | 行为 |
|----|------|
| threadId | 保持现网 `u-{userId}`，checkpoint 不变 |
| busy | `POST /api/chat` 创建 running 流时占用；completed/failed/cancelled 时释放 |
| 续传 | 不额外加 busy，不 409 |
| 断线 | 不释放 busy，直到生成结束或 cancel |

---

## 9. 客户端对接约定（给 iOS Agent）

1. 收到 `started` 后持久化 `streamId`  
2. 每处理一个事件更新 `lastEventId`，并拼接本地 `assistantText`  
3. 进后台：断开 URLSession 即可，**不要**调 cancel  
4. 回前台：若本地有 `status=streaming` 的未完成气泡，则：  
   `GET /api/chat/streams/{streamId}?afterEventId={lastEventId}`  
   继续追加 delta，直到 `message_end` / `error`  
5. 若续传 404：气泡定稿为已有文本，toast「回复已结束或过期」  
6. 发送新消息仍走 `POST /api/chat`；若 409 且 body 含 `streamId`，可先续传旧流  

---

## 10. 存储建议（实现参考）

### 10.1 表 `chat_stream`（示例）

| 列 | 类型 | 说明 |
|----|------|------|
| stream_id | varchar PK | |
| user_id | varchar/bigint | 索引 |
| status | varchar | running/completed/failed/cancelled |
| full_text | mediumtext | |
| last_event_id | bigint | |
| created_at | datetime | |
| updated_at | datetime | |
| expire_at | datetime | 索引，定时清理 |

### 10.2 表 `chat_stream_event`（方案 A）

| 列 | 类型 | 说明 |
|----|------|------|
| stream_id | varchar | 联合主键 |
| event_id | bigint | 联合主键 |
| event_name | varchar | started/message_delta/... |
| data_json | text | 完整 data 载荷 |
| created_at | datetime | |

### 10.3 清理

定时任务删除 `expire_at < now()` 的 stream 及事件；或 completed 后 30 分钟删除。

---

## 11. curl 示例

### 11.1 开流

```bash
TOKEN=xxx
curl -N -X POST "http://127.0.0.1:8088/api/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{"content":"查看我的账户"}'
# 记下 started 里的 streamId，以及最后的 eventId
```

### 11.2 模拟断线后续传

```bash
STREAM_ID=s-01HZX...
AFTER=5
curl -N "http://127.0.0.1:8088/api/chat/streams/${STREAM_ID}?afterEventId=${AFTER}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: text/event-stream"
```

### 11.3 取消

```bash
curl -X POST "http://127.0.0.1:8088/api/chat/streams/${STREAM_ID}/cancel" \
  -H "Authorization: Bearer $TOKEN"
```

---

## 12. 验收清单（后端）

- [ ] `POST /api/chat` 的 `started` / delta / end / error 均含 `streamId` + `eventId`  
- [ ] SSE 帧带 `id: <eventId>`（推荐）  
- [ ] 客户端中途断开后，服务端仍继续生成并写入 buffer  
- [ ] `GET /api/chat/streams/{id}?afterEventId=N` 能补齐 N 之后的事件并续上 live  
- [ ] 生成已结束后再续传，仍能收到完整补齐 + `message_end`  
- [ ] 续传不 409；新 POST 在有 running 流时 409  
- [ ] 非本人 stream → 403；过期 → 404  
- [ ] `cancel` 停止生成并释放 busy；进后台断线 **不** 自动 cancel  
- [ ] 旧客户端忽略新字段仍能完整走完一轮 POST SSE  

---

## 13. 与旧协议对照

| 项 | 现网 | 中改后 |
|----|------|--------|
| 开流 | `POST /api/chat` | 同左，响应增加 `streamId`/`eventId` |
| 断线 | 生成常被取消或结果不可再取 | 生成继续，可 GET 续传 |
| 续传 | 无 | `GET /api/chat/streams/{streamId}?afterEventId=` |
| 取消 | 断连即取消（若现网如此） | 仅显式 `.../cancel` |
| 事件名 | started / message_delta / message_end / error | 保持不变 |

---

## 14. 实现优先级建议

1. Stream 表 + POST 下发 `streamId`/`eventId` + 断线不取消任务  
2. 事件日志表 + GET 续传重放  
3. cancel 接口  
4. 409 附带 `streamId`（可选）  
5. 过期清理任务  

---

## 15. 联系与范围

- 本文仅覆盖 **聊天 SSE 断点续传**  
- 登录 / 账户 / 分类 / 概览 REST 见既有 `ios-swift-handoff`  
- 客户端持久化半成品气泡已可先做；待本接口就绪后再接续传 GET  
