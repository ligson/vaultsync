# VaultSync

VaultSync 是一个私有文件同步系统的多子项目仓库。

## 目录

- `vaultsync-be/`：Go + SQLite 后端服务
- `vaultsync-app/`：Flutter 客户端
- `vaultsync-fe/`：未来网页管理端
- `docs/`：需求、架构、决策和实现计划

## 后端

后端入口和构建都在 `vaultsync-be/`：

```bash
cd vaultsync-be
VAULTSYNC_DATA_DIR=./data \
VAULTSYNC_DATABASE_PATH=./data/vaultsync.db \
VAULTSYNC_TOKEN_SECRET=change-me \
go run ./cmd/server
```

- 构建：`cd vaultsync-be && make build`
- 测试：`cd vaultsync-be && go test ./...`
- 部署示例：`vaultsync-be/docker/docker-compose.yml`
