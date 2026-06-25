# VaultSync Go + SQLite 后端 MVP 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个可在单机 NAS 上运行的 VaultSync 后端 MVP，提供用户认证、设备绑定、同步目录管理、密文上传下载、变更游标和基础部署能力。

**Architecture:** 后端使用 Go 标准库 `net/http` 提供 API，使用 `modernc.org/sqlite` 驱动 SQLite 并启用 WAL 模式。元数据放在 SQLite，密文对象按用户和版本落盘到本地存储目录，服务端只把加密内容和加密元数据当作不透明数据处理。

**Tech Stack:** Go 1.24+, net/http, database/sql, modernc.org/sqlite, golang.org/x/crypto/bcrypt, Docker, SQLite WAL

---

## 文件结构

### 新建文件

- `go.mod`：定义模块 `github.com/ligson/vaultsync` 与依赖。
- `cmd/server/main.go`：程序入口，加载配置并启动 HTTP 服务。
- `internal/config/config.go`：环境变量配置加载与默认值。
- `internal/httpapi/router.go`：路由注册与中间件装配。
- `internal/httpapi/middleware/auth.go`：Bearer Token 鉴权中间件。
- `internal/httpapi/handlers/auth_handler.go`：注册与登录接口。
- `internal/httpapi/handlers/device_handler.go`：设备注册接口。
- `internal/httpapi/handlers/sync_root_handler.go`：同步目录增删查接口。
- `internal/httpapi/handlers/upload_handler.go`：上传会话、分片上传、完成上传接口。
- `internal/httpapi/handlers/change_handler.go`：变更拉取接口。
- `internal/httpapi/handlers/download_handler.go`：下载密文对象接口。
- `internal/app/app.go`：应用装配，连接数据库与存储目录。
- `internal/store/db.go`：SQLite 打开、WAL 初始化。
- `internal/store/migrate.go`：建表 SQL 与迁移执行。
- `internal/store/auth_repo.go`：用户与会话数据访问。
- `internal/store/device_repo.go`：设备数据访问。
- `internal/store/sync_root_repo.go`：同步目录数据访问。
- `internal/store/object_repo.go`：文件对象、版本、上传会话、变更游标数据访问。
- `internal/service/auth_service.go`：注册、登录、口令校验、Token 生成。
- `internal/service/device_service.go`：设备注册。
- `internal/service/sync_root_service.go`：同步目录 CRUD。
- `internal/service/upload_service.go`：上传会话、分片写入、完成上传。
- `internal/service/change_service.go`：按游标拉取变更。
- `internal/service/download_service.go`：权限校验与对象读取。
- `internal/domain/types.go`：核心领域类型。
- `internal/token/token.go`：HMAC Token 生成与校验。
- `internal/storage/fs.go`：本地文件系统对象存储。
- `internal/testutil/testapp.go`：测试用应用装配。
- `internal/testutil/http.go`：测试请求辅助函数。
- `cmd/server/main_test.go`：配置加载的入口级测试。
- `migrations/001_init.sql`：初始化表结构。
- `docker/Dockerfile`：后端镜像。
- `docker/docker-compose.yml`：单机 NAS 部署示例。
- `Makefile`：测试、运行、构建命令。
- `tests/integration/auth_flow_test.go`：注册与登录集成测试。
- `tests/integration/device_flow_test.go`：设备绑定集成测试。
- `tests/integration/sync_root_flow_test.go`：同步目录集成测试。
- `tests/integration/upload_flow_test.go`：上传、变更、下载集成测试。
- `docs/notes/backend-mvp.md`：实现期约束与接口约定。

### 修改文件

- `README.md`：补充后端 MVP 启动方式。
- `CHANGELOG.md`：记录实现计划文档与目录规则变更。
- `docs/README.md`：补充计划文档位置。
- `docs/notes/decisions.md`：记录后端驱动与对象存储决策。

## 通用代码约定

这些辅助函数和类型在后续任务中反复使用，执行计划时应在第一次出现它们的任务中一起落地。

### ID 生成

```go
package service

import (
	"crypto/rand"
	"encoding/hex"
)

func newID() string {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(bytes[:])
}
```

### JSON 响应

```go
package handlers

import (
	"encoding/json"
	"net/http"
)

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}
```

### 鉴权上下文

