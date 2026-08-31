# ADR-004: AI 后端抽象（插件轴）

**Status**: accepted
**日期**: 2026-08-31

## 背景
蓝图 AI 默认 `gpt-3.5-turbo`（已过时），且 AI 服务应可插拔（OpenAI / Claude / Ollama / DeepSeek / 自定义）。

## 决策
- AI 是插件轴（`ai`），MVP 内置 `openai-compatible` handler：兼容 OpenAI 协议（`/chat/completions`，Bearer Key）。
- 配置存于 `data/config.enc.json` 的 `ai` 块：`baseUrl` / `model` / `apiKey`(加密)。模型默认值由 UI 下拉提供（如 `gpt-4o-mini`、`deepseek-chat`、`qwen-plus`），不强绑单一厂商；`baseUrl` 指向 `http://localhost:11434/v1` 即适配 Ollama。
- AI 只负责"生成方案并回填表单"，永不自动执行部署。

## 后果
- 正面：任何 RESTful AI 服务可接入；无厂商锁定。
- 代价：自定义协议服务（非 OpenAI 兼容）需新 handler，作为新插件交付。