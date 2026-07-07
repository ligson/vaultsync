# 后端配置文件规范

## 背景

VaultSync 后端从本版本开始使用 `config.yaml` 作为运行配置入口，不再要求用户通过环境变量配置监听端口、数据目录、数据库路径和 Token 密钥。

## 文件规则

- `vaultsync-be/config.example.yaml`：提交到仓库，作为本地运行示例。
- `vaultsync-be/docker/config.example.yaml`：提交到仓库，作为 Docker 部署示例。
- `config.yaml`：真实运行配置，不提交到仓库。
- `.gitignore` 必须忽略 `vaultsync-be/config.yaml` 和 `vaultsync-be/docker/config.yaml`。

## 配置项

```yaml
app:
  server:
    http_addr: ":8080"

  storage:
    data_dir: "./data"
    database_path: "./data/vaultsync.db"

  security:
    token_secret: "change-me-please"
```

- `app`：VaultSync 应用配置根节点，后续新增配置都归入该节点下的分类。
- `app.server.http_addr`：后端 HTTP 监听地址，未填写时默认 `:8080`。
- `app.storage.data_dir`：服务器文件存储根目录，未填写时默认 `./data`。
- `app.storage.database_path`：SQLite 数据库文件路径，未填写时默认 `{app.storage.data_dir}/vaultsync.db`。
- `app.security.token_secret`：Token 签名密钥，必须显式填写，不能依赖默认值。

## 存储落点

- 上传临时分片：`{app.storage.data_dir}/uploads/{user_id}/{session_id}.part`
- 上传完成的密文对象：`{app.storage.data_dir}/objects/{user_id}/{version_id}.bin`
- SQLite 数据库：`app.storage.database_path`

## 启动方式

本地开发：

```bash
cd vaultsync-be
cp config.example.yaml config.yaml
go run ./cmd/server -config config.yaml
```

Docker 部署：

```bash
cd vaultsync-be/docker
cp config.example.yaml config.yaml
docker compose up -d
```