```go
package middleware

import "context"

type contextKey string

const userIDKey contextKey = "user_id"

func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, userIDKey, userID)
}

func MustUserID(ctx context.Context) string {
	userID, ok := ctx.Value(userIDKey).(string)
	if !ok || userID == "" {
		panic("missing authenticated user id")
	}
	return userID
}
```

### 路由依赖

```go
package httpapi

import "github.com/ligson/vaultsync/internal/httpapi/handlers"

type Dependencies struct {
	AuthHandler     *handlers.AuthHandler
	DeviceHandler   *handlers.DeviceHandler
	SyncRootHandler *handlers.SyncRootHandler
	UploadHandler   *handlers.UploadHandler
	ChangeHandler   *handlers.ChangeHandler
	DownloadHandler *handlers.DownloadHandler
}
```

## 任务 1：初始化 Go 工程与运行骨架

**Files:**
- Create: `go.mod`
- Create: `cmd/server/main.go`
- Create: `internal/config/config.go`
- Create: `internal/app/app.go`
- Create: `Makefile`
- Test: `cmd/server/main_test.go`

- [ ] **Step 1: 写失败测试，约束配置缺失时返回错误**

```go
package main

import (
	"testing"

	"github.com/ligson/vaultsync/internal/config"
)

func TestLoadConfigRequiresTokenSecret(t *testing.T) {
	t.Setenv("VAULTSYNC_HTTP_ADDR", ":8080")
	t.Setenv("VAULTSYNC_DATA_DIR", t.TempDir())
	t.Setenv("VAULTSYNC_DATABASE_PATH", t.TempDir()+"/vaultsync.db")
	t.Setenv("VAULTSYNC_TOKEN_SECRET", "")

	_, err := config.Load()
	if err == nil {
		t.Fatal("expected error when token secret is missing")
	}
}
```

- [ ] **Step 2: 运行测试，确认当前失败**

Run: `rtk go test ./cmd/server ./internal/config -v`  
Expected: FAIL，提示 `config.Load` 未定义或未按要求返回错误。

- [ ] **Step 3: 编写最小实现，建立可启动骨架**

```go
module github.com/ligson/vaultsync

go 1.24.0

require modernc.org/sqlite v1.39.0
```

```go
package config

import (
	"errors"
	"os"
)

type Config struct {
	HTTPAddr     string
	DataDir      string
	DatabasePath string
	TokenSecret  string
}

func Load() (Config, error) {
	cfg := Config{
		HTTPAddr:     valueOrDefault("VAULTSYNC_HTTP_ADDR", ":8080"),
		DataDir:      os.Getenv("VAULTSYNC_DATA_DIR"),
		DatabasePath: os.Getenv("VAULTSYNC_DATABASE_PATH"),
		TokenSecret:  os.Getenv("VAULTSYNC_TOKEN_SECRET"),
	}
	if cfg.DataDir == "" {
		return Config{}, errors.New("VAULTSYNC_DATA_DIR is required")
	}
	if cfg.DatabasePath == "" {
		return Config{}, errors.New("VAULTSYNC_DATABASE_PATH is required")
	}
	if cfg.TokenSecret == "" {
		return Config{}, errors.New("VAULTSYNC_TOKEN_SECRET is required")
	}
	return cfg, nil
}

func valueOrDefault(key string, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
```

```go
package app

import "github.com/ligson/vaultsync/internal/config"

type App struct {
	Config config.Config
}

func New(cfg config.Config) (*App, error) {
	return &App{Config: cfg}, nil
}
```

```go
package main

import (
	"log"

	"github.com/ligson/vaultsync/internal/app"
	"github.com/ligson/vaultsync/internal/config"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	_, err = app.New(cfg)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("vaultsync server configured on %s", cfg.HTTPAddr)
}
```

```makefile
test:
	go test ./...

run:
	go run ./cmd/server

build:
	go build ./cmd/server
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `rtk go test ./cmd/server ./internal/config -v`  
Expected: PASS

- [ ] **Step 5: 提交**

```bash
rtk git add go.mod cmd/server/main.go internal/config/config.go internal/app/app.go Makefile
rtk git commit -m "feat: initialize backend service skeleton"
```

## 任务 2：建立 SQLite 与迁移层

**Files:**
- Create: `internal/store/db.go`
- Create: `internal/store/migrate.go`
- Create: `migrations/001_init.sql`
- Test: `internal/store/db_test.go`

- [ ] **Step 1: 写失败测试，约束 SQLite 必须启用 WAL 并创建核心表**

```go
package store

