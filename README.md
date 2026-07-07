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
cp config.example.yaml config.yaml
# 修改 config.yaml 中的 app.security.token_secret
go run ./cmd/server -config config.yaml
```

- 构建：`cd vaultsync-be && make build`
- 测试：`cd vaultsync-be && go test ./...`
- 配置示例：`vaultsync-be/config.example.yaml`
- 部署示例：`vaultsync-be/docker/docker-compose.yml`
