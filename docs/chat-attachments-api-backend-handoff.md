# EasyAccounts — 聊天附件（图片）接口说明（后端实现稿）

面向：后端 Agent / `easyaccount-agent` 开发  
客户端：EasyAccount iOS (Swift)  
文档日期：2026-08-05（2026-08-05 联调修订）  
状态：**公网已部署并通过探测**；iOS 已按本文「先上传再开聊」接线  
关联：现有 `POST /api/chat` SSE（见 `docs/sse-stream-resume-api.md`）；iOS 待命区 + 上传接线合入 `feature/ux-polish`

---

## 0. 背景与目标

### 客户端现状（产品交互已就绪）

| 能力 | iOS 行为 |
|------|----------|
| 入口 | 输入框左侧 `+` → 相册 / 拍照 / 文件（文件本期不做） |
| 待命 | 选中图片**先进入输入框顶部待命区**，可多选、点开预览、✕ 删除 |
| 追加说明 | 待命后可继续在文字框输入 |
| 发送 | 文字 + 本地 JPEG 进入用户气泡；网络层先 `POST /api/chat/attachments`，再 `POST /api/chat` 带 `attachmentIds` |
| 上限 | 最多 **9** 张；客户端压缩最长边 ≤ **1600**px，JPEG quality ≈ **0.78** |

### 目标

在现有 REST/SSE 代理层提供：

1. **上传附件** → 拿到稳定 `attachmentId`（及可选访问 URL）  
2. **发起对话时携带附件引用** → 业务层用已有解析逻辑理解图片 + 文本  
3. 与现有 SSE 流协议兼容（`started` / `message_delta` / `message_end` / `error`、续传、取消不变）

### 非目标

- 本期不做「文件」（PDF/文档等）上传；契约可预留 `kind`  
- 不要求把图片字节塞进 SSE 事件  
- 历史回看所需的原图/缩略图下载与长期保留，见后续文档  
  `docs/chat-attachments-media-access-backend-handoff.md`（**待后端实现**）  
- 不改变鉴权方式（仍为 `Authorization: Bearer`）

---

## 1. 环境与通用约定

| 项 | 说明 |
|----|------|
| Base URL（公网） | `http://118.25.46.207:6088` |
| Base URL（本机示例） | `http://127.0.0.1:8088` |
| 鉴权 | `Authorization: Bearer <token>`（必填；缺省或失效 → **401**） |
| 错误体（非流式，推荐） | `{ "message": "人类可读错误" }` |
| 时区 | Asia/Shanghai |

**推荐调用顺序（iOS 将按此改造）：**

```text
1) 用户点发送
2) 对每张待命图：POST /api/chat/attachments  → 得到 attachmentId[]
3) POST /api/chat  { content, attachmentIds }  → SSE 如常
```

> 不要用 `multipart/form-data` 直接打在 `POST /api/chat` 上再开 SSE：多数代理/客户端对「multipart + text/event-stream」组合不友好。  
> **先上传、再 JSON 开聊** 是本契约的强制推荐。

---

## 2. 资源模型

### 2.1 ChatAttachment（上传结果）

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | string | 是 | 附件唯一 ID，建议 `att_` + ulid/uuid |
| `kind` | string | 是 | 本期仅 `image`；预留 `file` |
| `mimeType` | string | 是 | 如 `image/jpeg`、`image/png`、`image/heic` |
| `sizeBytes` | number | 是 | 原始上传字节数 |
| `width` | number | 否 | 像素宽（可知则填） |
| `height` | number | 否 | 像素高（可知则填） |
| `url` | string | 否 | **短期可读** URL（若助手/调试需要拉原图）；可空，服务端解析可不依赖公网 URL |
| `expiresAt` | string | 否 | ISO-8601；对象/签名 URL 过期时间 |
| `createdAt` | string | 否 | ISO-8601 |

### 2.2 约束（请与 iOS 对齐）

| 项 | 建议值 | 说明 |
|----|--------|------|
| 单次对话附件数 | ≤ **9** | 与 `ChatAttachmentLimits.maxCount` 一致 |
| 单文件大小 | ≤ **8 MiB**（上传后） | 客户端已压缩；服务端仍应校验 |
| 允许 MIME | `image/jpeg`、`image/png`、`image/heic`、`image/webp` | 其他 → **415** 或 **400** |
| 归属 | 必须绑定当前 `userId` | 禁止跨用户引用 `attachmentId` |
| 引用窗口 | 上传后建议 **≥ 30 分钟** 内可用于 `/api/chat` | 超时 → 开聊返回 **400** |