import (
	"database/sql"
	"path/filepath"
	"testing"
)

func TestOpenRunsMigrationsAndEnablesWAL(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "vaultsync.db")
	db, err := Open(dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()

	var mode string
	if err := db.QueryRow("PRAGMA journal_mode;").Scan(&mode); err != nil {
		t.Fatalf("read journal mode: %v", err)
	}
	if mode != "wal" {
		t.Fatalf("expected wal mode, got %s", mode)
	}

	var name string
	if err := db.QueryRow("SELECT name FROM sqlite_master WHERE type='table' AND name='users'").Scan(&name); err != nil {
		t.Fatalf("users table missing: %v", err)
	}
}
```

- [ ] **Step 2: 运行测试，确认当前失败**

Run: `rtk go test ./internal/store -run TestOpenRunsMigrationsAndEnablesWAL -v`  
Expected: FAIL，提示 `Open` 未定义或 `users` 表不存在。

- [ ] **Step 3: 编写最小实现，建立数据库初始化能力**

```go
package store

import (
	"database/sql"
	_ "modernc.org/sqlite"
)

func Open(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec("PRAGMA journal_mode = WAL;"); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.Exec(schemaSQL); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}
```

```go
package store

const schemaSQL = `
CREATE TABLE IF NOT EXISTS users (
	id TEXT PRIMARY KEY,
	email TEXT NOT NULL UNIQUE,
	password_hash TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
	token_id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	device_id TEXT,
	created_at TEXT NOT NULL,
	expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	name TEXT NOT NULL,
	platform TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_roots (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	device_id TEXT NOT NULL,
	encrypted_path TEXT NOT NULL,
	cleanup_policy TEXT NOT NULL,
	archive_path TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS upload_sessions (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	device_id TEXT NOT NULL,
	sync_root_id TEXT NOT NULL,
	object_id TEXT NOT NULL,
	version_id TEXT NOT NULL,
	total_size INTEGER NOT NULL,
	chunk_size INTEGER NOT NULL,
	received_size INTEGER NOT NULL,
	status TEXT NOT NULL,
	metadata_json TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS file_versions (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	sync_root_id TEXT NOT NULL,
	object_id TEXT NOT NULL,
	encrypted_name TEXT NOT NULL,
	content_path TEXT NOT NULL,
	content_hash TEXT NOT NULL,
	size_bytes INTEGER NOT NULL,
	metadata_json TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS sync_cursors (
	user_id TEXT NOT NULL,
	cursor_value INTEGER NOT NULL,
	version_id TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS audit_logs (
	id TEXT PRIMARY KEY,
	user_id TEXT NOT NULL,
	action TEXT NOT NULL,
	details_json TEXT NOT NULL,
	created_at TEXT NOT NULL
);
`
```

```sql
-- migrations/001_init.sql
PRAGMA journal_mode = WAL;
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `rtk go test ./internal/store -run TestOpenRunsMigrationsAndEnablesWAL -v`  
Expected: PASS

- [ ] **Step 5: 提交**

```bash
rtk git add internal/store/db.go internal/store/migrate.go migrations/001_init.sql internal/store/db_test.go
rtk git commit -m "feat: add sqlite bootstrap and schema"
```

## 任务 3：完成注册、登录与 Token 鉴权

**Files:**
- Create: `internal/domain/types.go`
- Create: `internal/token/token.go`
- Create: `internal/store/auth_repo.go`
- Create: `internal/service/auth_service.go`
- Create: `internal/httpapi/router.go`
- Create: `internal/httpapi/middleware/auth.go`
- Create: `internal/httpapi/handlers/auth_handler.go`
- Create: `internal/testutil/testapp.go`
- Create: `internal/testutil/http.go`
- Create: `tests/integration/auth_flow_test.go`
- Test: `tests/integration/auth_flow_test.go`

- [ ] **Step 1: 写失败测试，覆盖注册与登录**

