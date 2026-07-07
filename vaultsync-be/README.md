# VaultSync 后端

Go + SQLite 后端服务。

## 开发

```bash
cp config.example.yaml config.yaml
# 修改 config.yaml 中的 app.security.token_secret
go run ./cmd/server -config config.yaml
```

后端配置统一写在 `config.yaml`。真实配置文件不提交，仓库只提交带中文注释的 `config.example.yaml`。

默认存储规则：

- `app.storage.data_dir` 未填写时默认 `./data`。
- `app.storage.database_path` 未填写时默认 `{app.storage.data_dir}/vaultsync.db`。
- 上传临时分片保存到 `{app.storage.data_dir}/uploads/{user_id}/`。
- 上传完成后的密文对象保存到 `{app.storage.data_dir}/objects/{user_id}/`。

## 常用命令

- 测试：`go test ./...`
- 构建：`make build`
- 部署：进入 `docker/`，复制 `config.example.yaml` 为 `config.yaml` 后运行 `docker compose up -d`

## 镜像发布

后端正式部署使用镜像仓库模式，默认镜像名为 `ligson/vaultsync-be`。

```bash
make release-image TAG=$(git rev-parse --short HEAD)
make release-push TAG=$(git rev-parse --short HEAD)
```

发布镜像使用 `docker/release.Dockerfile`，只打包本地交叉编译出来的 Linux amd64 二进制，不把源码放到 NAS 部署目录。

NAS 侧 `docker-compose.yml` 推荐直接使用远程镜像：

```yaml
services:
  vaultsync-be:
    image: ligson/vaultsync-be:latest
    command: ["-config", "/app/config.yaml"]
    volumes:
      - ./config.yaml:/app/config.yaml:ro
      - ./data:/data
```

NAS 更新服务时执行：

```bash
docker-compose pull
docker-compose up -d
```

## 管理后台

管理后台接口统一使用 `/api/v1/admin/*`。管理员账号仍保存在 `users` 表中，通过 `role=admin` 区分普通用户。

初始化管理员：

1. 在 `config.yaml` 中设置 `app.admin.registration_enabled: true`。
2. 通过管理后台注册管理员账号。
3. 创建完成后建议改为 `false` 并重启后端。

主要接口：

- `POST /api/v1/admin/auth/register`
- `POST /api/v1/admin/auth/login`
- `GET /api/v1/admin/me`
- `GET /api/v1/admin/overview`
- `GET /api/v1/admin/users`
- `GET /api/v1/admin/settings`
- `GET /api/v1/admin/downloads`