---

## 3. 接口一览

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/api/chat/attachments` | 上传单个附件（multipart） |
| `GET` | `/api/chat/attachments/{id}` | 元数据（建议必做；见媒体访问交接稿） |
| `GET` | `/api/chat/attachments/{id}/content` | **新增**：缩略图/原图像素下载（见媒体访问交接稿） |
| `DELETE` | `/api/chat/attachments/{id}` | 可选：用户删除待命图时清理（未开聊） |
| `POST` | `/api/chat` | **扩展**：JSON 增加 `attachmentIds`（SSE 不变） |

现有不变：

| 方法 | 路径 |
|------|------|
| `GET` | `/api/chat/streams/{streamId}?afterEventId=` |
| `POST` | `/api/chat/streams/{streamId}/cancel` |

---

## 4. POST /api/chat/attachments（上传）

### 4.1 请求

```http
POST /api/chat/attachments
Authorization: Bearer <token>
Content-Type: multipart/form-data; boundary=....
```

**multipart 字段：**

| 字段名 | 类型 | 必填 | 说明 |
|--------|------|------|------|
| `file` | binary | 是 | 图片文件本体 |
| `kind` | text | 否 | 默认 `image` |

> 字段名请固定为 **`file`**，便于 iOS `multipart` 实现与联调脚本一致。

### 4.2 成功响应 `201`（或 `200`）

```json
{
  "id": "att_01JABCDEFG...",
  "kind": "image",
  "mimeType": "image/jpeg",
  "sizeBytes": 245760,
  "width": 1200,
  "height": 900,
  "url": "https://example.invalid/chat-att/att_01J...?sig=...",
  "expiresAt": "2026-08-05T12:00:00+08:00",
  "createdAt": "2026-08-05T11:30:00+08:00"
}
```

### 4.3 错误

| HTTP | 场景 | `message` 示例 |
|------|------|----------------|
| 400 | 缺 `file` / 空文件 | `请上传图片文件` |
| 401 | 未登录 | `未授权` |
| 413 | 超过大小限制 | `图片过大` |
| 415 | MIME 不支持 | `不支持的文件类型` |
| 429 | 限流（可选） | `上传过于频繁` |

---

## 5. POST /api/chat（扩展，兼容旧客户端）

### 5.1 请求

```http
POST /api/chat
Authorization: Bearer <token>
Content-Type: application/json; charset=utf-8
Accept: text/event-stream
```

```json
{
  "content": "这是午餐小票，帮我记一笔",
  "attachmentIds": ["att_01JABCDEFG...", "att_01JXYZ..."]
}
```

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `content` | string | 条件必填 | trim 后与 `attachmentIds` **至少有一个非空** |
| `attachmentIds` | string[] | 否 | 0…9 个；必须属于当前用户且未过期 |

**兼容：**

- 旧客户端只传 `{ "content": "..." }` → 行为与现网完全一致  
- 仅有图片、无文字：允许 `content` 为空字符串或省略，但 `attachmentIds` 非空；服务端应用业务默认提示（如「用户发送了图片」）喂给模型，**不必**要求客户端再传 `【图片】`  
- 未知字段忽略

### 5.2 成功

与现网相同：`200` + `Content-Type: text/event-stream`  
事件序列仍为：`started` → `message_delta*` → `message_end` | `error`  
（字段见 `docs/sse-stream-resume-api.md`）

业务侧应将 `attachmentIds` 解析为多模态输入（核心逻辑你们已具备），再流式输出助手文本。

### 5.3 开聊前校验错误（非 SSE）

在进入 SSE 之前，若请求不合法，直接返回 JSON 错误（不要开半截流）：

| HTTP | 场景 | `message` 示例 |
|------|------|----------------|
| 400 | `content` 与 `attachmentIds` 都空 | `消息不能为空` |
| 400 | `attachmentIds` 数量 > 9 | `附件数量超过限制` |
| 400 | id 不存在 / 不属于当前用户 / 已过期 | `附件无效或已过期` |
| 401 | 未登录 | `未授权` |
| 409 | 用户已有 running 流 | 现有 busy 体（含 `streamId` / `lastEventId`） |

---

## 6. 可选接口

### 6.1 GET /api/chat/attachments/{id}

```http
GET /api/chat/attachments/{id}
Authorization: Bearer <token>
```

**200** 元数据（同上传响应），或 **302** 到签名 URL。  
跨用户 → **404**（勿暴露存在性细节）。

### 6.2 DELETE /api/chat/attachments/{id}

用户在待命区删除、且尚未引用开聊时，客户端可调用以释放存储（可选，非联调阻塞项）。

- 已成功引用进某轮 `POST /api/chat` 的附件：建议 **禁止删** 或仅做逻辑删，避免审计/复盘丢图  
- **204** 无体，或 `{ "ok": true }`

### 6.3 存储与生命周期（建议）

| 策略 | 建议 |
|------|------|
| 未引用 | 上传后 24h 未用于 `/api/chat` 可 GC |
| 已引用 | 至少保留至该轮 stream `expireAt`；更长由产品定 |
| 病毒/内容安全 | 若有异步扫描，开聊时未通过 → **400** |

---

## 7. curl 验收脚本

```bash
BASE=http://118.25.46.207:6088
TOKEN=...   # 登录后 Bearer