```go
package integration

import (
	"net/http"
	"testing"

	"github.com/ligson/vaultsync/internal/testutil"
)

func TestRegisterAndLogin(t *testing.T) {
	app := testutil.NewTestServer(t)

	registerBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/register", registerBody, "")
	testutil.AssertStatus(t, resp, http.StatusCreated)

	loginBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/auth/login", loginBody, "")
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"token":"`)
}
```

- [ ] **Step 2: 运行测试，确认当前失败**

Run: `rtk go test ./tests/integration -run TestRegisterAndLogin -v`  
Expected: FAIL，提示路由不存在或返回 404。

- [ ] **Step 3: 编写最小实现，打通认证链路**

```go
type User struct {
	ID           string `json:"id"`
	Email        string `json:"email"`
	PasswordHash string `json:"-"`
}

type SessionToken struct {
	Token     string `json:"token"`
	TokenID   string `json:"token_id"`
	UserID    string `json:"user_id"`
	ExpiresAt string `json:"expires_at"`
}
```

```go
func Create(secret []byte, tokenID string, userID string, deviceID string, expiresAt time.Time) (string, error) {
	payload := fmt.Sprintf("%s.%s.%s.%d", tokenID, userID, deviceID, expiresAt.Unix())
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(payload))
	signature := hex.EncodeToString(mac.Sum(nil))
	return base64.RawURLEncoding.EncodeToString([]byte(payload + "." + signature)), nil
}
```

```go
func (s *Service) Register(ctx context.Context, email string, password string) (domain.User, error) {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return domain.User{}, err
	}
	user := domain.User{ID: newID(), Email: email, PasswordHash: string(hash)}
	return s.repo.CreateUser(ctx, user)
}
```

```go
func (h *AuthHandler) Register(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	user, err := h.service.Register(r.Context(), req.Email, req.Password)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"id": user.ID, "email": user.Email})
}
```

```go
func RegisterRoutes(mux *http.ServeMux, deps Dependencies) {
	mux.HandleFunc("POST /api/v1/auth/register", deps.AuthHandler.Register)
	mux.HandleFunc("POST /api/v1/auth/login", deps.AuthHandler.Login)
}
```

```go
package testutil

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ligson/vaultsync/internal/app"
	"github.com/ligson/vaultsync/internal/config"
	"github.com/ligson/vaultsync/internal/httpapi"
)

func NewTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	dataDir := t.TempDir()
	dbPath := filepath.Join(dataDir, "vaultsync.db")
	instance, err := app.New(config.Config{
		HTTPAddr:     "127.0.0.1:0",
		DataDir:      dataDir,
		DatabasePath: dbPath,
		TokenSecret:  "test-secret",
	})
	if err != nil {
		t.Fatalf("new app: %v", err)
	}
	return httptest.NewServer(httpapi.NewRouter(instance.Dependencies()))
}

func JSONRequest(t *testing.T, server *httptest.Server, method string, path string, body string, token string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, server.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	return resp
}

func BinaryRequest(t *testing.T, server *httptest.Server, method string, path string, body []byte, token string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, server.URL+path, bytes.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	return resp
}

func AssertStatus(t *testing.T, resp *http.Response, want int) {
	t.Helper()
	if resp.StatusCode != want {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("expected status %d, got %d: %s", want, resp.StatusCode, string(body))
	}
}

func AssertJSONContains(t *testing.T, resp *http.Response, want string) {
	t.Helper()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read response body: %v", err)
	}
	if !strings.Contains(string(body), want) {
		t.Fatalf("expected response body to contain %q, got %s", want, string(body))
	}
}

func MustReadJSONField(t *testing.T, resp *http.Response, field string) string {
	t.Helper()
	var payload map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		t.Fatalf("decode json: %v", err)
	}
	value, ok := payload[field].(string)
	if !ok || value == "" {
		t.Fatalf("expected json field %q to be a non-empty string", field)
	}
	return value
}

