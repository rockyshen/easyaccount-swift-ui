# EasyAccounts — 聊天附件媒体访问（缩略图 / 原图）后端交接稿

面向：后端 Agent / `easyaccount-agent` 开发  
客户端：EasyAccount iOS (Swift)  
文档日期：2026-08-06  
状态：**待后端实现**；iOS 已按本文改造（本地缩略图缓存 + 点按按需拉原图）  
关联：

- 既有上传与开聊：`docs/chat-attachments-api-backend-handoff.md`
- SSE：`docs/sse-stream-resume-api.md`

---

## 0. 背景与目标

### 产品目标（与主流 IM 对齐）

| 场景 | 行为 |
|------|------|
| 对话列表 | 只显示**缩略图** |
| 点按缩略图 | 再加载**原图**全屏预览 |
| 缩略图存放 | **手机磁盘缓存**（列表快速展示、省内存） |
| 原图权威来源 | **服务端对象存储**；手机可按需下载并做本地缓存 |

### 客户端已完成的改造（供对照）

1. `ChatMessage` 不再持有图片 `Data`，只存附件引用 `{ id, remoteId }`  
2. 发送时本地生成缩略图（≤256px）写入 Application Support  
3. 上传成功后用服务端 `attachmentId` 作为稳定键  
4. 点按预览：先读本地原图缓存 → 否则请求  
   `GET /api/chat/attachments/{id}/content?variant=original`  
5. 若 `/content` 尚未部署：回退 `GET /api/chat/attachments/{id}` 元数据中的 `url` / `thumbnailUrl`

### 后端需要补齐的能力

1. **持久化**：开聊成功引用过的附件，不能只用「上传后 30 分钟」短 TTL（否则历史会话点不开图）  
2. **内容下载接口**（推荐强制）：按 `variant` 返回缩略图 / 原图字节  
3. **上传响应扩展**（推荐）：返回 `thumbnailUrl`（及既有 `url`）  
4. **可选服务端出缩略图**：上传时生成 thumb，减轻客户端压力、统一规格

---

## 1. 环境与通用约定

| 项 | 说明 |
|----|------|
| Base URL（公网） | `http://118.25.46.207:6088` |
| 鉴权 | `Authorization: Bearer <token>` |
| 错误体（非流式） | `{ "message": "人类可读错误" }` |
| 跨用户 | 一律 **404**（勿用 403 暴露资源存在性） |

---

## 2. 生命周期与存储策略（重要）

当前上传契约里「引用窗口 ≥ 30 分钟」只覆盖**开聊前**。历史回看需要更长保留。

| 阶段 | 建议策略 |
|------|----------|
| 已上传、尚未被任何 `/api/chat` 引用 | 短 TTL（如 30–120 分钟）可清理 |
| **已被至少一次开聊成功引用** | **长期保留**：建议 ≥ **90 天**，或随用户聊天记录生命周期；生产可用对象存储 + 生命周期规则 |
| 用户删除会话 / 注销（若产品有） | 异步清理对应对象 |

> iOS 本地缩略图缓存可在清会话时删除；**不能**假设「没本地缓存就永远不需要服务端原图」。

存储建议结构（示例）：

```text
chat-attachments/{userId}/{attachmentId}/original.jpg
chat-attachments/{userId}/{attachmentId}/thumb.jpg
```

---

## 3. 资源模型扩展

### 3.1 ChatAttachment（上传 / 元数据）

在既有字段上增加：

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `id` | string | 是 | 既有 |
| `url` | string | 建议 | 原图可读地址（签名 URL 或走下方 content 接口的等价物） |
| `thumbnailUrl` | string | 建议 | 缩略图可读地址 |
| `expiresAt` | string | 否 | 若 `url` 为短签，填签名过期时间；**对象本身**的保留策略见 §2 |
| `width` / `height` | number | 建议 | 原图像素 |
| `thumbWidth` / `thumbHeight` | number | 否 | 缩略图像素 |

**缩略图规格建议（与 iOS 对齐）：**

| 项 | 值 |
|----|----|
| 最长边 | **256** px |
| 格式 | `image/jpeg` |
| 质量 | ≈ 0.7–0.8 |

上传原图约束仍与旧文档一致：单文件 ≤ 8 MiB，开聊附件数 ≤ 9，MIME 白名单不变。

---

## 4. 接口变更一览

| 方法 | 路径 | 优先级 | 说明 |
|------|------|--------|------|
| `POST` | `/api/chat/attachments` | 已有 | 响应建议增加 `thumbnailUrl`；服务端可同步生成 thumb |
| `GET` | `/api/chat/attachments/{id}/content` | **P0 新增** | 返回图片字节（`variant=thumbnail\|original`） |
| `GET` | `/api/chat/attachments/{id}` | **P1** | 返回元数据（含 url / thumbnailUrl）；从「可选」升为建议必做 |
| `DELETE` | `/api/chat/attachments/{id}` | P2 | 未开聊清理；已引用附件是否允许删由产品定 |
| `POST` | `/api/chat` | 已有 | 成功引用后将附件标记为「长期保留」 |

---

## 5. P0：GET `/api/chat/attachments/{id}/content`

### 5.1 请求

```http
GET /api/chat/attachments/{id}/content?variant=original
Authorization: Bearer <token>
Accept: image/*,application/octet-stream
```

| Query | 类型 | 必填 | 说明 |
|-------|------|------|------|
| `variant` | string | 否 | `thumbnail` \| `original`；默认 `original` |

### 5.2 成功 `200`

- `Content-Type`：`image/jpeg`（或实际上传 MIME）  
- Body：**原始图片字节**（不要包 JSON）  
- 建议 Header：`Cache-Control: private, max-age=86400`  
- 可选：`ETag` / `Content-Length`

