# Cloudflare Deploy Engine

> **轻量级、零依赖、数据全本地、AI 赋能的 Cloudflare Pages / Workers 一键部署工具。**
>
> 你的数据在你手里，你的选择在你手里。我们只做一件事——把你的代码送到 Cloudflare。

![License](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078d6)
![Size](https://img.shields.io/badge/exe-2.36%20MB-4ade80)
![Tests](https://img.shields.io/badge/tests-68%20passing-4ade80)

---

## 功能特性

- **一键部署**：本地文件夹、GitHub / GitLab 仓库、本地压缩包 → Cloudflare Pages，全程图形界面
- **零依赖**：用户不需要安装 Node.js / git / wrangler 等任何软件（基于 Windows 内置组件）
- **完全本地化**：凭证 Windows DPAPI 加密、数据只存应用目录，删除文件夹即完全卸载
- **五套预构建模板**：纯静态 / Astro / React（含枚举参数）/ 多页文档站 / 链接导航站
- **AI 智能辅助**：自然语言描述需求，AI 生成方案并回填表单——**只建议，永不自动部署**
- **插件体系**：四轴插件（来源 / 模板 / AI / 目标）+ 插件市场，全部可扩展
- **工程级韧性**：平台故障自动重试、部署存活探针验收、双后端（native / wrangler）
- **公开透明**：部署产物零凭证、日志全脱敏、无遥测、无账号体系

## 快速开始

1. 从 **Releases** 下载 `Cloudflare-Deploy-Engine-vX.Y.Z.zip`（约 1.3 MB）。
2. 解压到任意目录，双击 `cloudflare-deploy-engine-win_x64.exe`（SmartScreen 提示时选"更多信息 → 仍要运行"）。
3. 按「🔒 Token 权限指引」创建独立 API Token（只需 **Cloudflare Pages — Edit**），填入凭证并加密保存。
4. 选模板 → 填参数 → 点「🚀 部署」→ 探针验收通过后，你的站点即上线。

> 详细步骤见 **[使用说明.md](./使用说明.md)** 与 **[docs/使用教程.md](./docs/使用教程.md)**。
> 追求系统级零残留可用随包的 `start-zeroresidue.cmd` 启动（ADR-008）。

## 文档索引

| 文档 | 内容 |
| :--- | :--- |
| [使用说明.md](./使用说明.md) | 完整手册（14 章：安装 / 部署 / 模板 / 来源 / AI / 市场 / CLI / 故障排查） |
| [docs/使用教程.md](./docs/使用教程.md) | 快速上手教程 |
| [docs/插件开发指南.md](./docs/插件开发指南.md) | 四轴插件 handler 契约 |
| [docs/模板开发指南.md](./docs/模板开发指南.md) | template.json 规范与完整性要求 |
| [docs/手工验收矩阵.md](./docs/手工验收矩阵.md) | 外部验收清单 |
| [docs/adr/](./docs/adr/) | 架构决策记录（ADR-001 ~ 008） |

## 技术架构

```
┌────────────────────────────────────────────┐
│ Neutralino.js 桌面壳（exe 2.36MB）          │
│   HTML/CSS/JS UI · 最小能力集 · WebView2    │
├────────────────────────────────────────────┤
│ PowerShell 引擎（Windows 内置，PS 5.1）     │
│   deploy-core / config-manager / market /  │
│   plugin-manager / template-manager / ...  │
├────────────────────────────────────────────┤
│ 插件注册表 plugins.json（用户可编辑）        │
│   sources×4 · templates×5 · ai×1 ·         │
│   targets×2                                │
├────────────────────────────────────────────┤
│ 数据层 data/（DPAPI 加密 · 随目录删除）      │
└────────────────────────────────────────────┘
```

- **运行时协议**：stdout 双行协议（`LOG|` 日志流 / `RESULT|` 结果 JSON）；跨进程参数走 Base64(UTF-8) 安全通道
- **部署目标**：Cloudflare Pages（官方两段式资产上传协议）／ Workers（脚本直传，可选子域）
- **UI**：动态表单、实时日志、探针验收卡片、部署历史与一键重部署（回滚）

## 内置插件（v0.1.0）

| 轴 | 插件 |
| :--- | :--- |
| **sources** 来源 | `local` 本地文件夹 · `github` · `gitlab`（均为零依赖归档下载）· `zip` 本地压缩包 |
| **templates** 模板 | `plain` · `astro-site` · `react-vite` · `docs-site` · `nav-site`（全部预构建） |
| **ai** AI 后端 | `openai-compatible`（兼容 OpenAI / DeepSeek / Ollama / vLLM 等） |
| **targets** 目标 | `pages`（默认）· `workers` |

## 开发者

```powershell
# 1. 环境引导（仅开发者需要；node/npm → neu CLI → 运行时）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\bootstrap.ps1

# 2. 引擎冒烟（无需凭据）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy-core.ps1 -ListPlugins
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy-core.ps1 -ListTemplates

# 3. DryRun 演练（无副作用；JSON 参数走 Base64 通道防引号剥离）
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"site_title":"测试"}'))
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy-core.ps1 `
  -TemplateId plain -ParamsB64 $b64 -DryRun

# 4. 单测 / 全部门禁 / 打开发布包
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Script tests -EnableExit"
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\build-release.ps1   # 门禁+打包
```

**质量门禁**（CI 六作业 + 发布流水线）：Pester 68 项 / 语法与 ScriptAnalyzer / 无凭据扫描 /
模板完整性 / 尺寸（exe ≤ 5MB · templates ≤ 3MB · zip ≤ 10MB）／ zip 内容断言（无运行时数据、
无嵌套目录、关键文件齐备）。

## 安全与合规

- **凭证安全**：API Token / AI Key 仅经 Windows DPAPI（当前用户）加密存于 `data/config.enc.json`；
  导出迁移使用口令加密（PBKDF2 + AES-256）；任何日志与部署产物均不含明文凭证（自动化断言）。
- **合规边界**：本项目仅用于**合法技术研究与合规场景**：部署你自己的内容到你自己账号。
  本项目**不提供、不运营、不推销任何网络代理服务**，不包含代理 / VPN / 订阅 / 优选 IP 相关功能模块；
  使用者须遵守所在地法律与 Cloudflare 服务条款，因使用产生的风险由使用者自行承担。
- **卸载**：应用自身零残留（不写注册表 / APPDATA / USERPROFILE），删除文件夹即卸载；
  WebView2 系统缓存口径与零残留启动器见 [docs/adr/0008](./docs/adr/0008-webview2-residue.md)。

## 路线图

- **已完成（v0.1.0）**：引擎 / 桌面 UI / 双目标 / 插件市场 / 五模板 / 部署历史与回滚 / i18n / 发布流水线
- **外部验收中**：无 Node 干净虚拟机全流程计时、桌面交互目测、CI 首跑（推送后自动执行）
- **Backlog**：R2/D1 部署目标、AI 多轮对话、插件市场默认源上线

## 贡献

欢迎 Issue 与 PR。请确保：`tests\syntax-check.ps1`、Pester 全套、`check-no-secrets.ps1` 通过；
发布级改动请附对应测试与《测试报告》更新。

## 许可证

[MIT](./LICENSE)（仓库未含 LICENSE 文件时将随首个 Release 补充；Neutralino.js 遵循其上游许可证；
内置模板遵循其各自来源许可证）。