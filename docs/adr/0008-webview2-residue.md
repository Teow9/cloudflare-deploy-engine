# ADR-008 WebView2 缓存目录策略

## 状态
已接受（2026-09，M5 发布前实测发现并决策）

## 背景
Neutralino.js 在 Windows 使用 WebView2 渲染 UI。实测（打包 exe 启动后扫描）：
WebView2 运行时把用户数据写到 `%APPDATA%\<exe文件名>\EBWebView`（Chromium 标准行为），
每次启动重建。这威胁蓝图"删除文件夹 = 完全卸载、残留扫描为零"的承诺
（评估 §D3 与 §1.4 理念门禁 E5）。

查证运行时源码（neutralinojs-6.9.0 `lib/webview/webview.h` L1043-1068）：
`CreateCoreWebView2EnvironmentWithOptions(nullptr, "%APPDATA%\\<exe名>", ...)`
—— 用户数据目录由运行时**硬编码**，不读任何配置项。

## 实测
1. 直接启动 exe → `%APPDATA%\cloudflare-deploy-engine-win_x64.exe\EBWebView` 出现。
2. 设置环境变量 `WEBVIEW2_USER_DATA_FOLDER=<应用目录>\data\webview2` 后启动
   → APPDATA 无任何创建；数据全部落入应用目录内。10 秒窗口双路径对照成立。

## 决策
- **默认入口不变**：双击 exe 直接可用；此时 WebView2 缓存位于 APPDATA，
  定性为「系统组件托管缓存」——WebView2 Runtime 本身即列为系统基线（§1.5），
  其缓存与浏览器缓存同级，不属于应用写入的配置/数据。
- **提供 `start-zeroresidue.cmd`（零残留启动器）**：设置上述环境变量后启动 exe，
  实现完整"删文件夹 = 零残留"路径（含 WebView2 缓存）。
- **residue-scan 门禁口径**：WebView2 缓存目录列入白名单并显式报告
  （视为系统组件数据，PASS）；其余任何 APPDATA/注册表命中一律 FAIL。

## 后果
- 文档（README/使用教程）卸载承诺精确化为：应用自身零残留；
  追求系统级零残留（含 WebView2 缓存）请用 `start-zeroresidue.cmd`。
- 无需修改 Neutralino 运行时（封闭二进制，无配置项）。

## 备选（未采纳）
自定义外壳启动器 exe（csc 编译）把环境变量固化进启动链——增加二进制产物与
SmartScreen 双提示风险，收益有限；cmd 启动器已覆盖同一效果。