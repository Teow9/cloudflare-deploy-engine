# ADR-006: Cloudflare Token 最小权限引导

**Status**: accepted
**日期**: 2026-08-31

## 背景
早期原型要求 Token 覆盖 Pages/Workers/KV 全 Edit，且随产物部署到公网（见 ADR-001）。Token 权限越大，泄露损失越大。

## 决策
- 首启 UI 提供"Token 权限指引"：静态站点部署**只需 `Cloudflare Pages: Edit`**（Account 级，限定单一账号）。
- 仅当模板声明需要 KV / Workers 时才要求额外权限，并在模板选择处显式提示。
- 推荐用户为工具创建**独立 API Token**（非账户全局 Token），便于随时吊销。

## 后果
- 正面：默认最小权限；泄露损失收敛到单个 Pages 项目可管理范围。
- 代价：模板若需 KV 需额外引导，UI 文案成本。