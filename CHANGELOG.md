# 变更记录

所有有意义的项目变更都应记录在这里。

## 2026-06-25

- 对齐 SQLite 初始化表结构与后端 MVP 实现计划，补充核心表和关键列的 schema 测试。
- 新增 SQLite 初始化与迁移层，启用 WAL，并创建后端 MVP 核心元数据表。
- 收紧 Go 后端工程骨架基线：降低 Go 版本目标、补充配置测试，并忽略本地构建产物。
- 初始化 Go 后端工程骨架，新增配置加载、应用装配、服务入口和基础测试。
- 新增 `.gitignore`，忽略 `.worktrees/` 隔离工作区目录。
- 新增 Go + SQLite 后端 MVP 实现计划文档，路径为 `docs/superpowers/plans/2026-06-25-go-sqlite-backend-mvp.md`。
- 补充规则：实现计划统一放在 `docs/superpowers/plans/`。
- 将根目录 `README.md` 中文化。
- 将项目文档规则改为尽可能使用中文编写，技术名词和代码标识可保留英文。
- 将现有规则、说明和决策文档中的英文说明改为中文。
- 新增 `AGENTS.md` 仓库规则。
- 新增 `docs/` 文档结构。
- 新增第一版 VaultSync 设计稿。
- 新增用于沉淀决策和项目记忆的 `docs/notes/`。
