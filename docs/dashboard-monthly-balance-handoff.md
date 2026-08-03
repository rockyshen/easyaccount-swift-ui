# EasyAccounts — 概览本月结余字段说明（后端实现稿）

面向：后端 Agent / `easyaccount-agent` 开发  
客户端：EasyAccount iOS (Swift)  
文档日期：2026-08-02  
状态：**待后端补字段**（`GET /api/dashboard` 已可用；缺本月结余）  
关联：现有 `GET /api/dashboard`

---

## 0. 背景与目标

iOS「概览分析」页已精简为两张三列指标卡：

| 卡片 | 指标 |
|------|------|
| 本月 | 收入 / 支出 / **结余** |
| 本年度 | 收入 / 支出 / 结余 |

现网响应已有本月收入、本月支出与年度三项，**缺少与 `yearBalance` 平行的本月结余字段**。

**目标：** 在 `GET /api/dashboard` 响应中新增 `curBalance`，语义与计算口径与 `yearBalance` 一致（仅时间范围为「本月」）。

**非目标：**

- 不改动鉴权、路径、其它已有字段  
- 不要求客户端用 `curIncome - curOutCome` 自行推算（避免与后端入账/豁免规则不一致）  
- 本阶段不要求提供按月筛选 query；`monthDetails` 可继续保留，iOS 当前 UI 不依赖

---

## 1. 环境与通用约定

| 项 | 说明 |
|----|------|
| Base URL（公网） | `http://118.25.46.207:6088` |
| 鉴权 | `Authorization: Bearer <token>`（必填；缺省或失效 → **401**） |
| Content-Type | `application/json; charset=utf-8` |
| 错误体（推荐） | `{ "message": "人类可读错误" }` |
| 金额字段 | **字符串**（如 `"1234.56"`），与现网 `yearBalance` / `curIncome` 一致 |

---

## 2. 接口（已有，扩展响应）

```
GET /api/dashboard
Authorization: Bearer <token>
```

### 2.1 新增字段

| JSON 字段 | 类型 | 必填 | 说明 |
|-----------|------|------|------|
| `curBalance` | string | 是（推荐） | **本月结余**，与 `yearBalance` 同语义、同格式 |

与本月/本年度相关的字段对照：

| 维度 | 收入 | 支出 | 结余 |
|------|------|------|------|
| 本月 | `curIncome`（已有） | `curOutCome`（已有） | **`curBalance`（新增）** |
| 本年度 | `yearIncome`（已有） | `yearOutCome`（已有） | `yearBalance`（已有） |

> 支出字段现网拼写为 `curOutCome` / `yearOutCome`（`Come` 大写 C）。新增字段请勿改名已有键；结余使用 camelCase：`curBalance`。

### 2.2 响应示例（节选）

```json
{
  "totalAsset": "100000.00",
  "netAsset": "80000.00",
  "curIncome": "12000.00",
  "curOutCome": "4500.50",
  "curBalance": "7499.50",
  "yearIncome": "96000.00",
  "yearOutCome": "52000.00",
  "yearBalance": "44000.00",
  "accounts": [],
  "monthDetails": []
}
```

未登录示例：

```json
{ "message": "未登录或会话已失效" }
```

HTTP **401**。

### 2.3 计算口径建议

- `curBalance` 与产品「本月结余」定义一致；若与 `yearBalance` 同源公式，仅将时间窗改为当前自然月即可。  
- 无账单月份：返回 `"0.00"`（或 `"0"`），勿省略键（便于客户端稳定解码）。  
- 字符串小数位建议两位，与现网金额字段一致。

---

## 3. 验收标准

1. 带有效 token 调用 `GET /api/dashboard` → **200**，JSON 含 `curBalance`。  
2. `curBalance` 为字符串金额；本月无数据时为 `"0.00"`（或等价零值字符串）。  
3. 未带 / 无效 token → **401** + `{ "message": "..." }`。  
4. 既有字段（`curIncome`、`curOutCome`、`yearIncome`、`yearOutCome`、`yearBalance` 等）行为不变。  

### curl

```bash
BASE='http://118.25.46.207:6088'
TOKEN='<bearer>'

curl -sS "$BASE/api/dashboard" -H "Authorization: Bearer $TOKEN"
```

---

## 4. iOS 侧现状

- 已解码 `curBalance: String?`；字段暂缺时显示为 `¥0.00`，后端上线后自动展示真实结余。  
- 概览页 UI 仅展示「本月」「本年度」两张三列卡，不再展示资产概况 / 账户构成（相关响应字段可保留，客户端忽略即可）。
