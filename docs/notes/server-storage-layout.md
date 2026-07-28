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

从支持“按同步目录选择是否加密”开始，新上传文件按存储方式继续分层：

```text
data/objects/{user_id}/encrypted/{version_id}.bin
data/objects/{user_id}/plain/{version_id}.bin
```

- `encrypted/`：客户端上传前加密，服务器只保存密文。
- `plain/`：客户端不加密，服务器保存原文件内容。

## 兼容旧数据

旧版本上传的文件可能直接位于：

```text
data/objects/{user_id}/{version_id}.bin
```

这些文件仍通过 SQLite 的 `file_versions.content_path` 精确定位，不需要移动。升级时不得批量迁移、删除或重写旧对象文件。

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
