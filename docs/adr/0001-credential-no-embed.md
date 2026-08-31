# ADR-001: 凭证默认不注入部署产物

**Status**: accepted
**日期**: 2026-08-31

## 背景
早期原型工具曾将账号级 API Token / AccountId / Email 注入 `EMBEDED_SETTINGS` 随 `_worker.js` 部署到公网边缘，Token 要求 Pages/Workers/KV 全 Edit——一旦面板被攻破或代码泄露，等于交出账号写权限。

## 决策
- `deploy-core.ps1` 的部署管线**默认不向产物写入任何凭证**（模板 manifest 声明 `embedCredentials: false`）。
- 若模板显式声明需要凭证注入（如带后端的面板类模板），UI 必须先告警 + 用户二次确认，且注入内容经过脱敏审计。
- CI 提供自动化断言：部署后反查产物，不得出现 Token/Email 明文。

## 后果
- 正面：即使产物泄露，不影响账号安全；与新项目"绝对的用户可控"叙事一致。
- 代价：面板类模板需额外确认流程；MVP 模板均为静态站，不受影响。