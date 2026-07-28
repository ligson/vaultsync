# 服务端存储布局说明

## 目录映射

NAS 部署时，Docker Compose 将部署目录下的 `data/` 挂载到后端容器内的 `/data`。

- NAS 实际路径：`/var/services/homes/ligson/wk/docker-services/vaultsync/data`
- 后端容器内路径：`/data`
- SQLite 数据库：`/data/vaultsync.db`

## 用户同步文件

同步文件按用户 ID 隔离存储：

```text
data/objects/{user_id}/
```

从支持“按同步目录选择是否加密”开始，新上传文件按存储方式继续分层。

加密目录只保存密文对象，服务端不暴露真实文件名和目录结构：

```text
data/objects/{user_id}/encrypted/{device_id}/{sync_root_id}/{version_id}.bin
```

普通目录保存明文，并提供一个贴近用户本地目录的 current 镜像：

```text
data/objects/{user_id}/plain/{device_id}/{sync_root_id}/{原始相对路径}
```

例如用户同步 `Download/docs/a.pdf`，服务端会看到类似：

```text
data/objects/{user_id}/plain/{device_id}/{sync_root_id}/docs/a.pdf
```

为了保留版本历史，同一份普通文件的不可变历史版本放在隐藏目录：

```text
data/objects/{user_id}/plain/{device_id}/{sync_root_id}/.vaultsync_versions/{object_id}/{version_id}/{原文件名}
```

- `encrypted/`：客户端上传前加密，服务器只保存密文，不提供明文目录镜像。
- `plain/`：客户端不加密，服务器保存原文件内容；根目录下直接可按原相对路径查看最新文件。
- `plain/.../.vaultsync_versions/`：普通文件历史版本，数据库 `file_versions.content_path` 指向这里，禁止手动删除。

## 兼容与迁移旧数据

旧版本上传的文件可能直接位于：

```text
data/objects/{user_id}/{version_id}.bin
data/objects/{user_id}/encrypted/{version_id}.bin
data/objects/{user_id}/plain/{version_id}.bin
```

这些文件通过 SQLite 的 `file_versions.content_path` 精确定位。后端读取文件时继续兼容旧路径，因此升级后不会强制迁移、删除或重写既有对象文件。

如果需要把旧对象整理成新目录结构，必须使用维护工具：

```bash
go run ./cmd/storage-layout-migrate \
  -mode dry-run \
  -data-dir /var/services/homes/ligson/wk/docker-services/vaultsync/data \
  -stored-data-dir /data \
  -db /var/services/homes/ligson/wk/docker-services/vaultsync/data/vaultsync.db
```

推荐执行顺序：

1. `dry-run`：只读取数据库和对象文件，输出计划，不修改数据。
2. `apply`：自动用 SQLite `VACUUM INTO` 生成数据库备份，然后复制对象到新路径、校验 `SHA-256` 和大小、更新 `file_versions.content_path`，并生成 JSONL 迁移报告。
3. `cleanup`：读取 `apply` 阶段的迁移报告，只删除已经不再被数据库引用、且新文件校验通过的旧 `.bin` 文件。

迁移规则：

- 仍存在同步目录记录的普通文件：迁移到 `plain/{device_id}/{sync_root_id}/.vaultsync_versions/...`，并为最新版本生成 `plain/{device_id}/{sync_root_id}/{原始相对路径}` 镜像。
- 仍存在同步目录记录的加密文件：迁移到 `encrypted/{device_id}/{sync_root_id}/{version_id}.bin`。
- 缺失同步目录记录、无法判断设备的旧加密历史：迁移到 `encrypted/__legacy_device__/{sync_root_id}/{version_id}.bin`，继续保持数据库可追溯，不尝试还原明文目录。
- 旧文件只有在数据库不再引用旧 `content_path`，且新文件完整校验通过后才允许删除。

## 查看建议

查看文件存储占用：

```bash
du -sh data data/*
du -sh data/objects/*
```

查看数据库记录：

```bash
sqlite3 data/vaultsync.db \
'select substr(user_id,1,8), substr(sync_root_id,1,8), content_path, size_bytes, created_at from file_versions order by rowid desc limit 20;'
```

不要手动删除 `data/objects/`、`data/uploads/` 或 `data/vaultsync.db`。如需清理，应通过 VaultSync 后端接口或管理后台完成，避免数据库记录和文件对象不一致。
