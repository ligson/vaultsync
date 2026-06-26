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
- API 错误响应统一使用 JSON：`{"error":{"code":"...","message":"..."}}`；客户端应优先依赖稳定的 `error.code`。
- MVP 阶段常见业务校验失败统一使用 `invalid_request`，认证失败使用 `unauthorized`，未知服务端错误使用 `internal_error`。
- 客户端加密格式 V1 推荐 `Argon2id + HKDF-SHA256 + XChaCha20-Poly1305`，内容和元数据分别加密。
- 加密密钥层级采用用户主密钥、同步目录密钥、文件版本密钥、元数据密钥分层派生。
- 服务器不解析密文对象格式，只保存不透明密文字节、加密元数据和同步所需索引。
- 同步协议 V1 采用文件级增量同步，不做块级差量。
- 冲突由客户端生成冲突副本，服务端不自动合并文件内容。
- V1 不实现远端删除墓碑；本地清理策略只影响客户端本地文件，不表示远端删除。
- `sync_cursors` 已升级为用户+设备维度游标，未传 `device_id` 的旧调用使用 `__legacy__` 兼容键。
- 本地清理策略 V1 中 `keep` 是默认策略。
- `delete` 和 `archive` 只在上传完成、本地索引落盘后由客户端执行。
- 本地清理失败不回滚远端上传，应进入客户端本地待处理任务。
- 后端不执行本地清理动作，只保存同步目录的策略配置。
- 远端删除使用 `file_tombstones` 墓碑记录，不删除历史密文对象。
- 变更列表通过 `sync_events` 统一事件表生成游标，`change_type` 使用 `upsert` 或 `delete`。

## 文档习惯

- 文档尽可能使用中文编写；技术名词、命令、代码标识、库名和协议名可保留英文。
- 每次有意义的变更都要更新 `CHANGELOG.md`。
- 长期有效的知识沉淀到 `docs/notes/`。
- 正式产品、需求和架构文档放在 `docs/specs/`。
- 可执行实现计划放在 `docs/superpowers/plans/`。
