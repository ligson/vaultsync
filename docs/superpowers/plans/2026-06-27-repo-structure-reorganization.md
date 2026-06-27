# 仓库目录重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 VaultSync 仓库重构为 `vaultsync-be/`、`vaultsync-app/` 和预留的 `vaultsync-fe/` 三个子目录，并同步更新所有路径引用与入口文档。

**Architecture:** 后端运行时代码、构建与部署文件整体迁移到 `vaultsync-be/`；Flutter 客户端工程放入 `vaultsync-app/`；网页管理端只预留目录和说明，不做实际实现。根目录仅保留跨端文档、规则、变更记录和仓库总索引，避免后续新子项目继续挤占根目录。

**Tech Stack:** Go, Flutter, Markdown, Docker, Makefile

---

## 文件结构

- Move: `cmd/` -> `vaultsync-be/cmd/`
- Move: `internal/` -> `vaultsync-be/internal/`
- Move: `migrations/` -> `vaultsync-be/migrations/`
- Move: `docker/` -> `vaultsync-be/docker/`
- Move: `go.mod` -> `vaultsync-be/go.mod`
- Move: `go.sum` -> `vaultsync-be/go.sum`
- Move: `Makefile` -> `vaultsync-be/Makefile`
- Modify: `README.md`：改成仓库总索引。
- Modify: `CHANGELOG.md`：记录本次重构。
- Modify: `AGENTS.md`：补充新目录约定。
- Modify: `docs/README.md`（如存在）或 `README.md`：补充子项目入口说明。
- Create: `vaultsync-app/README.md`
- Create: `vaultsync-fe/README.md`
- Modify: `docs/specs/2026-06-27-repo-structure-reorganization.md`

## Task 1: 后端目录搬迁

**Files:**
- Move: `cmd/` -> `vaultsync-be/cmd/`
- Move: `internal/` -> `vaultsync-be/internal/`
- Move: `migrations/` -> `vaultsync-be/migrations/`
- Move: `docker/` -> `vaultsync-be/docker/`
- Move: `go.mod` -> `vaultsync-be/go.mod`
- Move: `go.sum` -> `vaultsync-be/go.sum`
- Move: `Makefile` -> `vaultsync-be/Makefile`

- [x] **Step 1: 搬移后端目录**

将根目录下后端相关目录和文件整体移动到 `vaultsync-be/`，保持目录结构不变：

```text
vaultsync-be/
  cmd/
  internal/
  migrations/
  docker/
  go.mod
  go.sum
  Makefile
```

- [x] **Step 2: 运行后端测试确认路径仍可用**

Run: `cd vaultsync-be && rtk go test ./...`

Expected: PASS。

## Task 2: 根目录与子项目说明

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `docs/README.md`
- Create: `vaultsync-app/README.md`
- Create: `vaultsync-fe/README.md`

- [x] **Step 1: 更新根目录 README**

根目录 `README.md` 只保留仓库索引，明确：

- `vaultsync-be/` 是后端
- `vaultsync-app/` 是 Flutter 客户端
- `vaultsync-fe/` 是未来网页管理端

- [x] **Step 2: 更新规则与文档入口**

在 `AGENTS.md` 和 `docs/README.md` 里写明新目录职责，避免以后新内容继续堆回根目录。

- [x] **Step 3: 创建客户端与前端占位说明**

`vaultsync-app/README.md` 说明 Flutter 客户端后续将在此初始化；`vaultsync-fe/README.md` 说明网页管理端的预留位置。

## Task 3: 路径与命令更新

**Files:**
- Modify: `vaultsync-be/Makefile`
- Modify: `vaultsync-be/docker/docker-compose.yml`
- Modify: `vaultsync-be/docker/Dockerfile`
- Modify: `vaultsync-be/cmd/server/main_test.go`
- Modify: `vaultsync-be/README.md`（若需要新建）
- Modify: `CHANGELOG.md`

- [x] **Step 1: 更新构建与启动命令**

把后端构建、测试、运行命令都改成在 `vaultsync-be/` 下执行，例如：

```bash
cd vaultsync-be
rtk go test ./...
rtk make build
```

- [x] **Step 2: 更新 Docker 与 compose**

将镜像构建上下文和工作目录改成新的后端路径，保证 NAS 单机部署仍能一键启动。

- [x] **Step 3: 更新变更记录**

在 `CHANGELOG.md` 记录目录重构和路径迁移。

## Task 4: 最终验证与清理

**Files:**
- Modify: `docs/specs/2026-06-27-repo-structure-reorganization.md`

- [x] **Step 1: 全量验证**

Run: `cd vaultsync-be && rtk go test ./...`

Expected: PASS。

Run: `cd vaultsync-be && rtk make build`

Expected: PASS。

- [x] **Step 2: 清理旧 worktree**

确认 `codex/flutter-client-mvp` 如果不再使用，则清理；否则保持其独立存在，后续将 Flutter 客户端工程放入 `vaultsync-app/`。
