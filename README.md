# easyaccount-swift-ui

智能记账（EasyAccount）SwiftUI iOS 客户端。

按 Web 端 `EasyAccountAgent` 能力复现：**登录/注册、会话恢复、WebSocket 流式对话**；UI 对齐对话式交互（登录首屏 / 手机号流程 / 侧栏 / 欢迎引导），支持浅色 / 暗色 / 跟随系统。

## 要求

- macOS + Xcode 15+
- iOS 17.0+
- 可访问的 `easyaccount-agent` 后端（HTTP + WebSocket）

## 打开与运行

1. 用 Xcode 打开 `EasyAccount.xcodeproj`
2. 选择模拟器或真机
3. 如需签名，在 Target → Signing & Capabilities 中选择你的 Team
4. Run（⌘R）

默认连接：

- HTTP：`http://118.25.46.207:8088`
- WS：`ws://118.25.46.207:8088`

可在登录页 →「使用账号密码登录」→「连接设置」中修改。本地联调可改回 `127.0.0.1`。

登录入口：

- 微信 / Apple ID：界面占位（即将开放）
- 手机号登录：输入手机号 → 验证码；联调时验证码即密码，未注册自动注册
- 账号密码登录：对接现有 `login` / `register` API

外观：登录页右上角或侧栏可切换「系统 / 浅色 / 暗色」，选择会持久化。

## 与后端对齐的能力

| 能力 | 说明 |
|------|------|
| 登录 / 注册 | `POST /api/auth/login`、`/api/auth/register` |
| 会话恢复 | `GET /api/auth/me` + UserDefaults 持久化 token |
| 退出 | `POST /api/auth/logout` |
| 对话 | `WS /ws?token=…`（`chat` / `connected` / `message_delta` / `message_end` / `error`） |
| 重连 | 连接失败与断线后校验会话并退避重连 |

## 目录

```
EasyAccount.xcodeproj/
EasyAccount/
  EasyAccountApp.swift
  AppConfig.swift
  Models/
  Services/
  ViewModels/
  Views/          # LoginView / ChatView / SideMenuView / Root
  Theme/
  Assets.xcassets/
  Info.plist
```
