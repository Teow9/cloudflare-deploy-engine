# Changelog

本文件记录 Cloudflare Deploy Engine 的每个发布版本。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；
版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)（详见 `docs/版本管理.md`）。

## [Unreleased]

### 计划中
- 无 Node 干净虚拟机全流程验收（`docs/手工验收矩阵.md` A9/E4）
- R2 / D1 部署目标（需新 Token 权限与签名/SQL 实现）
- AI 多轮对话（当前为单轮生成 + 回填）
- 插件市场默认源上线（随 Releases 托管 `market.json`）

## [0.1.0] - 2026-08-31

### 新增
- **轻量化桌面应用**：Neutralino.js 壳 + PowerShell 引擎，exe 2.36 MB、全包 zip ~1.3 MB，零外部依赖（Windows 10/11 内置组件）
- **一键部署**：本地文件夹 / GitHub / GitLab / 本地压缩包 四种来源 → Cloudflare Pages（官方两段式资产上传协议）或 Workers（脚本直传）
- **五套预构建模板**：plain（纯静态）、astro-site（Astro 博客）、react-vite（含 `theme` 枚举参数）、docs-site（三页文档站）、nav-site（JSON 参数化导航）
- **插件体系（四轴）**：sources×4 / templates×5 / ai×1 / targets×2，全部经 `plugins.json` 注册与统一分发；**插件市场**：远程清单 + SHA256 校验 + 安装/卸载（内置插件白名单保护）
- **AI 智能辅助**：OpenAI 兼容协议（OpenAI/DeepSeek/Ollama 等），需求描述 → 方案生成并回填表单；**只生成方案，永不自动部署**；失败自动重试与降级手填
- **凭证与数据安全**：Windows DPAPI（CurrentUser）加密存储；口令加密导出/导入迁移（PBKDF2 + AES-256 + HMAC）；部署产物零凭证（ADR-001）
- **部署历史与回滚**：最近 50 条历史（含参数与来源）；一键重放即回滚（Pages 资产 hash 复用）
- **韧性工程**：平台故障窗口自动重试（含强制重传）与部署存活探针验收门；双后端 `native` / `wrangler`
- **桌面 UI**：动态表单（枚举渲染下拉）、实时日志、探针结果卡片、取消与看门狗、导出/导入向导、Token 权限指引、首启免责流程、中英文切换
- **零残留**：应用不写注册表/APPDATA/USERPROFILE；`start-zeroresidue.cmd` 连 WebView2 缓存一并收入应用目录（ADR-008）

### 修复
- 平台级（京津冀真实账号验证）：Token 校验方法（GET）、JSON 引号剥离（临时文件通道）、manifest 部件 Content-Type 规则（不得携带）、平台间歇故障韧性（非 JSON 防护/重试/强传/探针）
- 发布级：neu CLI/运行时版本线修正（11.7.2 / 6.9.0）、asar 暂存污染（.tmp 清理）、zip 运行时数据混入（内容断言）、发布装配嵌套（scripts\scripts 幂等修复 + zip 断言）
- 引擎级：PS 5.1 六大环境坑（@() 管道单元素化、foreach 变量大小写吞参、Mandatory 掩盖原始异常、B64 参数通道化、旧配置字段迁移、8.3 短名路径截串）
- CI 级：Pester 3.4 锁定（与引擎运行时一致）、测试清单补全 9 套件、客户端库自愈依赖（@neutralinojs/lib）

### 测试
- Pester 单测 **70/70**（9 套件：utils/config/plugin/template/engine-state/market/pages/workers/deploy-core）
- 语法检查 31 脚本、无凭据扫描、模板完整性、尺寸门禁（exe≤5MB/templates≤3MB/zip≤10MB）、zip 内容断言、残留扫描
- 真实账号端到端：五模板 × 四来源 + Workers 上传/删除 + 历史重放 + 双后端兜底，>20 个部署记录

### 已知事项
- 未签名 exe：SmartScreen 提示"更多信息 → 仍要运行"（ADR-005，附 SHA256 校验）
- WebView2 系统缓存：直接启动 exe 时写入 `%APPDATA%\<exe名>`（ADR-008）；零残留请用 `start-zeroresidue.cmd`
- Workers 子域启用需账户级权限（实测 10405）；脚本请用 Service Worker 格式（`addEventListener("fetch",…)`）
- GitLab 来源：仓库含空格文件名时按引擎规则拒绝直传（防护行为，非缺陷）
- Token 建议最小权限：仅 `Cloudflare Pages: Edit`（ADR-006）

[Unreleased]: https://github.com/Teow9/cloudflare-deploy-engine/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Teow9/cloudflare-deploy-engine/releases/tag/v0.1.0