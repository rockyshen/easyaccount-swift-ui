# EasyAccounts iOS — SSE 断点续传联调问题反馈（给后端）

面向：`easyaccount-agent` 后端  
客户端：`easyaccount-swift-ui`  
文档日期：2026-07-31  
关联：`docs/sse-stream-resume-api.md`（续传设计说明）；对接文档中的 `GET /api/chat/streams/{streamId}`

---

## 0. 摘要

| 项 | 说明 |
|----|------|
| 环境 | 公网 `http://118.25.46.207:6088` |
| 现象 | 助手打字机输出中退出 App（SSE 断开），回前台后半截文字仍在，但出现「请求失败（500）」，无法继续增量 |
| 结论 | **问题在后端续传接口**；前端请求路径、鉴权与参数符合文档，服务端对续传相关 API 返回 HTTP 500 |

---

## 1. 预期行为（文档）

| 步骤 | 行为 |
|------|------|
| 开流 | `POST /api/chat`，SSE 事件带 `streamId` + `eventId` |
| 进后台 | 客户端只断开 URLSession，**不**调 cancel |
| 回前台 | `GET /api/chat/streams/{streamId}?afterEventId={本地已处理的最大 eventId}`，补推后续 `message_delta`，直到 `message_end` / `error` |
| 流不存在 | 应 **404** + `{ "message": "流不存在或已过期" }`，而不是 500 |

---

## 2. 前端实际行为（已确认正常）

1. `POST /api/chat` 成功，能解析并持久化 `streamId`、`lastEventId`、已拼接的助手文本。
2. 进后台仅断连，不调用 `POST .../cancel`。
3. 回前台（或冷启动恢复未完成气泡后）发起：

```http
GET /api/chat/streams/{streamId}?afterEventId={lastEventId}
Authorization: Bearer <token>
Accept: text/event-stream
```

4. 收到非 200 时，若 body 无 `message`，展示兜底文案 `请求失败（{status}）` → 用户看到的「请求失败（500）」即来自此路径。
5. 半截气泡能保留，说明断连前的本地状态没问题；失败发生在**续传 GET**。

---

## 3. 公网复现结果（后端需优先看）

用新注册用户实测（2026-07-31，公网 `6088`）：

### A. 开流正常

```bash
POST /api/chat
→ 200 + SSE
  started / message_delta … 含 streamId、eventId
```

示例：`streamId=s-49763500b3124481929060f84f6cd84d`，中途断开时本地已收到约 `eventId=36`。

### B. 对同一 streamId 查状态 → 500

```bash
GET /api/chat/streams/{streamId}/status
Authorization: Bearer <token>
```

实际：

- HTTP **500**
- Body 类似 Spring 默认错误页：

```json
{
  "timestamp": "...",
  "status": 500,
  "error": "Internal Server Error",
  "path": "/api/chat/streams/.../status"
}
```

### C. 断点续传 GET → 500（与线上一致）

```bash
GET /api/chat/streams/{streamId}?afterEventId=36
Authorization: Bearer <token>
Accept: text/event-stream
```

实际：

- HTTP **500**
- `Content-Length: 0`（空 body）
- 连接关闭，无任何 SSE 事件

### D. 不存在的 streamId → 也是 500（不符合文档）

```bash
GET /api/chat/streams/s-does-not-exist?afterEventId=1
→ HTTP 500（空 body）
```

文档期望：**404** + `{ "message": "流不存在或已过期" }`。

---

## 4. 建议后端排查点

1. **`GET /api/chat/streams/{streamId}` 与 `/status` 的 500 堆栈**
   - 路由是否已注册、是否打到错误 Controller/Filter
   - 是否在读取 buffer、序列化 SSE、解析 `afterEventId` 时 NPE / 未捕获异常

2. **断连后流是否仍保留**
   - 客户端断开 POST SSE 后，服务端是否仍把该流标为 `running` 并缓冲事件
   - 是否误把断连当成 cancel / 立刻销毁 stream，导致续传时空指针或非法状态 → 500

3. **错误码契约**
   - 流不存在 / 过期 → **404** + `{ "message": "..." }`
   - 参数非法 → **400**
   - 勿用空 body 的 500 代替业务错误（前端无法展示友好文案）

4. **最小自测脚本（与客户端一致）**

```bash
TOKEN=xxx

# 1) 开流，记下 streamId，中途 Ctrl+C 断连
curl -N -X POST "http://118.25.46.207:6088/api/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{"content":"请用很长的一段话介绍记账技巧"}'

# 2) 续传（AFTER 换成断连前最后看到的 eventId）
STREAM_ID=s-...
AFTER=36
curl -N "http://118.25.46.207:6088/api/chat/streams/${STREAM_ID}?afterEventId=${AFTER}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: text/event-stream"

# 期望：200 + SSE（补 delta，最终 message_end）；当前公网为 500

# 3) 可选：查状态
curl "http://118.25.46.207:6088/api/chat/streams/${STREAM_ID}/status" \
  -H "Authorization: Bearer $TOKEN"
```

---

## 5. 验收标准（修完后）

- [ ] 开流中途断开 POST，再 `GET ...?afterEventId=` 返回 **200** 与 SSE
- [ ] 能补齐缺失 `message_delta`，并以一次 `message_end`（或 `error`）结束
- [ ] `/status` 对存在的流返回 JSON（`running/completed/...`），不 500
- [ ] 不存在的 `streamId` 返回 **404** + `message`，不 500
- [ ] iOS：退出再进前台后，半截气泡能继续打字机，且不再出现「请求失败（500）」

---

## 6. 一句话

客户端续传请求已按文档发出；公网对真实 `streamId` 的 `GET /api/chat/streams/{id}` 与 `/status` 均返回 **HTTP 500**，请后端先修这两个接口的内部异常与错误码，前端无需改协议即可恢复续传。
