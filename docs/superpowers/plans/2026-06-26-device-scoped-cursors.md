# 设备维度变更游标 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将变更游标从用户维度升级为设备维度，同时保持旧的无 `device_id` 调用兼容。

**Architecture:** `GET /api/v1/changes` 新增可选 `device_id` 查询参数。后端校验该设备属于当前用户后，按 `(user_id, device_id)` 持久化游标；未传 `device_id` 时使用 `__legacy__` 作为兼容游标键。SQLite `sync_cursors` 表改为复合主键。

**Tech Stack:** Go, net/http, database/sql, SQLite

---

## 文件结构

- Modify: `internal/store/migrate.go`：`sync_cursors` 增加 `device_id` 并使用 `(user_id, device_id)` 复合主键。
- Modify: `internal/store/db_test.go`：更新 schema 期望。
- Modify: `internal/service/change_service.go`：新增设备维度游标写入。
- Modify: `internal/httpapi/handlers/change_handler.go`：读取 `device_id` 查询参数。
- Modify: `internal/app/app.go`：注入 `DeviceRepo` 到 `ChangeService`。
- Modify: `tests/integration/upload_flow_test.go`：新增多设备游标互不覆盖集成测试。
- Modify: `docs/notes/decisions.md`：更新设备维度游标决策。
- Modify: `docs/notes/backend-mvp.md`：更新后端游标记忆。
- Modify: `CHANGELOG.md`：记录本阶段变更。

## Task 1: 设备维度游标失败测试

**Files:**
- Modify: `tests/integration/upload_flow_test.go`

- [x] **Step 1: 写失败测试**

新增测试 `TestChangesCursorIsScopedByDevice`：

- 同一用户注册两个设备。
- 设备 A 创建同步目录并上传一个版本。
- 设备 A 拉取 `changes?device_id={deviceA}&cursor=0`。
- 设备 B 拉取 `changes?device_id={deviceB}&cursor=0`。
- 两次响应都应包含同一个版本 ID，证明设备 A 的游标不会覆盖设备 B。

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run TestChangesCursorIsScopedByDevice -v`

Expected: FAIL，当前接口忽略 `device_id`，但这个测试会进一步检查 `sync_cursors` 表中是否有两条设备游标记录。

## Task 2: schema 与服务实现

**Files:**
- Modify: `internal/store/migrate.go`
- Modify: `internal/store/db_test.go`
- Modify: `internal/service/change_service.go`
- Modify: `internal/httpapi/handlers/change_handler.go`
- Modify: `internal/app/app.go`

- [x] **Step 1: 更新 schema**

`sync_cursors` 增加 `device_id TEXT NOT NULL DEFAULT '__legacy__'`，主键改为 `(user_id, device_id)`。

- [x] **Step 2: 更新 ChangeService**

`ChangeService.List` 签名改为 `List(ctx, userID, deviceID string, cursorValue int64)`。如果 `deviceID` 为空，使用 `__legacy__`；如果不为空，校验设备属于当前用户。

- [x] **Step 3: 更新 handler 和 app 装配**

`ChangeHandler.List` 读取查询参数 `device_id` 并传给 service；`app.New` 创建 `ChangeService` 时注入 `deviceRepo`。

- [x] **Step 4: 运行测试确认通过**

Run: `rtk go test ./tests/integration -run TestChangesCursorIsScopedByDevice -v`

Expected: PASS。

## Task 3: 文档与最终验证

**Files:**
- Modify: `docs/notes/decisions.md`
- Modify: `docs/notes/backend-mvp.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-06-26-device-scoped-cursors.md`

- [x] **Step 1: 更新文档**

记录设备维度游标已实现，以及 `__legacy__` 兼容键。

- [x] **Step 2: 全量验证**

Run: `rtk go test ./...`

Expected: PASS。

Run: `rtk make build`

Expected: PASS。
