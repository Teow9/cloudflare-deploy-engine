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

## [0.1.3] - 2026-09-01

### 修复
- **站点 URL 按请求名假设导致指向他人站点（实测事故）**：平台在项目名冲突时会给 pages.dev 子域加随机后缀（`my-tech-blog` → `my-tech-blog-64q.pages.dev`），旧实现一律按 `https://<请求名>.pages.dev` 上报结果与探针 URL——结果页指向同名他人站点，探针还误报"✅ 边缘存活"（假阳性）；现改为部署后从 API 取**真实 subdomain** 用于结果 URL 与探针（native/wrangler 两路）
- **模板内容升级**：`astro-site` 占位骨架替换为完整中文技术博客（文章列表/标签/关于/RSS，`{{site_title}}` 真实生效）

### 测试
- 真实账号部署验证：中文博客经 exe 界面部署成功、真实子域外部 200、内容标记校验

## [0.1.2] - 2026-09-01

### 修复
- **部署结果面板被后续装载覆盖**：`loadHistory` 等装载类引擎结果的 RESULT 也会渲染进结果面板（无 url/project → `<table></table>` 空表格，覆盖部署/销毁结果）；`runEngine` 增加 `{render:false}` 选项，仅部署/DryRun/销毁渲染面板
- **Add-DeployHistory 返回值泄漏到 stdout**：历史记录对象混入引擎输出与 UI 日志；deploy-core 调用点改为 `$null =` 捕获

### 测试
- 新增 `tools/ui-e2e/`：CDP 驱动的打包 exe 全流程自动化（首启/凭证/模板/DryRun/部署/历史/销毁 + 外部激活轮询 + 原始事件重放诊断）
- 真实账号 GUI 端到端：8 轮全流程执行；API 侧部署全部 success；平台资产库 check-missing 确认资产在库；**平台边缘激活当日故障窗口（probe 000 / 站点 500，旧内容 200）被引擎按设计正确报告**

## [0.1.1] - 2026-09-01

### 修复（桌面端全量启动链，用户实测"按钮无响应"的根因）
- **`Neutralino.init()` 误用导致整个界面静默瘫痪（核心根因）**：官方客户端库 `init()` 返回 `undefined`（不返回 Promise），旧写法 `Neutralino.init().then(init)` 在 `.then` 处同步抛 `TypeError`，init 从未执行、错误无人捕获、无任何日志——界面静态渲染正常但全部按钮无响应；改为先 `Neutralino.init()` 再对自身 `init()` 挂 `.catch`（CDP 实测启动异常捕获并修复）
- **引擎目录解析失效**：该 Neutralino 构建的 `os.getPath('exe'/'resources'/'cwd')` 均报 `Invalid platform path name`，`resolveEngineDir` 返回空串 → 引擎以根相对路径启动失败（exit=-196608）；改用运行时预注入变量 `window.NL_PATH`（= exe 目录）并做双候选兜底
- **`os.spawnProcess` args 数组被服务端忽略**：实测数组/对象两种形态均无效（PowerShell 以交互模式空跑、引擎从未执行）；改为把整条命令行作为 `command` 单串传递，参数按 Windows 规则引号化（路径含空格亦可）
- **RESULT 行跨事件分块导致解析失败**：大输出（插件/模板清单）被拆成多个 stdout 事件，JSON 解析落空 → 引擎误报"异常退出（exit=0）"；改为跨事件缓冲 + 按换行重组完整行
- **首启流程死循环**：点击「我已阅读并同意」后遮罩被 `loadConfig()` 重新弹出，界面永久遮挡；改为遮罩仅由 `init()` 展示一次 + `firstRunDismissed` 竞态防护，未保存凭证时给出日志提示
- **引擎调用失败静默化**：保存凭证 / AI 设置 / 导出导入 / 市场安装卸载 / 市场 URL 保存 / 销毁 / 历史与清单加载等按钮在引擎异常时无任何反馈（部分卡死 disabled）；全部补上 try/catch 与可见错误提示
- **引擎 stdout 编码加固**：`utils.ps1` 强制 `[Console]::OutputEncoding = UTF-8`，杜绝 PS5.1 OEM 代码页导致的中文日志乱码与 RESULT JSON 损坏
- **构建期 BOM 防护**：非 ASCII `.ps1` 必须带 UTF-8 BOM（PS5.1 按 ANSI 读取导致语法崩溃，本次构建实测拦截）
- **发布通道代理**：`release.ps1` 的 tag 推送未透传 `-Proxy`（直连 github.com 间歇失败），补上代理配置

### 测试
- 打包 exe 真实 UI 冒烟（CDP 驱动，Windows WebView2 实测）：首启遮罩、绑定、DryRun、凭证保存、插件市场、历史刷新、JS 错误零报告
- Pester 70/70（9 套件）、语法 32 脚本、密扫、模板完整性、尺寸门禁、zip 断言全部通过

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

[Unreleased]: https://github.com/Teow9/cloudflare-deploy-engine/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/Teow9/cloudflare-deploy-engine/releases/tag/v0.1.3
[0.1.2]: https://github.com/Teow9/cloudflare-deploy-engine/releases/tag/v0.1.2
[0.1.1]: https://github.com/Teow9/cloudflare-deploy-engine/releases/tag/v0.1.1
[0.1.0]: https://github.com/Teow9/cloudflare-deploy-engine/releases/tag/v0.1.0