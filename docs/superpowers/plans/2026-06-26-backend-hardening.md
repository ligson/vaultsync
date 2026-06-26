# 后端隔离与上传链路硬化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 补强后端 MVP 的用户隔离、上传会话状态校验和上传大小完整性校验。

**Architecture:** 在现有 Go service/repo 分层上增加归属查询方法，让 service 在写入前完成权限和状态判断。集成测试从 HTTP API 入口覆盖跨用户访问和上传边界，保持服务器只处理密文与密文元数据的不透明模型。

**Tech Stack:** Go 1.24+, net/http, database/sql, modernc.org/sqlite, SQLite WAL

---

## 文件结构

- Modify: `internal/store/device_repo.go`：增加设备归属查询。
- Modify: `internal/store/sync_root_repo.go`：增加同步目录归属查询。
- Modify: `internal/service/sync_root_service.go`：创建同步目录前校验设备归属。
- Modify: `internal/service/upload_service.go`：创建、追加、完成上传时校验归属、状态和大小。
- Modify: `internal/app/app.go`：按新构造函数注入依赖。
- Modify: `tests/integration/sync_root_flow_test.go`：补充跨用户设备隔离测试。
- Modify: `tests/integration/upload_flow_test.go`：补充上传会话和下载隔离测试。
- Modify: `docs/notes/backend-mvp.md`：记录硬化后的长期约定。
- Modify: `CHANGELOG.md`：记录本阶段变更。

## Task 1: 同步目录设备归属校验

**Files:**
- Modify: `internal/store/device_repo.go`
- Modify: `internal/service/sync_root_service.go`
- Modify: `internal/app/app.go`
- Test: `tests/integration/sync_root_flow_test.go`

- [x] **Step 1: 写失败测试**

新增测试 `TestSyncRootRejectsForeignDevice`：创建两个用户，用户 B 使用用户 A 的 `device_id` 创建同步目录，应返回 `400`。

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run TestSyncRootRejectsForeignDevice -v`

Expected: FAIL，当前服务会错误返回 `201`。

- [x] **Step 3: 最小实现**

在 `DeviceRepo` 增加 `ExistsForUser`，在 `SyncRootService.Create` 前调用；`internal/app/app.go` 更新构造函数注入。

- [x] **Step 4: 运行测试确认通过**

Run: `rtk go test ./tests/integration -run TestSyncRootRejectsForeignDevice -v`

Expected: PASS。

## Task 2: 上传会话归属校验

**Files:**
- Modify: `internal/store/sync_root_repo.go`
- Modify: `internal/service/upload_service.go`
- Modify: `internal/app/app.go`
- Test: `tests/integration/upload_flow_test.go`

- [x] **Step 1: 写失败测试**

新增测试 `TestUploadSessionRejectsForeignSyncRoot`：用户 B 使用用户 A 的 `device_id` 和 `sync_root_id` 创建上传会话，应返回 `400`。

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run TestUploadSessionRejectsForeignSyncRoot -v`

Expected: FAIL，当前服务会错误返回 `201`。

- [x] **Step 3: 最小实现**

在 `SyncRootRepo` 增加 `GetForUser`；`UploadService.CreateSession` 校验设备归属、同步目录归属，并要求同步目录绑定设备与请求设备一致。

- [x] **Step 4: 运行测试确认通过**

Run: `rtk go test ./tests/integration -run TestUploadSessionRejectsForeignSyncRoot -v`

Expected: PASS。

## Task 3: 上传大小与状态校验

**Files:**
- Modify: `internal/service/upload_service.go`
- Modify: `internal/store/object_repo.go`
- Test: `tests/integration/upload_flow_test.go`

- [x] **Step 1: 写失败测试**

新增测试：

- `TestUploadRejectsChunksBeyondTotalSize`
- `TestCompleteRejectsIncompleteUpload`
- `TestUploadRejectsChunkAfterComplete`

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run 'TestUploadRejectsChunksBeyondTotalSize|TestCompleteRejectsIncompleteUpload|TestUploadRejectsChunkAfterComplete' -v`

Expected: FAIL，当前服务允许超量追加、未传满完成或完成后追加。

- [x] **Step 3: 最小实现**

`AppendChunk` 先读取会话，状态必须为 `pending`，并在写入前检查本次分片不会超过 `total_size`。`Complete` 要求 `received_size == total_size` 且状态为 `pending`。

- [x] **Step 4: 运行测试确认通过**

Run: `rtk go test ./tests/integration -run 'TestUploadRejectsChunksBeyondTotalSize|TestCompleteRejectsIncompleteUpload|TestUploadRejectsChunkAfterComplete' -v`

Expected: PASS。

## Task 4: 下载隔离与文档收尾

**Files:**
- Modify: `tests/integration/upload_flow_test.go`
- Modify: `docs/notes/backend-mvp.md`
- Modify: `CHANGELOG.md`

- [x] **Step 1: 写失败或确认性测试**

新增测试 `TestDownloadRejectsForeignVersion`：用户 B 下载用户 A 的 `version_id` 应返回 `400`。

- [x] **Step 2: 运行测试**

Run: `rtk go test ./tests/integration -run TestDownloadRejectsForeignVersion -v`

Expected: PASS 或 FAIL。如果已通过，保留测试作为回归保护。

- [x] **Step 3: 更新文档**

在 `docs/notes/backend-mvp.md` 记录本阶段硬化约定，在 `CHANGELOG.md` 写入 2026-06-26 变更。

- [x] **Step 4: 最终验证**

Run: `rtk go test ./...`

Expected: PASS。

Run: `rtk make build`

Expected: PASS。
