# ADR-005: 发布物策略（单文件 exe + zip + SHA256）

**Status**: accepted
**日期**: 2026-02

## 背景
Neutralino `neu build --embed-resources` 产出未签名单文件 exe，会触发 Windows SmartScreen / Defender 拦截；蓝图未处理。

## 决策
- 发布物：`Cloudflare-Deploy-Engine-vX.Y.Z.zip` = exe + `templates/` + `plugins.json` + README + SHA256 校验文件。
- README 顶部给 SmartScreen 引导（"更多信息 → 仍要运行"）；Release Notes 附 SHA256；不承诺免拦截。
- 若发布后下载转化明显受损，再评估代码签名（EV/OV）——非 MVP 阻塞项。

## 后果
- 正面：零签名成本上线；完整性可校验。
- 代价：部分小白用户可能被 SmartScreen 劝退；属已知可接受成本。