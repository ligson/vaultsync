# 变更列表分页 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `GET /api/v1/changes` 增加分页能力，让客户端可以按 `limit` 分批拉取变更，并通过 `has_more` 判断是否继续拉取。

**Architecture:** 在现有 `changes` 查询上支持可选 `limit` 参数，服务端使用 `LIMIT limit+1` 多取一条来判断是否还有更多数据。响应新增 `has_more`，`next_cursor` 仍指向本批返回给客户端的最后一条变更；如果本页没有变更，则保持请求传入的 `cursor`。

**Tech Stack:** Go, net/http, database/sql, SQLite

---

## 文件结构

- Modify: `internal/domain/types.go`：新增 `ChangePage` 响应模型。
- Modify: `internal/service/change_service.go`：新增默认分页、最大分页、`LIMIT limit+1` 查询和 `has_more` 计算。
- Modify: `internal/httpapi/handlers/change_handler.go`：解析 `limit`，返回 `invalid_request` 或包含 `has_more` 的 JSON。
- Modify: `tests/integration/upload_flow_test.go`：新增分页集成测试。
- Modify: `docs/specs/2026-06-26-sync-protocol.md`：记录 `limit` 和 `has_more`。
- Modify: `docs/notes/backend-mvp.md`、`docs/notes/decisions.md`、`CHANGELOG.md`：记录本阶段决策和变更。

## Task 1: 分页成功路径测试

**Files:**
- Modify: `tests/integration/upload_flow_test.go`

- [x] **Step 1: 写失败测试**

新增 `TestChangesPaginationReturnsHasMoreAndNextPage`：

- 创建一个已认证、已注册设备、已创建同步目录的测试服务。
- 连续上传 3 个版本。
- 请求 `GET /api/v1/changes?cursor=0&device_id={device_id}&limit=2`。
- 断言返回 2 条 `items`、`has_more=true`、`next_cursor>0`。
- 使用 `next_cursor` 请求下一页。
- 断言第二页返回 1 条 `items`、`has_more=false`。

- [x] **Step 2: 运行测试确认失败**

Run: `rtk go test ./tests/integration -run TestChangesPaginationReturnsHasMoreAndNextPage -v`

Expected: FAIL，当前响应没有 `has_more` 且不会按 `limit` 截断。

## Task 2: service 与 handler 分页实现

**Files:**
- Modify: `internal/domain/types.go`
- Modify: `internal/service/change_service.go`
- Modify: `internal/httpapi/handlers/change_handler.go`

- [x] **Step 1: 新增响应模型**

在 `internal/domain/types.go` 新增：

```go
type ChangePage struct {
	Items      []CursorChange `json:"items"`
	NextCursor int64          `json:"next_cursor"`
	HasMore    bool           `json:"has_more"`
}
```

- [x] **Step 2: 实现 `LIMIT limit+1`**

将 `ChangeService.List` 改为接收 `limit int` 并返回 `domain.ChangePage`。

规则：

- `DefaultChangeLimit = 100`
- `MaxChangeLimit = 500`
- `limit == 0` 使用默认值。
- `limit < 0` 返回错误。
- `limit > MaxChangeLimit` 截断到最大值。
- SQL 使用 `LIMIT ?`，实际传入 `limit + 1`。
- 如果查到数量大于 `limit`，只返回前 `limit` 条，并设置 `has_more=true`。

- [x] **Step 3: handler 解析 `limit`**

`ChangeHandler.List` 解析查询参数：

- 未传 `limit`：传 `0` 给 service。
- 非数字或 `limit <= 0`：返回 `400 invalid_request`。
- 合法数字：传给 service。

- [x] **Step 4: 运行分页测试确认通过**

Run: `rtk go test ./tests/integration -run TestChangesPaginationReturnsHasMoreAndNextPage -v`

Expected: PASS。

## Task 3: limit 校验测试

**Files:**
- Modify: `tests/integration/upload_flow_test.go`

- [x] **Step 1: 写 limit 校验测试**

新增 `TestChangesRejectsInvalidLimit`：

- 请求 `GET /api/v1/changes?cursor=0&limit=0`。
- 断言 HTTP 400。
- 断言 JSON 错误码是 `invalid_request`。

- [x] **Step 2: 运行测试确认当前行为**

Run: `rtk go test ./tests/integration -run TestChangesRejectsInvalidLimit -v`

Actual: PASS，handler 校验已在 Task 2 中实现。

- [x] **Step 3: 补齐 handler 校验**

如果 Task 2 已经实现校验，本步骤只需要确认无需额外改动。

- [x] **Step 4: 运行测试确认通过**

Run: `rtk go test ./tests/integration -run TestChangesRejectsInvalidLimit -v`

Expected: PASS。

## Task 4: 文档与最终验证

**Files:**
- Modify: `docs/specs/2026-06-26-sync-protocol.md`
- Modify: `docs/notes/backend-mvp.md`
- Modify: `docs/notes/decisions.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-06-26-change-pagination.md`

- [x] **Step 1: 更新同步协议**

记录：

- `GET /api/v1/changes?cursor={cursor}&device_id={device_id}&limit={limit}`
- 默认 `limit=100`
- 最大 `limit=500`
- 响应包含 `has_more`
- `has_more=true` 时客户端继续使用 `next_cursor` 拉下一页。

- [x] **Step 2: 更新 notes 和 changelog**

记录后端当前支持分页变更列表，使用 `LIMIT limit+1` 探测是否还有更多数据。

- [x] **Step 3: 全量验证**

Run: `rtk go test ./...`

Expected: PASS。

Run: `rtk make build`

Expected: PASS。
