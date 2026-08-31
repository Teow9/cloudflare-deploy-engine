# ADR-003: DPAPI 凭证存储与"导出/导入重加密"迁移流程

**Status**: accepted
**日期**: 2026-02

## 背景
Windows DPAPI `DataProtectionScope.CurrentUser` 加密数据与**机器+用户**绑定，换机无法解密。蓝图"复制文件夹到新电脑即用"的便携承诺对加密凭证不成立。

## 决策
- 本地存储：`data/config.enc.json`，敏感字段（accountId/apiToken/email/ai.apiKey）逐字段 DPAPI 加密；非敏感字段明文。
- 换机迁移：`Export-Config` 用**用户口令**（PBKDF2 100k 迭代 → AES-256-CBC + HMAC-SHA256，encrypt-then-MAC）加密导出为 `export.json`；`Import-Config` 在目标机输入口令解密后**重新 DPAPI 加密**落盘。
- 文档明示口径：配置可迁移，凭证需在目标机重输口令导入。

## 后果
- 正面：安全、合规的迁移路径；无明文落盘。
- 代价：口令强度决定导出文件安全；导出口令丢失即无法恢复（设计如此，防暴力）。