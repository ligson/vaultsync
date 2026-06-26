# 同步协议 V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 沉淀 VaultSync 第一版同步协议，为后续客户端实现和后端协议演进提供依据。

**Architecture:** 本阶段只新增和更新文档，不修改 Go 运行时代码。同步协议规格描述设备初始化、本地扫描、上传、变更拉取、下载、冲突、本地清理、幂等重试和当前后端支持度；notes 记录长期协议决策；CHANGELOG 记录本次变更。

**Tech Stack:** Markdown, HTTP API, SQLite cursor, encrypted file versions

---

## 文件结构

- Create: `docs/specs/2026-06-26-sync-protocol.md`：同步协议 V1。
- Modify: `docs/notes/decisions.md`：记录文件级增量、客户端冲突副本、删除语义等协议决策。
- Modify: `docs/notes/backend-mvp.md`：补充当前后端同步协议支持边界。
- Modify: `CHANGELOG.md`：记录本阶段变更。

## Task 1: 同步协议规格文档

**Files:**
- Create: `docs/specs/2026-06-26-sync-protocol.md`

- [x] **Step 1: 写规格文档**

覆盖以下内容：

- 核心原则。
- 设备初始化流程。
- 本地扫描模型。
- 上传协议。
- 变更拉取协议。
- 下载协议。
- 冲突判定与冲突副本。
- 删除语义。
- 本地清理策略触发点。
- 幂等与重试。
- 当前后端支持度。

- [x] **Step 2: 自查规格文档**

Run: `rtk rg -n "T[B]D|TO[D]O|待[定]|以[后]|适[当]|类[似]" docs/specs/2026-06-26-sync-protocol.md || true`

Expected: 无输出。

## Task 2: 长期决策沉淀

**Files:**
- Modify: `docs/notes/decisions.md`
- Modify: `docs/notes/backend-mvp.md`

- [x] **Step 1: 更新决策文档**

记录：

- V1 采用文件级增量同步。
- V1 冲突由客户端生成冲突副本，不做自动合并。
- V1 不实现远端删除墓碑，本地清理不等于远端删除。
- 后续应把用户维度游标升级为设备维度游标。

- [x] **Step 2: 更新后端记忆**

记录：

- 当前后端支持上传版本、变更列表和下载密文对象。
- 当前 `sync_cursors` 是用户维度，适合 MVP，但多设备阶段应升级。

## Task 3: 变更记录与验证

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-06-26-sync-protocol.md`

- [x] **Step 1: 更新 CHANGELOG**

记录新增同步协议 V1 规格。

- [x] **Step 2: 文档占位符扫描**

Run: `rtk rg -n "T[B]D|TO[D]O|待[定]|以[后]|适[当]|类[似]" docs/specs/2026-06-26-sync-protocol.md docs/superpowers/plans/2026-06-26-sync-protocol.md docs/notes/decisions.md docs/notes/backend-mvp.md CHANGELOG.md || true`

Expected: 无输出。

- [x] **Step 3: 基础验证**

Run: `rtk go test ./...`

Expected: PASS。

Run: `rtk make build`

Expected: PASS。
