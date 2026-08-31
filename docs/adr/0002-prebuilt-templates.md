# ADR-002: 模板预构建分发

**Status**: accepted
**日期**: 2026-02

## 背景
蓝图模板构建走 `npm install && npm run build`，要求用户机器安装 Node.js——与"零依赖、下载即用"的核心理念直接冲突。

## 决策
- `templates/<id>/` 只随包分发**构建完成态产物** + `template.json` + 参数占位符说明。
- 模板源码与构建脚本放在 `templates-src/`（仅维护者使用），`build-all.ps1` 产出产物前必须通过 `check-build-integrity.ps1`（体积上限、无 `node_modules`、无 `.env`、无源码泄漏）。
- 用户机器零 Node 依赖；M3 验收硬性门禁 = 未安装 Node.js 的干净 Windows 上全流程部署成功。

## 后果
- 正面：兑现零依赖；产物可控（供应链只发生在维护端）。
- 代价：模板参数只能在"构建期变量 / 文件占位符"两种形式内支持；新增模板需要维护者在 CI 里构建。