# 1) 上传
curl -sS -X POST "$BASE/api/chat/attachments" \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@./receipt.jpg;type=image/jpeg" \
  -F "kind=image"

# 记下返回的 id → ATT_ID

# 2) 带附件开聊（应返回 SSE）
curl -sS -N -X POST "$BASE/api/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: text/event-stream" \
  -d "{\"content\":\"帮我记一下这张小票\",\"attachmentIds\":[\"$ATT_ID\"]}"

# 3) 仅附件、无文字
curl -sS -N -X POST "$BASE/api/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: text/event-stream" \
  -d "{\"content\":\"\",\"attachmentIds\":[\"$ATT_ID\"]}"

# 4) 旧客户端兼容（无 attachmentIds）
curl -sS -N -X POST "$BASE/api/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -H "Accept: text/event-stream" \
  -d '{"content":"今天午饭 35 元"}'
```

### 通过标准

1. 上传返回稳定 `id`，鉴权失效 → 401  
2. `/api/chat` 携带有效 `attachmentIds` 能正常 SSE，且业务能吃到图片  
3. 无效 / 过期 / 跨用户 id → 开聊前 **400**，不开流  
4. 不传 `attachmentIds` 的旧请求行为与现网一致  
5. 续传 `GET /api/chat/streams/{streamId}`、取消接口不受影响  

---

## 8. iOS 当前实现与后续改造点

| 项 | 当前（`feature/ux-polish`） |
|----|---------------------------|
| 待命区 UI | ✅ |
| 压缩 | ✅ JPEG ≤1600px，上传前压缩 |
| `ChatOutbound` | `{ content, attachmentIds? }` |
| `ChatAttachmentService` | ✅ multipart 字段 `file` + `kind` |
| `ChatSSEClient.stream` | ✅ 先 upload 再开 SSE；允许空 content + 附件 |
| 用户气泡图 | 本地缩略图缓存 + 附件 `remoteId`；点按按需拉原图（见媒体访问交接稿） |

---

## 9. 公网探测摘要（2026-08-05）

| 检查 | 结果 |
|------|------|
| `OPTIONS /api/chat/attachments` | Allow: `POST,OPTIONS` |
| 无 Token multipart | **401** `{ "message":"未登录或会话已失效" }` |
| 有 Token 上传 JPEG | **201**，返回 `id/kind/mimeType/sizeBytes/expiresAt/...` |
| `POST /api/chat` + `attachmentIds` | **200** SSE：`started` → `message_delta*` → `message_end` |
| 无效 `attachmentIds` | **400** `{ "message":"附件无效或已过期" }`（开流前） |
| 空 `content` + 有效 ids | 可开 SSE |

---

## 10. 联调联系

- 客户端分支：`feature/ux-polish`  
- 相关文档：`docs/sse-stream-resume-api.md`  
- 本文路径：`docs/chat-attachments-api-backend-handoff.md`