也允许 **302** 到短时签名 URL（客户端会跟随；若签名 URL 不接受 Bearer，请确保 URL 本身可匿名 GET）。

### 5.3 错误

| HTTP | 场景 | `message` 示例 |
|------|------|----------------|
| 400 | `variant` 非法 | `不支持的 variant` |
| 401 | 未登录 | `未授权` |
| 404 | 不存在 / 非本人 / 已清理 | `附件不存在或已过期` |
| 410 | 明确已过期（可选，也可用 404） | `附件已过期` |

### 5.4 实现注意

- 必须校验 `attachment.userId == 当前用户`  
- `variant=thumbnail`：若尚未生成 thumb，可实时缩放原图并回写缓存，或临时返回缩小后的原图  
- 不要在 SSE 事件里推图片字节

---

## 6. P1：GET `/api/chat/attachments/{id}`（元数据）

```http
GET /api/chat/attachments/{id}
Authorization: Bearer <token>
```

**200** 示例：

```json
{
  "id": "att_01JABCDEFG...",
  "kind": "image",
  "mimeType": "image/jpeg",
  "sizeBytes": 245760,
  "width": 1200,
  "height": 900,
  "url": "https://example.invalid/chat-att/att_01J.../original?sig=...",
  "thumbnailUrl": "https://example.invalid/chat-att/att_01J.../thumb?sig=...",
  "expiresAt": "2026-08-06T12:00:00+08:00",
  "createdAt": "2026-08-06T11:30:00+08:00"
}
```

iOS 在 `/content` 返回 404/405 时会回退使用这里的 `url` / `thumbnailUrl`。

---

## 7. 上传响应扩展（兼容）

`POST /api/chat/attachments` 成功体建议：

```json
{
  "id": "att_01JABCDEFG...",
  "kind": "image",
  "mimeType": "image/jpeg",
  "sizeBytes": 245760,
  "width": 1200,
  "height": 900,
  "url": "https://example.invalid/.../original?sig=...",
  "thumbnailUrl": "https://example.invalid/.../thumb?sig=...",
  "expiresAt": "2026-08-06T12:00:00+08:00",
  "createdAt": "2026-08-06T11:30:00+08:00"
}
```

- 旧客户端忽略未知字段 → **向后兼容**  
- 新客户端：列表仍优先用本地缩略图；`thumbnailUrl` 可用于补缓存 / 多端同步

---

## 8. 与开聊的衔接

`POST /api/chat` + `attachmentIds` 行为不变，额外要求：

1. 校验 id 属于当前用户且文件可读  
2. **开聊校验通过后**，将这些 id 标记为 `referenced=true`（或写入消息附件表），应用 §2 长期保留  
3. 多模态仍由业务侧解析图片；无需改 SSE 事件格式

---

## 9. 客户端调用顺序（实现后）

```text
发送：
  1) 本地生成 thumb + 暂存 original（磁盘）
  2) POST /api/chat/attachments  × N  → attachmentIds
  3) POST /api/chat { content, attachmentIds } → SSE

列表展示：
  只读本地 thumb 缓存（不访问网络）

点按预览：
  1) 本地 original 缓存命中 → 直接显示
  2) 否则 GET .../content?variant=original
  3) 写入本地 original 缓存后显示
  4) /content 不可用 → GET 元数据 url → 下载
```

---

## 10. 验收清单（后端）

- [ ] `GET /content?variant=thumbnail` 返回小图字节，鉴权有效  
- [ ] `GET /content?variant=original` 返回原图字节  
- [ ] 跨用户 id → **404**  
- [ ] 上传后短时间内可开聊（旧行为）  
- [ ] **开聊引用后**超过原 30 分钟短 TTL，仍可用 `/content` 打开原图  
- [ ] 上传响应可带 `thumbnailUrl`（可先空，但字段建议稳定）  
- [ ] 未登录 → **401**

### curl 示例

```bash
BASE=http://118.25.46.207:6088
TOKEN=...

# 上传
ATT=$(curl -sS -X POST "$BASE/api/chat/attachments" \
  -H "Authorization: Bearer $TOKEN" \
  -F "kind=image" \
  -F "file=@/path/to.jpg;type=image/jpeg")
echo "$ATT"
ID=$(echo "$ATT" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# 开聊（将附件标记为长期保留）
curl -sS -N -X POST "$BASE/api/chat" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d "{\"content\":\"看一下这张图\",\"attachmentIds\":[\"$ID\"]}"

# 拉缩略图 / 原图
curl -sS -D- -o /tmp/thumb.jpg \
  -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/chat/attachments/$ID/content?variant=thumbnail"

curl -sS -D- -o /tmp/original.jpg \
  -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/chat/attachments/$ID/content?variant=original"
```

---

## 11. 工作量切分建议

| 优先级 | 项 | 说明 |
|--------|----|------|
| P0 | `/content` + 鉴权 + variant | iOS 点按预览的主路径 |
| P0 | 开聊后附件长期保留 | 否则历史会话必然 404 |
| P1 | 元数据 GET + url/thumbnailUrl | 兼容与签名 URL 场景 |
| P2 | 上传时服务端生成 thumb | 多端一致、可省客户端补拉 |
| P2 | 生命周期清理任务 | 未引用短 TTL / 已引用按策略删 |

---

## 12. 联调联系

- iOS 仓库：`rockyshen/easyaccount-swift-ui`  
- 本文路径：`docs/chat-attachments-media-access-backend-handoff.md`  
- 旧上传/开聊契约仍有效：`docs/chat-attachments-api-backend-handoff.md`（其中「可选 GET」升级见本文 §4–§6）