func AssertHeader(t *testing.T, resp *http.Response, key string, want string) {
	t.Helper()
	got := resp.Header.Get(key)
	if got != want {
		t.Fatalf("expected header %s=%q, got %q", key, want, got)
	}
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `rtk go test ./tests/integration -run TestRegisterAndLogin -v`  
Expected: PASS

- [ ] **Step 5: 提交**

```bash
rtk git add internal/domain/types.go internal/token/token.go internal/store/auth_repo.go internal/service/auth_service.go internal/httpapi/router.go internal/httpapi/middleware/auth.go internal/httpapi/handlers/auth_handler.go internal/testutil/testapp.go internal/testutil/http.go tests/integration/auth_flow_test.go
rtk git commit -m "feat: add auth registration and login"
```

## 任务 4：完成设备绑定与同步目录管理

**Files:**
- Create: `internal/store/device_repo.go`
- Create: `internal/store/sync_root_repo.go`
- Create: `internal/service/device_service.go`
- Create: `internal/service/sync_root_service.go`
- Create: `internal/httpapi/handlers/device_handler.go`
- Create: `internal/httpapi/handlers/sync_root_handler.go`
- Create: `tests/integration/device_flow_test.go`
- Create: `tests/integration/sync_root_flow_test.go`
- Test: `tests/integration/device_flow_test.go`
- Test: `tests/integration/sync_root_flow_test.go`

- [ ] **Step 1: 写失败测试，覆盖设备注册与同步目录新增查询**

```go
func TestRegisterDeviceAndManageSyncRoots(t *testing.T) {
	app, token := testutil.NewAuthenticatedServer(t)

	deviceBody := `{"name":"Alice MacBook","platform":"macos"}`
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/devices", deviceBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	deviceID := testutil.MustReadJSONField(t, resp, "id")

	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:path","cleanup_policy":"delete","archive_path":""}`, deviceID)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/sync-roots", rootBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/sync-roots", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, `"cleanup_policy":"delete"`)
}
```

- [ ] **Step 2: 运行测试，确认当前失败**

Run: `rtk go test ./tests/integration -run TestRegisterDeviceAndManageSyncRoots -v`  
Expected: FAIL，提示 `/api/v1/devices` 或 `/api/v1/sync-roots` 不存在。

- [ ] **Step 3: 编写最小实现，建立设备与目录能力**

```go
type Device struct {
	ID        string `json:"id"`
	UserID    string `json:"user_id"`
	Name      string `json:"name"`
	Platform  string `json:"platform"`
	CreatedAt string `json:"created_at"`
}

