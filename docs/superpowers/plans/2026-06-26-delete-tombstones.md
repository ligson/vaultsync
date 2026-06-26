# 删除墓碑与变更类型 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为后端增加远端删除墓碑能力，并让变更列表明确返回 `change_type`。

**Architecture:** 新增 `file_tombstones` 表记录删除事件，不删除历史密文对象。`GET /api/v1/changes` 将 `file_versions` 映射为 `upsert`，将 `file_tombstones` 映射为 `delete`，按单调游标合并返回。新增 `DELETE /api/v1/objects/{objectID}` 追加删除墓碑。

**Tech Stack:** Go, net/http, database/sql, SQLite

---

## 文件结构

- Modify: `internal/store/migrate.go`：新增 `file_tombstones` 表。
- Modify: `internal/store/db_test.go`：更新 schema 测试。
- Modify: `internal/domain/types.go`：`CursorChange` 增加 `change_type` 和可空版本字段语义。
- Modify: `internal/service/change_service.go`：合并版本变更和删除墓碑。
- Create: `internal/service/delete_service.go`：创建删除墓碑并校验归属。
- Create: `internal/httpapi/handlers/delete_handler.go`：删除对象 API。
- Modify: `internal/httpapi/router.go`：注册 DELETE 路由。
- Modify: `internal/app/app.go`：装配删除服务和 handler。
- Modify: `tests/integration/upload_flow_test.go`：新增删除墓碑集成测试。
- Modify: `docs/notes/decisions.md`、`docs/notes/backend-mvp.md`、`CHANGELOG.md`。

## Task 1: 删除墓碑失败测试

**Files:**
- Modify: `tests/integration/upload_flow_test.go`

- [x] **Step 1: 写失败测试**

新增测试 `TestDeleteObjectCreatesTombstoneChange`：

- 上传一个对象版本。
- 调用 `DELETE /api/v1/objects/{object_id}?sync_root_id={root_id}&device_id={device_id}`。
- 拉取 `GET /api/v1/changes?cursor=0&device_id={device_id}`。
- 响应包含 `"change_type":"delete"` 和目标 `object_id`。

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run TestDeleteObjectCreatesTombstoneChange -v`

Expected: FAIL，当前 DELETE 路由不存在。

## Task 2: schema 与删除服务

**Files:**
- Modify: `internal/store/migrate.go`
- Modify: `internal/store/db_test.go`
- Create: `internal/service/delete_service.go`

- [x] **Step 1: 新增 file_tombstones 表**

字段：`id, user_id, device_id, sync_root_id, object_id, metadata_json, created_at`。

- [x] **Step 2: 实现 DeleteService**

校验设备属于用户、同步目录属于用户且绑定设备一致，然后插入墓碑记录。

## Task 3: API 与 changes 输出

**Files:**
- Modify: `internal/domain/types.go`
- Modify: `internal/service/change_service.go`
- Create: `internal/httpapi/handlers/delete_handler.go`
- Modify: `internal/httpapi/router.go`
- Modify: `internal/app/app.go`

- [x] **Step 1: 注册 DELETE 路由**

`DELETE /api/v1/objects/{objectID}` 接收 `sync_root_id`、`device_id` 查询参数。

- [x] **Step 2: changes 返回 change_type**

版本变更返回 `upsert`，删除墓碑返回 `delete`。

- [x] **Step 3: 运行目标测试确认通过**

Run: `rtk go test ./tests/integration -run TestDeleteObjectCreatesTombstoneChange -v`

Expected: PASS。

## Task 4: 文档与最终验证

**Files:**
- Modify: `docs/notes/decisions.md`
- Modify: `docs/notes/backend-mvp.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-06-26-delete-tombstones.md`

- [x] **Step 1: 更新文档**

记录远端删除使用墓碑，不删除历史密文对象。

- [x] **Step 2: 全量验证**

Run: `rtk go test ./...`

Expected: PASS。

Run: `rtk make build`

Expected: PASS。
