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

## 兼容旧数据

旧版本上传的文件可能直接位于：

```text
data/objects/{user_id}/{version_id}.bin
data/objects/{user_id}/encrypted/{version_id}.bin
data/objects/{user_id}/plain/{version_id}.bin
```

这些文件仍通过 SQLite 的 `file_versions.content_path` 精确定位，不需要移动。升级时不得批量迁移、删除或重写旧对象文件。

如果需要把旧普通 `.bin` 对象整理成新的可读目录结构，必须走非破坏流程：先备份 SQLite 和对象目录，再按数据库元数据复制到新路径并校验哈希，确认无误后更新 `content_path`。未经用户确认不得删除旧对象。

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
