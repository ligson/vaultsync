# VaultSync

私有文件同步系统文档仓库。

## 后端 MVP

- 后端：Go + SQLite
- 部署：单机 NAS
- 存储：服务器只保存密文对象与索引
- 启动示例：
  ```bash
  VAULTSYNC_DATA_DIR=./data \
  VAULTSYNC_DATABASE_PATH=./data/vaultsync.db \
  VAULTSYNC_TOKEN_SECRET=change-me \
  go run ./cmd/server
  ```
- 构建：`make build`
- 测试：`go test ./...`
- 部署示例：`docker/docker-compose.yml`

## 目录说明

- `docs/specs/`：正式需求和架构
- `docs/notes/`：长期记忆、决策和实现约定
- `docs/superpowers/plans/`：实现计划
