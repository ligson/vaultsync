# API 错误响应规范化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将后端 API 错误响应统一为稳定 JSON 结构，便于后续客户端开发。

**Architecture:** 在 `internal/httpapi/handlers` 中新增统一错误响应 helper，handler 内所有 `http.Error` 替换为 `writeError`。认证中间件使用相同 JSON 结构返回 `401`。测试从 HTTP API 入口验证错误体，而不是直接测试 helper。

**Tech Stack:** Go 1.24+, net/http, encoding/json

---

## 文件结构

- Create: `internal/httpapi/handlers/errors.go`：统一 JSON 错误响应。
- Modify: `internal/httpapi/handlers/*.go`：替换 handler 内 `http.Error`。
- Modify: `internal/httpapi/middleware/auth.go`：认证失败返回 JSON。
- Modify: `internal/testutil/http.go`：增加 JSON 错误断言辅助函数。
- Modify: `tests/integration/auth_flow_test.go`：验证认证失败 JSON。
- Modify: `tests/integration/sync_root_flow_test.go`：验证无效 JSON 和业务校验错误 JSON。
- Modify: `tests/integration/upload_flow_test.go`：验证上传错误和下载错误 JSON。
- Modify: `docs/notes/decisions.md`：记录 API 错误格式决策。
- Modify: `CHANGELOG.md`：记录本阶段变更。

## Task 1: 认证失败错误体

**Files:**
- Modify: `internal/httpapi/middleware/auth.go`
- Modify: `internal/testutil/http.go`
- Test: `tests/integration/auth_flow_test.go`

- [x] **Step 1: 写失败测试**

新增测试 `TestProtectedRoutesReturnJSONUnauthorized`，未带 Token 请求 `/api/v1/devices`，期望 `401` 且响应体包含 `"code":"unauthorized"`。

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run TestProtectedRoutesReturnJSONUnauthorized -v`

Expected: FAIL，当前响应体不是统一 JSON。

- [x] **Step 3: 最小实现**

认证中间件在失败时返回：

```json
{"error":{"code":"unauthorized","message":"missing bearer token"}}
```

- [x] **Step 4: 运行测试确认通过**

Run: `rtk go test ./tests/integration -run TestProtectedRoutesReturnJSONUnauthorized -v`

Expected: PASS。

## Task 2: Handler 错误 helper 与无效请求

**Files:**
- Create: `internal/httpapi/handlers/errors.go`
- Modify: `internal/httpapi/handlers/auth_handler.go`
- Modify: `internal/httpapi/handlers/sync_root_handler.go`
- Test: `tests/integration/sync_root_flow_test.go`

- [x] **Step 1: 写失败测试**

新增测试 `TestSyncRootInvalidJSONReturnsJSONError`，发送非法 JSON 到 `/api/v1/sync-roots`，期望 `400` 且包含 `"code":"invalid_request"`。

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run TestSyncRootInvalidJSONReturnsJSONError -v`

Expected: FAIL，当前响应体不是统一 JSON。

- [x] **Step 3: 最小实现**

新增 `writeError` helper，并替换 auth/sync root handler 内错误返回。

- [x] **Step 4: 运行测试确认通过**

Run: `rtk go test ./tests/integration -run TestSyncRootInvalidJSONReturnsJSONError -v`

Expected: PASS。

## Task 3: 上传与下载错误响应

**Files:**
- Modify: `internal/httpapi/handlers/device_handler.go`
- Modify: `internal/httpapi/handlers/upload_handler.go`
- Modify: `internal/httpapi/handlers/download_handler.go`
- Modify: `internal/httpapi/handlers/change_handler.go`
- Test: `tests/integration/upload_flow_test.go`

- [x] **Step 1: 写失败测试**

新增或扩展测试，验证：

- 上传超出 `total_size` 返回 `"code":"invalid_request"`。
- 下载其他用户版本返回 `"code":"invalid_request"`。

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run 'TestUploadRejectsChunksBeyondTotalSize|TestDownloadRejectsForeignVersion' -v`

Expected: FAIL，状态码正确但响应体不是统一 JSON。

- [x] **Step 3: 最小实现**

替换剩余 handler 内 `http.Error` 为 `writeError`。

- [x] **Step 4: 运行测试确认通过**

Run: `rtk go test ./tests/integration -run 'TestUploadRejectsChunksBeyondTotalSize|TestDownloadRejectsForeignVersion' -v`

Expected: PASS。

## Task 4: 文档与最终验证

**Files:**
- Modify: `docs/notes/decisions.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-06-26-api-error-contract.md`

- [x] **Step 1: 更新文档**

记录错误响应 JSON 决策和本阶段变更。

- [x] **Step 2: 全量验证**

Run: `rtk go test ./...`

Expected: PASS。

Run: `rtk make build`

Expected: PASS。
