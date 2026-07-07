# VaultSync 前端

`vaultsync-fe` 是前端源码目录，不是服务器部署目录。

## 目录

```text
apps/
  portal/     官网首页、下载页、产品介绍
  admin/      管理后台，Vue 3 + Vite + TypeScript + Ant Design Vue
packages/
  api-client/ 共享 API 请求封装
  ui-theme/   共享品牌和主题常量
docker/
  nginx.conf  前端容器内 nginx 配置
```

## 开发

```bash
npm install
npm run dev:portal
npm run dev:admin
```

默认端口：

- 官网：`http://127.0.0.1:5173`
- 管理后台：`http://127.0.0.1:5174/admin/`

## 构建

```bash
npm run build
```

构建输出：

- `dist/portal`
- `dist/admin`

## 容器

前端镜像会同时提供：

- `/` 官网首页
- `/admin/` 管理后台
- `/downloads/` 最新客户端安装包目录

服务器部署目录只保留 `docker-compose.yml`、配置、数据和下载文件，不保存前端源码。
