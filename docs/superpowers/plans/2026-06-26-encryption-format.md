# 加密格式规范 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 沉淀 VaultSync 第一版客户端加密格式，为后续客户端实现提供稳定协议依据。

**Architecture:** 本阶段只新增文档，不修改后端运行时代码。规格文档定义密钥层级、内容密文格式、元数据密文格式、上传/下载流程和后端约束；notes 记录长期算法决策；CHANGELOG 记录本次变更。

**Tech Stack:** Markdown, Argon2id, HKDF-SHA256, XChaCha20-Poly1305, SHA-256

---

## 文件结构

- Create: `docs/specs/2026-06-26-encryption-format.md`：加密格式规范 V1。
- Modify: `docs/notes/decisions.md`：记录算法和密钥层级决策。
- Modify: `docs/notes/backend-mvp.md`：补充后端对加密格式的处理边界。
- Modify: `CHANGELOG.md`：记录本阶段变更。

## Task 1: 加密格式规格文档

**Files:**
- Create: `docs/specs/2026-06-26-encryption-format.md`

- [x] **Step 1: 写规格文档**

覆盖以下内容：

- 威胁模型。
- 算法选择。
- 用户主密钥、同步目录密钥、文件版本密钥、元数据密钥。
- 内容密文对象格式。
- 加密元数据格式。
- `encrypted_name` 字段约定。
- 客户端上传/下载流程。
- 兼容升级策略。
- 后端约束。

- [x] **Step 2: 自查规格文档**

Run: `rtk rg -n "T[B]D|TO[D]O|待[定]|以[后]|适[当]|类[似]" docs/specs/2026-06-26-encryption-format.md || true`

Expected: 无输出。

## Task 2: 长期决策沉淀

**Files:**
- Modify: `docs/notes/decisions.md`
- Modify: `docs/notes/backend-mvp.md`

- [x] **Step 1: 更新决策文档**

在 `docs/notes/decisions.md` 记录：

- 第一版推荐 `Argon2id + HKDF-SHA256 + XChaCha20-Poly1305`。
- 服务器不解析密文格式，只保存不透明密文对象和加密元数据。

- [x] **Step 2: 更新后端记忆**

在 `docs/notes/backend-mvp.md` 记录：

- 后端只校验密文字节大小和归属，不校验明文语义。
- 后端日志不得输出完整密文元数据。

## Task 3: 变更记录与验证

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-06-26-encryption-format.md`

- [x] **Step 1: 更新 CHANGELOG**

记录新增加密格式规范。

- [x] **Step 2: 文档占位符扫描**

Run: `rtk rg -n "T[B]D|TO[D]O|待[定]|以[后]|适[当]|类[似]" docs/specs/2026-06-26-encryption-format.md docs/superpowers/plans/2026-06-26-encryption-format.md docs/notes/decisions.md docs/notes/backend-mvp.md CHANGELOG.md || true`

Expected: 无输出。

- [x] **Step 3: 基础验证**

Run: `rtk go test ./...`

Expected: PASS。

Run: `rtk make build`

Expected: PASS。
