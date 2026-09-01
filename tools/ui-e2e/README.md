# tools/ui-e2e —— GUI 端到端部署测试（CDP 驱动）

对打包产物 `cloudflare-deploy-engine-win_x64.exe`（Windows WebView2）做**真实用户视角**的全流程测试：
首启遮罩 → 保存凭证（DPAPI 落盘）→ 模板装载 → DryRun 演练 → 真实云端部署（探针验收）→
历史记录核对 → 销毁项目。

## 使用方法

```powershell
# 1. 设置 API Token（环境变量，唯一凭证通道，禁止写入文件）
$env:CDE_E2E_TOKEN = '<cfut_...>'

# 2. 运行（工作区根）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ui-e2e\run-e2e.ps1 `
  -Zip dist\Cloudflare-Deploy-Engine-v0.1.1.zip `
  -Account <Cloudflare账号ID> -Project cde-e2e-ui<stamp>
```

运行目录：工作区根 `_ui-e2e/`（app=解压产物，results.json=结构化结果，shots/=截图证据，driver.log=驱动日志）。

## 前置条件

- Windows 10/11 + WebView2 运行时（系统自带）
- Node.js（驱动用；仅开发测试机需要）
- 网络可达 api.cloudflare.com（部署用）；直连不通时可为 exe 进程注入 `HTTPS_PROXY` 环境变量

## 注意

- 凭证只经 `CDE_E2E_TOKEN`/run-e2e.ps1 参数传递，驱动/脚本/日志均不记录 token 原文；
  运行产生的 `app/data/config.enc.json` 为 DPAPI 加密（本机用户绑定），测试目录 `_ui-e2e/` 用完即删。
- 测试会在真实 Cloudflare 账号创建 `-Project` 指定项目的站点并随后销毁；请使用专用测试项目名。