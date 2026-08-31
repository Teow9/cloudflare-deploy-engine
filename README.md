# Cloudflare Deploy Engine

> 轻量级、零依赖、数据全本地、AI 赋能的 Cloudflare Pages 一键部署工具。
> **你的数据在你手里，你的选择在你手里。我们只做一件事——把你的代码送到 Cloudflare。**

## 核心理念（四条承诺，均有可验证指标）

| 理念 | 落地机制 | 验证指标 |
| :--- | :--- | :--- |
| 极致轻量化 | Neutralino.js 单文件壳 + 预构建模板 | exe ≤ 5MB / templates ≤ 3MB / zip ≤ 10MB（CI 断言） |
| 零依赖 | 模板预构建分发 + Windows 内置组件（PowerShell/curl/tar/WebView2） | 无 Node 环境全流程部署验收 |
| 万物皆插件 | `plugins.json` 四轴注册（sources/templates/ai/targets）+ 统一分发 | `Get-PluginList` 枚举四轴 ≥ 全部内置插件可调用 |
| 降低使用成本 | 一键部署 + AI 回填表单（永不自动部署）+ 删除文件夹即卸载 | 全新机器下载→部署 ≤ 15 分钟 |

## 当前状态（M2–M5 完成，MVP 可发布）

- ✅ 引擎层：`utils`（DPAPI/口令加密/脱敏）、`config-manager`（加解密存取/导出导入迁移）、`plugin-manager`（四轴注册分发）、`template-manager`（参数展开）、`deploy-core`（通用部署管线）、`destroy`、`ai-bridge`
- ✅ 插件：sources×3（local/github/zip）、templates×2（plain/astro-site）、ai×1（openai-compatible）、targets×1（pages）
- ✅ M2 桌面 UI：来源/模板动态表单、项目名、取消与看门狗、导出/导入向导、Token 权限指引、首启免责流程、AI 设置持久化、`servingOk/attempts` 结果卡片
- ✅ M4 AI：设置面板（baseUrl/model/apiKey DPAPI 加密）+ 需求→方案回填（永不自动部署）
- ✅ M5 发布：`build-release.ps1` 门禁（语法/Pester/密扫/尺寸 ≤5MB+≤3MB+≤10MB）、zip+SHA256、CI 打包作业、`residue-scan` 零残留验收、使用教程/模板开发指南/手工验收矩阵
- 🚧 待办：干净虚拟机无 Node 验收（A9/E4）、交互桌面目测（D2–D4）、GitHub 仓库推送后首跑 CI

## 目录结构

```
app/             Neutralino 前端（HTML/CSS/JS）
scripts/         PowerShell 引擎（插件体系见 docs/插件开发指南.md）
templates/       内置预构建模板（ADR-002）
templates-src/   模板源码与构建（维护者专用，M3 落地）
plugins.json     四轴插件注册表（用户可编辑）
tests/           Pester 单测 + 语法检查 + 无凭据扫描
docs/            使用教程、ADR、插件开发指南
```

## 开发者快速开始

```powershell
# 1. 引导（node/npm → neu CLI → 运行时）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\bootstrap.ps1

# 2. 引擎冒烟（无需任何凭据）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy-core.ps1 -ListPlugins
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy-core.ps1 -ListTemplates

# 3. DryRun 演练（无副作用）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy-core.ps1 -TemplateId plain -ParamsJson '{"site_title":"测试"}' -DryRun

# 4. 单测
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Script tests -EnableExit"

# 5. 桌面运行
neu run
```

## 合规声明

- 本项目仅用于**合法的技术研究、学习与合规场景**：部署用户自有内容到用户自己的 Cloudflare 账号。
- 本项目**不提供、不运营、不推销任何网络代理服务**，不包含代理/VPN/订阅/优选 IP 相关功能模块。
- 使用者必须遵守所在地法律法规与 Cloudflare 服务条款；因使用产生的任何法律、账号或安全风险，由使用者自行承担。
- 凭证仅存于本机 `data/config.enc.json`（Windows DPAPI 加密），删除文件夹即完全卸载。
- 卸载口径（ADR-008）：应用自身零残留（不写注册表/APPDATA/USERPROFILE）；直接双击 exe 时，
  WebView2 运行时会在 `%APPDATA%\<exe名>` 写入**系统组件缓存**（与浏览器缓存同级，系统托管）；
  追求系统级零残留请用 `start-zeroresidue.cmd` 启动（缓存收进应用目录）。

## 许可证

MIT License。（Neutralino.js 遵循其上游许可证；内置模板遵循其各自来源许可证。）