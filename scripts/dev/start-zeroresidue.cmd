# Cloudflare Deploy Engine —— 零残留启动器
# 作用：设置 WEBVIEW2_USER_DATA_FOLDER，把 WebView2 运行时缓存收进应用目录
#       （data/webview2），实现"删除应用文件夹 = 完全卸载"（含系统缓存零残留）。
# 原理（ADR-008）：Neutralino 运行时硬编码 userDataFolder=%APPDATA%\<exe名>，
#       但实测 WebView2 SDK 优先采用本环境变量，数据即落入应用目录。
# 用法：双击本文件，或从命令行调用：
#   start-zeroresidue.cmd
@echo off
setlocal
set "WEBVIEW2_USER_DATA_FOLDER=%~dp0data\webview2"
start "" "%~dp0cloudflare-deploy-engine-win_x64.exe"
endlocal