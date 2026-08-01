# EasyAccounts — 分类（Types）CRUD 接口说明（后端实现稿）

面向：后端 Agent / `easyaccount-agent` 开发  
客户端：EasyAccount iOS (Swift)  
文档日期：2026-08-01  
状态：**待后端完整实现**（只读已可用；写接口需补齐并与下文契约对齐）  
关联：现有 `GET /api/types`、`GET /api/actions`、账户 CRUD（`/api/accounts`）

---

## 0. 背景与目标

iOS「分类管理」需要与「账户管理」一致的能力：

| 能力 | 客户端交互 |
|------|------------|
| 新建 | 右上角 `+` |
| 编辑 | 右划条目 |
| 删除 | 左划条目 |
| 列表 | 按 `actionId` 拉取树形分类（已有） |

**目标：** 在现有 REST 代理层提供稳定、可鉴权的分类 CRUD，字段与现有 `GET /api/types` 保持兼容。

**非目标：**

- 不改动收支操作（actions）本身的 CRUD  
- 不要求一次请求改整棵树排序（本阶段不做 sort）  
- 不强制实现归档（archive）能力；删除可先做停用/软删（与 EasyAccounts 原版一致亦可）

---

## 1. 环境与通用约定

| 项 | 说明 |
|----|------|
| Base URL（公网） | `http://118.25.46.207:6088` |
| Base URL（本机示例） | `http://127.0.0.1:8088` |
| 鉴权 | `Authorization: Bearer <token>`（必填；缺省或失效 → **401**） |
| Content-Type | `application/json; charset=utf-8` |
| 错误体（推荐，与现网一致） | `{ "message": "人类可读错误" }` |
| 成功空体（可选） | `{ "ok": true }` |
| 时区 | Asia/Shanghai |

**字段命名兼容（重要）：**

| 逻辑字段 | JSON 写出（响应） | JSON 读入（请求） |
|----------|-------------------|-------------------|
| 分类名 | **`tname`**（小写，与现网 GET 一致） | 同时接受 `tname` / `tName` |
| 收支类型 ID | `actionId` | `actionId` |
| 父分类 ID | `parent` | `parent` |
| 子节点 | `childrenTypes` | —（只读树） |

> 现网 `GET /api/actions` 返回 `hname`，`GET /api/types` 返回 `tname`。写接口请勿突然改成仅 camelCase，否则 iOS 会解包失败。

---

## 2. 现状探针（2026-08-01，未带 Token）

对公网代理实测：

| 方法 | 路径 | 结果 | 说明 |
|------|------|------|------|
| GET | `/api/types` | **401** | 路由存在（只读已上线） |
| OPTIONS | `/api/types` | Allow: `GET,HEAD,OPTIONS` | **未声明写方法** |
| POST | `/api/types` | **405** | 集合创建未开放 |
| POST | `/api/types/create` | **401** | 路由疑似存在，待鉴权后验收 |
| POST | `/api/types/add` | **401** | 路由疑似存在，待鉴权后验收 |
| PUT | `/api/types/{id}` | **401** | 路由疑似存在，待鉴权后验收 |
| DELETE | `/api/types/{id}` | **401** | 路由疑似存在，待鉴权后验收 |
| POST | `/type/addType` 等原版路径 | **404** | 代理未透出 EasyAccounts 原 Controller |

> 「401」只说明路由进了鉴权过滤器，**不代表业务已实现正确**。请按下文契约补测并补齐。

---

## 3. 推荐契约（请按此实现）

为与账户 API 风格一致，**推荐**最终形态如下（iOS 可随后改客户端对齐；当前客户端已兼容标注中的「过渡路径」）。

### 3.1 资源模型

