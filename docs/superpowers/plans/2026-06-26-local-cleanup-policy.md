# 客户端本地清理策略 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 沉淀 VaultSync 客户端上传成功后的本地清理策略，明确 `keep`、`delete`、`archive` 的安全边界和移动端权限要求。

**Architecture:** 本阶段只新增和更新文档，不修改 Go 运行时代码。规格文档描述策略类型、安全触发条件、失败重试、移动端相册权限、用户确认、本地待处理任务和后端边界；notes 记录长期产品决策；CHANGELOG 记录本次变更。

**Tech Stack:** Markdown, client sync policy, mobile photo permissions

---

## 文件结构

- Create: `docs/specs/2026-06-26-local-cleanup-policy.md`：客户端本地清理策略 V1。
- Modify: `docs/notes/decisions.md`：记录本地清理不等于远端删除、清理失败不回滚远端上传等决策。
- Modify: `docs/notes/backend-mvp.md`：补充后端只保存策略配置、不执行本地清理。
- Modify: `CHANGELOG.md`：记录本阶段变更。

## Task 1: 本地清理策略规格文档

**Files:**
- Create: `docs/specs/2026-06-26-local-cleanup-policy.md`

- [x] **Step 1: 写规格文档**

覆盖以下内容：

- 策略类型。
- 安全触发条件。
- `keep` 策略。
- `delete` 策略。
- `archive` 策略。
- 移动端相册清理。
- 用户确认与防误删。
- 本地待处理任务。
- 与同步协议的关系。
- 日志与隐私。
- 后端边界。

- [x] **Step 2: 自查规格文档**

Run: `rtk rg -n "T[B]D|TO[D]O|待[定]|以[后]|适[当]|类[似]" docs/specs/2026-06-26-local-cleanup-policy.md || true`

Expected: 无输出。

## Task 2: 长期决策沉淀

**Files:**
- Modify: `docs/notes/decisions.md`
- Modify: `docs/notes/backend-mvp.md`

- [x] **Step 1: 更新决策文档**

记录：

- `keep` 是默认策略。
- `delete` 和 `archive` 只在上传完成、本地索引落盘后执行。
- 清理失败不回滚远端上传。
- 后端不执行本地清理。

- [x] **Step 2: 更新后端记忆**

记录：

- 后端只保存 `cleanup_policy` 和 `archive_path`。
- 后端不得把本地 `delete` 策略解释为远端删除。

## Task 3: 变更记录与验证

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-06-26-local-cleanup-policy.md`

- [x] **Step 1: 更新 CHANGELOG**

记录新增本地清理策略 V1 规格。

- [x] **Step 2: 文档占位符扫描**

Run: `rtk rg -n "T[B]D|TO[D]O|待[定]|以[后]|适[当]|类[似]" docs/specs/2026-06-26-local-cleanup-policy.md docs/superpowers/plans/2026-06-26-local-cleanup-policy.md docs/notes/decisions.md docs/notes/backend-mvp.md CHANGELOG.md || true`

Expected: 无输出。

- [x] **Step 3: 基础验证**

Run: `rtk go test ./...`

Expected: PASS。

Run: `rtk make build`

Expected: PASS。