type SyncRoot struct {
	ID            string `json:"id"`
	UserID        string `json:"user_id"`
	DeviceID      string `json:"device_id"`
	EncryptedPath string `json:"encrypted_path"`
	CleanupPolicy string `json:"cleanup_policy"`
	ArchivePath   string `json:"archive_path"`
	CreatedAt     string `json:"created_at"`
}
```

```go
func (h *DeviceHandler) Create(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	var req struct {
		Name     string `json:"name"`
		Platform string `json:"platform"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	device, err := h.service.Register(r.Context(), userID, req.Name, req.Platform)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusCreated, device)
}
```

```go
func (h *SyncRootHandler) List(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	roots, err := h.service.ListByUser(r.Context(), userID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": roots})
}
```

```go
secured.HandleFunc("POST /api/v1/devices", deps.DeviceHandler.Create)
secured.HandleFunc("GET /api/v1/sync-roots", deps.SyncRootHandler.List)
secured.HandleFunc("POST /api/v1/sync-roots", deps.SyncRootHandler.Create)
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `rtk go test ./tests/integration -run TestRegisterDeviceAndManageSyncRoots -v`  
Expected: PASS

- [ ] **Step 5: 提交**

```bash
rtk git add internal/store/device_repo.go internal/store/sync_root_repo.go internal/service/device_service.go internal/service/sync_root_service.go internal/httpapi/handlers/device_handler.go internal/httpapi/handlers/sync_root_handler.go tests/integration/device_flow_test.go tests/integration/sync_root_flow_test.go
rtk git commit -m "feat: add device and sync root management"
```

## 任务 5：完成密文上传会话与对象落盘

**Files:**
- Create: `internal/storage/fs.go`
- Create: `internal/store/object_repo.go`
- Create: `internal/service/upload_service.go`
- Create: `internal/httpapi/handlers/upload_handler.go`
- Create: `tests/integration/upload_flow_test.go`
- Test: `tests/integration/upload_flow_test.go`

- [ ] **Step 1: 写失败测试，覆盖上传会话、分片上传与完成上传**

```go
func TestUploadCiphertextAndCompleteVersion(t *testing.T) {
	app, token, deviceID, rootID := testutil.NewUploadReadyServer(t)

	createBody := fmt.Sprintf(`{
		"device_id":"%s",
		"sync_root_id":"%s",
		"object_id":"obj-1",
		"version_id":"ver-1",
		"total_size":11,
		"chunk_size":5,
		"encrypted_name":"enc:file.txt",
		"metadata_json":"{\"nonce\":\"abc\"}"
	}`, deviceID, rootID)
	resp := testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions", createBody, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
	sessionID := testutil.MustReadJSONField(t, resp, "id")

	resp = testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("hello"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.BinaryRequest(t, app, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/1", []byte(" world"), token)
	testutil.AssertStatus(t, resp, http.StatusNoContent)
	resp = testutil.JSONRequest(t, app, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	testutil.AssertStatus(t, resp, http.StatusCreated)
}
```

- [ ] **Step 2: 运行测试，确认当前失败**

Run: `rtk go test ./tests/integration -run TestUploadCiphertextAndCompleteVersion -v`  
Expected: FAIL，提示上传相关接口不存在。

- [ ] **Step 3: 编写最小实现，打通上传会话与文件存储**

```go
type UploadSession struct {
	ID           string `json:"id"`
	UserID       string `json:"user_id"`
	DeviceID     string `json:"device_id"`
	SyncRootID   string `json:"sync_root_id"`
	ObjectID     string `json:"object_id"`
	VersionID    string `json:"version_id"`
	TotalSize    int64  `json:"total_size"`
	ChunkSize    int64  `json:"chunk_size"`
	ReceivedSize int64  `json:"received_size"`
	Status       string `json:"status"`
	MetadataJSON string `json:"metadata_json"`
}
```

```go
func (s *FSStorage) AppendChunk(userID string, sessionID string, chunk []byte) error {
	path := filepath.Join(s.rootDir, "uploads", userID, sessionID+".part")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(chunk)
	return err
}
```

```go
func (h *UploadHandler) UploadPart(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	sessionID := r.PathValue("sessionID")
	if err := h.service.AppendChunk(r.Context(), userID, sessionID, r.Body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
```

```go
func (s *Service) Complete(ctx context.Context, userID string, sessionID string) (domain.FileVersion, error) {
	session, err := s.repo.GetUploadSession(ctx, userID, sessionID)
	if err != nil {
		return domain.FileVersion{}, err
	}
	contentPath, hashValue, err := s.storage.FinalizeUpload(userID, sessionID, session.VersionID)
	if err != nil {
		return domain.FileVersion{}, err
	}
	version := domain.FileVersion{
		ID:            session.VersionID,
		UserID:        userID,
		SyncRootID:    session.SyncRootID,
		ObjectID:      session.ObjectID,
		EncryptedName: session.EncryptedName,
		ContentPath:   contentPath,
		ContentHash:   hashValue,
		SizeBytes:     session.TotalSize,
		MetadataJSON:  session.MetadataJSON,
	}
	return s.repo.CompleteUpload(ctx, sessionID, version)
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `rtk go test ./tests/integration -run TestUploadCiphertextAndCompleteVersion -v`  
Expected: PASS

- [ ] **Step 5: 提交**

```bash
rtk git add internal/storage/fs.go internal/store/object_repo.go internal/service/upload_service.go internal/httpapi/handlers/upload_handler.go tests/integration/upload_flow_test.go
rtk git commit -m "feat: add encrypted upload sessions"
```

## 任务 6：完成变更游标与密文下载

**Files:**
- Create: `internal/service/change_service.go`
- Create: `internal/service/download_service.go`
- Create: `internal/httpapi/handlers/change_handler.go`
- Create: `internal/httpapi/handlers/download_handler.go`
- Modify: `tests/integration/upload_flow_test.go`
- Test: `tests/integration/upload_flow_test.go`

- [ ] **Step 1: 写失败测试，覆盖变更拉取与版本下载**

```go
func TestListChangesAndDownloadCiphertext(t *testing.T) {
	app, token, versionID := testutil.NewUploadedVersionServer(t)

	resp := testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/changes?cursor=0", "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertJSONContains(t, resp, versionID)

	resp = testutil.JSONRequest(t, app, http.MethodGet, "/api/v1/objects/"+versionID, "", token)
	testutil.AssertStatus(t, resp, http.StatusOK)
	testutil.AssertHeader(t, resp, "Content-Type", "application/octet-stream")
}
```

- [ ] **Step 2: 运行测试，确认当前失败**

Run: `rtk go test ./tests/integration -run TestListChangesAndDownloadCiphertext -v`  
Expected: FAIL，提示 `/api/v1/changes` 或 `/api/v1/objects/{id}` 不存在。

- [ ] **Step 3: 编写最小实现，打通同步拉取链路**

```go
type CursorChange struct {
	CursorValue int64  `json:"cursor_value"`
	VersionID   string `json:"version_id"`
	ObjectID    string `json:"object_id"`
	SyncRootID  string `json:"sync_root_id"`
	CreatedAt   string `json:"created_at"`
}
```

```go
func (h *ChangeHandler) List(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	cursorValue, _ := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	items, nextCursor, err := h.service.List(r.Context(), userID, cursorValue)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"items":       items,
		"next_cursor": nextCursor,
	})
}
```

```go
func (h *DownloadHandler) Download(w http.ResponseWriter, r *http.Request) {
	userID := middleware.MustUserID(r.Context())
	versionID := r.PathValue("versionID")
	reader, err := h.service.OpenCiphertext(r.Context(), userID, versionID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	defer reader.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	io.Copy(w, reader)
}
```

```go
secured.HandleFunc("GET /api/v1/changes", deps.ChangeHandler.List)
secured.HandleFunc("GET /api/v1/objects/{versionID}", deps.DownloadHandler.Download)
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `rtk go test ./tests/integration -run TestListChangesAndDownloadCiphertext -v`  
Expected: PASS

- [ ] **Step 5: 提交**

```bash
rtk git add internal/service/change_service.go internal/service/download_service.go internal/httpapi/handlers/change_handler.go internal/httpapi/handlers/download_handler.go tests/integration/upload_flow_test.go
rtk git commit -m "feat: add change cursor and download api"
```

## 任务 7：补齐测试装配、部署文件与开发文档

**Files:**
- Modify: `internal/testutil/testapp.go`
- Modify: `internal/testutil/http.go`
- Create: `docker/Dockerfile`
- Create: `docker/docker-compose.yml`
- Create: `docs/notes/backend-mvp.md`
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/notes/decisions.md`
- Test: `tests/integration/auth_flow_test.go`
- Test: `tests/integration/device_flow_test.go`
- Test: `tests/integration/sync_root_flow_test.go`
- Test: `tests/integration/upload_flow_test.go`

- [ ] **Step 1: 写失败测试，要求测试装配可一次性跑完整条后端主流程**

```go
func TestFullBackendMVPFlow(t *testing.T) {
	t.Run("auth", TestRegisterAndLogin)
	t.Run("device_and_sync_root", TestRegisterDeviceAndManageSyncRoots)
	t.Run("upload_and_download", TestListChangesAndDownloadCiphertext)
}
```

- [ ] **Step 2: 运行测试，确认当前失败或存在装配缺口**

Run: `rtk go test ./tests/integration -v`  
Expected: FAIL，提示缺少测试装配、依赖未注入或集成链路不完整。

- [ ] **Step 3: 编写最小实现，扩展测试工具、补齐部署脚本和文档**

```go
package testutil

func NewAuthenticatedServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	server := NewTestServer(t)
	registerBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp := JSONRequest(t, server, http.MethodPost, "/api/v1/auth/register", registerBody, "")
	AssertStatus(t, resp, http.StatusCreated)
	loginBody := `{"email":"alice@example.com","password":"passw0rd!"}`
	resp = JSONRequest(t, server, http.MethodPost, "/api/v1/auth/login", loginBody, "")
	AssertStatus(t, resp, http.StatusOK)
	token := MustReadJSONField(t, resp, "token")
	return server, token
}

func NewUploadReadyServer(t *testing.T) (*httptest.Server, string, string, string) {
	t.Helper()
	server, token := NewAuthenticatedServer(t)
	deviceBody := `{"name":"Alice MacBook","platform":"macos"}`
	resp := JSONRequest(t, server, http.MethodPost, "/api/v1/devices", deviceBody, token)
	AssertStatus(t, resp, http.StatusCreated)
	deviceID := MustReadJSONField(t, resp, "id")
	rootBody := fmt.Sprintf(`{"device_id":"%s","encrypted_path":"base64:path","cleanup_policy":"delete","archive_path":""}`, deviceID)
	resp = JSONRequest(t, server, http.MethodPost, "/api/v1/sync-roots", rootBody, token)
	AssertStatus(t, resp, http.StatusCreated)
	rootID := MustReadJSONField(t, resp, "id")
	return server, token, deviceID, rootID
}

func NewUploadedVersionServer(t *testing.T) (*httptest.Server, string, string) {
	t.Helper()
	server, token, deviceID, rootID := NewUploadReadyServer(t)
	createBody := fmt.Sprintf(`{"device_id":"%s","sync_root_id":"%s","object_id":"obj-1","version_id":"ver-1","total_size":11,"chunk_size":5,"encrypted_name":"enc:file.txt","metadata_json":"{\"nonce\":\"abc\"}"}`, deviceID, rootID)
	resp := JSONRequest(t, server, http.MethodPost, "/api/v1/upload-sessions", createBody, token)
	AssertStatus(t, resp, http.StatusCreated)
	sessionID := MustReadJSONField(t, resp, "id")
	resp = BinaryRequest(t, server, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/0", []byte("hello"), token)
	AssertStatus(t, resp, http.StatusNoContent)
	resp = BinaryRequest(t, server, http.MethodPut, "/api/v1/upload-sessions/"+sessionID+"/parts/1", []byte(" world"), token)
	AssertStatus(t, resp, http.StatusNoContent)
	resp = JSONRequest(t, server, http.MethodPost, "/api/v1/upload-sessions/"+sessionID+"/complete", `{}`, token)
	AssertStatus(t, resp, http.StatusCreated)
	return server, token, "ver-1"
}
```

```dockerfile
FROM golang:1.24 AS build
WORKDIR /src
COPY . .
RUN go build -o /out/vaultsync ./cmd/server

FROM debian:bookworm-slim
WORKDIR /app
COPY --from=build /out/vaultsync /app/vaultsync
ENTRYPOINT ["/app/vaultsync"]
```

```yaml
services:
  vaultsync:
    build:
      context: ..
      dockerfile: docker/Dockerfile
    ports:
      - "8080:8080"
    environment:
      VAULTSYNC_HTTP_ADDR: ":8080"
      VAULTSYNC_DATA_DIR: /data
      VAULTSYNC_DATABASE_PATH: /data/vaultsync.db
      VAULTSYNC_TOKEN_SECRET: change-me
    volumes:
      - ./data:/data
```

```md
# 后端 MVP 说明

- 只处理密文内容与密文元数据
- 不提供明文预览或跨用户共享
- 默认单机部署
- 上传完成后通过 `file_versions` 与 `sync_cursors` 提供同步拉取依据
```

- [ ] **Step 4: 运行完整验证，确认通过**

Run: `rtk go test ./... -v`  
Expected: PASS

Run: `rtk go build ./cmd/server`  
Expected: PASS

- [ ] **Step 5: 提交**

```bash
rtk git add internal/testutil/testapp.go internal/testutil/http.go docker/Dockerfile docker/docker-compose.yml docs/notes/backend-mvp.md README.md CHANGELOG.md docs/notes/decisions.md
rtk git commit -m "chore: finish backend mvp plan coverage"
```

## 自检结果

### 需求覆盖

- 登录与设备绑定：任务 3、任务 4 覆盖。
- 同步目录选择：任务 4 覆盖。
- 密文上传与下载：任务 5、任务 6 覆盖。
- 版本记录：任务 5 覆盖。
- 变更游标：任务 6 覆盖。
- 单机 NAS 部署：任务 7 覆盖。
- 变更留痕与文档沉淀：任务 7 覆盖。

### 占位符检查

- 未使用 `TODO`、`TBD`、`implement later` 等占位符。
- 每个任务都给出了文件路径、示例代码、验证命令和提交命令。

### 命名一致性

- 模块路径统一使用 `github.com/ligson/vaultsync`。
- 核心概念统一使用 `sync root`、`upload session`、`file version`、`cursor`。
- API 路径统一使用 `/api/v1/...`。