```json
{
  "id": 12,
  "tname": "餐饮",
  "parent": -1,
  "childrenTypes": [
    {
      "id": 34,
      "tname": "午饭",
      "parent": 12,
      "childrenTypes": []
    }
  ]
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | int | 分类 ID |
| `tname` | string | 分类名，非空，建议 ≤ 50 |
| `parent` | int \| null | 父分类 ID；**一级分类用 `-1`**（也接受 `null`/`0`，响应建议统一为 `-1`） |
| `childrenTypes` | array | 子分类；叶子可为 `[]` 或省略 |
| `actionId` | int（可选，写请求必填/可读） | 所属收支操作；列表接口已用 query `actionId` 过滤 |

树深：产品为二级分类（一级 + 子级）。创建时若 `parent` 指向非一级节点，建议 **400** 并返回明确 `message`。

---

### 3.2 列表（已有，请保持）

```
GET /api/types?actionId={actionId}
Authorization: Bearer <token>
```

**响应 `200`：** `TypeNode[]`（树形数组，不是 `{ data: ... }` 信封）

```json
[
  {
    "id": 12,
    "tname": "餐饮",
    "parent": -1,
    "childrenTypes": [
      { "id": 34, "tname": "午饭", "parent": 12, "childrenTypes": [] }
    ]
  }
]
```

**错误：**

| HTTP | 场景 |
|------|------|
| 401 | 未登录 / token 失效 |
| 400 | `actionId` 缺失或非法 |

---

### 3.3 创建

**推荐（与账户一致）：**

```
POST /api/types
Authorization: Bearer <token>
Content-Type: application/json
```

**过渡（iOS 当前已调用，请至少实现其一，推荐两者都指向同一实现）：**

```
POST /api/types/create
```

**请求体：**

```json
{
  "tname": "餐饮",
  "actionId": 1,
  "parent": -1
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `tname` | 是 | 分类名 |
| `actionId` | 是 | 所属收支操作 ID（须属于当前用户可见 actions） |
| `parent` | 否 | 默认 `-1`（一级）；子分类传父节点 `id` |

**响应 `200` 或 `201`（二选一，推荐 `200` 与账户一致）：**

优先返回新建节点（便于客户端乐观更新）：

```json
{
  "id": 12,
  "tname": "餐饮",
  "parent": -1,
  "childrenTypes": []
}
```

若暂时只返回：

```json
{ "ok": true }
```

亦可；客户端会强制刷新列表。

**错误：**

| HTTP | `message` 示例 |
|------|----------------|
| 401 | `未登录或会话已失效` |
| 400 | `分类名不能为空` / `actionId 无效` / `父分类不存在` / `仅支持二级分类` |
| 409 | `同名分类已存在`（若做唯一约束） |

---

### 3.4 更新

```
PUT /api/types/{id}
Authorization: Bearer <token>
Content-Type: application/json
```

**请求体：**

```json
{
  "tname": "餐饮支出",
  "actionId": 1,
  "parent": -1
}
```

| 字段 | 必填 | 说明 |
|------|------|------|
| `tname` | 是 | 新名称 |
| `actionId` | 否 | 一般保持不变；若传则校验归属 |
| `parent` | 否 | 调整层级；禁止把节点挂到自己的子孙下 |

**响应 `200`：** 更新后的节点，或 `{ "ok": true }`

**错误：** 401 / 400 / 404（分类不存在或不属于当前用户）

---

### 3.5 删除

```
DELETE /api/types/{id}
Authorization: Bearer <token>
```

**语义（请在实现中选一种并在响应/`message` 中保持稳定）：**

| 方案 | 说明 | 建议 |
|------|------|------|
| A. 软删/停用 | 与 EasyAccounts 原版 `deleteType`≈disable 一致；列表不再返回 | **推荐** |
| B. 硬删 | 物理删除；若存在子分类或被流水引用 → 400 | 可选 |

**若存在子分类：**

- 推荐：级联停用/删除子分类，或  
- 拒绝并返回：`{ "message": "请先删除子分类" }`（HTTP 400）

**若已被流水引用：**

- 软删方案可直接停用  
- 硬删方案应 **400**：`{ "message": "分类已被账单使用，无法删除" }`

**响应 `200`：**

```json
{ "ok": true }
```

---

## 4. 与原版 EasyAccounts 的映射（供参考）

原版 Controller 前缀为 `/type`（代理层 **不要**直接暴露给 iOS，请收敛到 `/api/types*`）：

| 原版 | 建议代理 |
|------|----------|
| `POST /type/addType` | `POST /api/types`（及/或 `/api/types/create`） |
| `PUT /type/updateType/{id}` | `PUT /api/types/{id}` |
| `DELETE /type/deleteType/{id}` | `DELETE /api/types/{id}` |
| `GET /type/getTypeByActionId/{actionId}` | 已有 `GET /api/types?actionId=` |

原版 DTO 字段：`tName` / `parent` / `actionId`（Java）；JSON 请继续输出 **`tname`** 以兼容现网 iOS。

---

## 5. 验收用例（后端自测清单）

登录拿到 token 后执行：

```bash
BASE=http://118.25.46.207:6088
TOKEN='<bearer>'

# 1) 列表
curl -sS "$BASE/api/types?actionId=1" -H "Authorization: Bearer $TOKEN"

# 2) 创建一级
curl -sS -X POST "$BASE/api/types" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tname":"验收一级","actionId":1,"parent":-1}'

# 3) 创建二级（把 PARENT_ID 换成上一步 id）
curl -sS -X POST "$BASE/api/types" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tname":"验收二级","actionId":1,"parent":PARENT_ID}'

# 4) 改名
curl -sS -X PUT "$BASE/api/types/TYPE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tname":"验收改名","actionId":1,"parent":-1}'

# 5) 删除
curl -sS -X DELETE "$BASE/api/types/TYPE_ID" \
  -H "Authorization: Bearer $TOKEN"

# 6) 过渡路径（若保留）
curl -sS -X POST "$BASE/api/types/create" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"tname":"过渡创建","actionId":1,"parent":-1}'
```

**通过标准：**

1. 未带 token → 一律 401 + `{ "message": "..." }`  
2. `POST /api/types` 不再 405  
3. 创建后 `GET /api/types?actionId=` 能看到新节点（含正确 `parent` / `childrenTypes`）  
4. 更新后名称变化；删除后列表不再出现（或软删不可见）  
5. OPTIONS `/api/types` 的 `Allow` 至少包含 `GET,POST`；`/api/types/{id}` 包含 `PUT,DELETE`

---

## 6. iOS 客户端当前调用（实现时请兼容）

文件：`EasyAccount/Services/CatalogService.swift`

| 操作 | 当前路径 | 请求体 |
|------|----------|--------|
| 列表 | `GET /api/types?actionId=` | — |
| 创建 | `POST /api/types/create` | `{ "tname", "actionId", "parent" }` |
| 更新 | `PUT /api/types/{id}` | `{ "tname", "actionId?", "parent?" }` |
| 删除 | `DELETE /api/types/{id}` | — |

后端若先实现推荐的 `POST /api/types`，请**同时**把 `/api/types/create` 指到同一 handler，避免发版窗口期 iOS 创建失败。

---

## 7. 建议排期

| 优先级 | 项 |
|--------|----|
| P0 | `PUT /api/types/{id}`、`DELETE /api/types/{id}` 业务可用 + 鉴权 |
| P0 | `POST /api/types` **或** 保证 `/api/types/create` 真正落库 |
| P1 | `POST /api/types` 与 `/api/types/create` 双路径同源 |
| P1 | 子分类/引用账单的删除策略与明确错误文案 |
| P2 | 同名校验、归档 API（非本阶段必须） |

---

## 8. 联系与联调

- 客户端仓库：`rockyshen/easyaccount-swift-ui`  
- 相关 PR：分类管理滑动编辑/删除（对接上述写接口）  
- 联调时请提供：环境 Base URL、一例成功创建的请求/响应 JSON、删除语义（软/硬）说明  
