# ADR-007: 插件机制为 MVP 一等公民（机制与内容分离）

**Status**: accepted
**日期**: 2026-08-31

## 背景
"万物皆插件"是项目核心理念契约：代码来源、模板、AI 后端、部署目标均可插拔（蓝图 §5.4）。若把机制推迟到市场之后，理念契约将落空。

## 决策
- **机制进 MVP**：`plugins.json` 四轴注册表（sources/templates/ai/targets，用户可编辑）+ `plugin-manager.ps1` 统一注册与分发 + handler 契约（`scripts/plugins/<轴>/<id>.ps1` 定义 `Invoke-<前缀><Id>` 函数，接收 `-Args` 哈希表）。
- **内容精简但齐全**：MVP 内置 sources×3（local/github/zip）、templates×2（plain/astro-site）、ai×1（openai-compatible）、targets×1（pages）。
  > 2026-09 更新：已扩充至 sources×4（+gitlab）、templates×5（+react-vite/docs-site/nav-site）、targets×2（+workers），见 `plugins.json`。
- **市场（M5 已交付）**：远程清单 `market.json` + SHA256 校验 + 安装/卸载/内置白名单；远程共享、版本管理属于此机制的增量应用。
  > 2026-09 更新：插件市场已随 v0.1.0 交付（`market.ps1` registry/search/install/uninstall + UI 模态）；默认市场源待随项目 Release 托管上线。
- 验收线：`Get-PluginList` 可枚举四轴全部内置插件且均可实际调用；plugins.json schema 进 CI 校验。

## 后果
- 正面：理念契约在第一个可用版本即成立；后续一切能力 = 新增插件。
- 代价：M1 增加 plugin-manager 工作量（约 5~8h），视为理念合规成本，不砍。