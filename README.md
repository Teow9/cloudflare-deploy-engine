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

## 当前状态（M0/M1 骨架完成）

- ✅ 引擎层：`utils`（DPAPI/口令加密/脱敏）、`config-manager`（加解密存取/导出导入迁移）、`plugin-manager`（四轴注册分发）、`template-manager`（参数展开）、`deploy-core`（通用部署管线）、`destroy`、`ai-bridge`
- ✅ 插件：sources×3（local/github/zip）、templates×2（plain/astro-site）、ai×1（openai-compatible）、targets×1（pages）
- ✅ 测试：Pester 单测 ×5 + 语法检查 + 无凭据扫描 + CI 五线
- 🚧 M2 桌面 UI、M3 sources 联调验收、M4 AI 对话界面：按 `实现计划.md` 推进

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

## 许可证

MIT License。（Neutralino.js 遵循其上游许可证；内置模板遵循其各自来源许可证。）