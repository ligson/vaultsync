# VaultSync 后端

Go + SQLite 后端服务。

## 开发

```bash
VAULTSYNC_DATA_DIR=./data \
VAULTSYNC_DATABASE_PATH=./data/vaultsync.db \
VAULTSYNC_TOKEN_SECRET=change-me \
go run ./cmd/server
```

## 常用命令

- 测试：`go test ./...`
- 构建：`make build`
- 部署：`docker/docker-compose.yml`
