# VaultSync 统一 JSON 响应 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 VaultSync 后端所有对外 JSON 接口统一封装为 `success/message/httpCode/data` 结构，并让现有 handler 与测试一起对齐。

**Architecture:** 引入一个通用的 JSON envelope 响应层，所有成功接口返回 `success=true`、`httpCode=实际 HTTP 状态码`、`data=业务主体`；所有错误接口同样返回该 envelope，但 `success=false`，`data` 为空对象。这样前端只需要认一种响应结构，避免每个 handler 手写不同格式。

**Tech Stack:** Go, net/http, encoding/json, database/sql, SQLite

---

## 文件结构

- Modify: `vaultsync-be/internal/httpapi/handlers/errors.go`：统一响应封装与错误响应。
- Create: `vaultsync-be/internal/httpapi/response/response.go`：统一 JSON envelope 写入。
- Modify: `vaultsync-be/internal/httpapi/handlers/auth_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/device_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/sync_root_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/upload_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/change_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/delete_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/download_handler.go`
- Modify: `vaultsync-be/internal/httpapi/middleware/auth.go`
- Modify: `vaultsync-be/internal/testutil/http.go`
- Modify: `vaultsync-be/internal/testutil/testapp.go`
- Modify: `vaultsync-be/internal/testutil/upload.go`
- Modify: `vaultsync-be/tests/integration/auth_flow_test.go`
- Modify: `vaultsync-be/tests/integration/device_flow_test.go`
- Modify: `vaultsync-be/tests/integration/sync_root_flow_test.go`
- Modify: `vaultsync-be/tests/integration/upload_flow_test.go`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `CHANGELOG.md`

## Task 1: 统一响应结构测试

**Files:**
- Modify: `vaultsync-be/internal/testutil/http.go`
- Modify: `vaultsync-be/tests/integration/auth_flow_test.go`

- [ ] **Step 1: 写失败测试**

新增一个辅助断言，要求接口响应必须包含统一 envelope：

```go
func AssertJSONEnvelope(t *testing.T, resp *http.Response, wantSuccess bool, wantCode int) {
	t.Helper()
	var payload struct {
		Success  bool            `json:"success"`
		Message  string          `json:"message"`
		HTTPCode int             `json:"httpCode"`
		Data     json.RawMessage `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("decode json envelope: %v", err)
	}
	if payload.Success != wantSuccess {
		t.Fatalf("expected success=%v, got %v", wantSuccess, payload.Success)
	}
	if payload.HTTPCode != wantCode {
		t.Fatalf("expected httpCode=%d, got %d", wantCode, payload.HTTPCode)
	}
}
```

在 `TestAuthFlow` 中先断言 `POST /api/v1/auth/register` 的响应不是旧的裸对象。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd vaultsync-be && go test ./tests/integration -run TestAuthFlow -v`

Expected: FAIL，当前响应没有统一 envelope。

## Task 2: 通用响应封装

**Files:**
- Modify: `vaultsync-be/internal/httpapi/handlers/errors.go`
- Modify: `vaultsync-be/internal/httpapi/middleware/auth.go`

- [ ] **Step 1: 写最小实现**

新增统一 envelope：

```go
type Envelope struct {
	Success  bool        `json:"success"`
	Message  string      `json:"message"`
	HTTPCode int         `json:"httpCode"`
	Data     any         `json:"data"`
}

func writeJSON(w http.ResponseWriter, status int, message string, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data == nil {
		data = map[string]any{}
	}
	_ = json.NewEncoder(w).Encode(Envelope{
		Success:  status >= 200 && status < 300,
		Message:  message,
		HTTPCode: status,
		Data:     data,
	})
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, message, map[string]string{
		"code": code,
	})
}
```

`middleware/auth.go` 里 401 也要改成同一 envelope。

- [ ] **Step 2: 运行测试确认通过**

Run: `cd vaultsync-be && go test ./tests/integration -run TestAuthFlow -v`

Expected: PASS。

## Task 3: 更新所有 handler

**Files:**
- Modify: `vaultsync-be/internal/httpapi/handlers/auth_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/device_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/sync_root_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/upload_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/change_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/delete_handler.go`
- Modify: `vaultsync-be/internal/httpapi/handlers/download_handler.go`

- [ ] **Step 1: 更新成功返回**

所有 JSON 成功返回统一改成：

```go
writeJSON(w, http.StatusCreated, "", device)
writeJSON(w, http.StatusOK, "", map[string]any{"items": roots})
```

下载接口仍返回二进制，不走 envelope。

- [ ] **Step 2: 更新错误返回**

所有 handler 仍使用 `writeError`，但返回内容必须是 envelope 结构。

- [ ] **Step 3: 运行测试确认通过**

Run: `cd vaultsync-be && go test ./...`

Expected: PASS。

## Task 4: 更新测试辅助与文档

**Files:**
- Modify: `vaultsync-be/internal/testutil/http.go`
- Modify: `vaultsync-be/internal/testutil/testapp.go`
- Modify: `vaultsync-be/internal/testutil/upload.go`
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: 更新测试读取逻辑**

`MustReadJSONField` 需要从 `data` 内读取字段；`AssertJSONErrorCode` 需要读取 `data.code`。

- [ ] **Step 2: 更新仓库规则**

在 `AGENTS.md` 里新增统一 JSON envelope 规则，明确：

```json
{
  "success": true,
  "message": "",
  "httpCode": 200,
  "data": {}
}
```

- [ ] **Step 3: 更新变更记录**

在 `CHANGELOG.md` 记录后端 JSON 响应统一封装。

## Task 5: 最终验证

**Files:**
- Modify: `docs/superpowers/plans/2026-06-27-unified-json-response.md`

- [ ] **Step 1: 全量验证**

Run: `cd vaultsync-be && go test ./...`

Expected: PASS。

- [ ] **Step 2: 构建验证**

Run: `cd vaultsync-be && make build`

Expected: PASS。
