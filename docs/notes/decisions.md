# 当前决策

## 已确定

- 后端：Go。
- 元数据存储：SQLite。
- SQLite 驱动：优先使用纯 Go 的 `modernc.org/sqlite`，降低 NAS 环境对 CGO 的依赖。
- 部署方式：单机 NAS。
- 磁盘文件：只保存密文。
- 密文对象存储：文件系统落盘，SQLite 只保存索引和元数据。
- 密钥管理：由客户端负责，服务器不保存明文密钥。
- 范围：优先做私有同步，如后续确有需要再考虑共享文件夹。
- 变更拉取的 MVP 版本使用 `file_versions` 顺序行号充当游标，并通过 `sync_cursors` 按用户持久化最新游标。
- 上传完成后将 `encrypted_name` 写入版本元数据，便于下载与同步侧识别。
- 下载服务已独立为 `internal/service/download_service.go`。

## 文档习惯

- 文档尽可能使用中文编写；技术名词、命令、代码标识、库名和协议名可保留英文。
- 每次有意义的变更都要更新 `CHANGELOG.md`。
- 长期有效的知识沉淀到 `docs/notes/`。
- 正式产品、需求和架构文档放在 `docs/specs/`。
- 可执行实现计划放在 `docs/superpowers/plans/`。
