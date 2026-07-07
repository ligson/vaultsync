# VaultSync 后端镜像发布规范

## 目标

后端正式部署使用 Docker 镜像仓库模式，不在服务器部署目录保存源码或临时构建上下文。

## 镜像

- 默认镜像仓库：`ligson/vaultsync-be`
- 发布架构：`linux/amd64`
- 推荐 tag：
  - 固定版本：Git 短 hash 或日期加 Git 短 hash。
  - 滚动版本：`latest`。

## 本地发布流程

在 `vaultsync-be/` 目录执行：

```bash
make test
make release-push TAG=$(git rev-parse --short HEAD)
```

`release-push` 会执行：

1. 本地交叉编译 Linux amd64 二进制。
2. 使用 `docker/release.Dockerfile` 打包运行镜像。
3. 推送 `$(IMAGE):$(TAG)` 与 `$(IMAGE):latest`。

默认变量：

```bash
IMAGE=ligson/vaultsync-be
TAG=$(git rev-parse --short HEAD)
```

## 服务器部署目录

服务器部署目录只保留运行所需内容：

- `config.yaml`
- `docker-compose.yml`
- `data/`
- 必要备份目录

不得长期保留：

- 项目源码目录。
- 本地构建上下文目录。
- 明文密钥以外的临时调试产物。

## 服务器更新流程

服务器侧 `docker-compose.yml` 使用远程镜像：

```yaml
services:
  vaultsync-be:
    image: ligson/vaultsync-be:latest
```

更新服务：

```bash
docker-compose pull
docker-compose up -d
```

如果服务器临时无法访问镜像仓库，可以把本地已发布的同名镜像通过 `docker save` 传到服务器后执行 `docker load`，再使用相同的 `docker-compose up -d` 切换容器。
