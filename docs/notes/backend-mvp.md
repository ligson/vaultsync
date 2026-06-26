# 后端 MVP 记忆

## 当前实现

- 后端使用 Go + SQLite。
- SQLite 驱动使用 `modernc.org/sqlite`。
- 当前以单机 NAS 部署为目标，不考虑多实例或集群。
- 服务器端只保存密文对象与元数据索引。
- 上传流程包含会话创建、分片追加、完成落盘和文件版本记录。
- 下载接口按版本 ID 读取密文对象。
- 变更拉取接口当前用 `sync_events` 统一事件表生成游标，并按用户+设备维度把最新游标持久化到 `sync_cursors`。
- 测试装配已经提供 auth、device、sync root、upload、change、download 的完整集成链路。
- 计划中的 `sync_root_flow_test.go` 已独立成文件，`full_flow_test.go` 用于聚合主流程。
- 同步目录创建必须校验设备属于当前用户，不能信任客户端传入的 `device_id`。
- 上传会话创建必须校验设备、同步目录都属于当前用户，并且同步目录绑定的设备与请求设备一致。
- 分片追加必须在会话 `pending` 状态下进行，且累计接收大小不能超过声明的 `total_size`。
- 上传完成前必须确认 `received_size == total_size`，完成后不允许继续追加分片。
- 下载密文对象按当前用户和版本 ID 查询；其他用户不能通过猜测 `version_id` 下载文件。
- 后端只校验密文字节大小、用户归属和同步索引，不校验明文语义。
- 后端不解析客户端加密格式，密文对象、`encrypted_name` 和 `metadata_json` 都按不透明数据处理。
- 后端日志不得输出完整 `encrypted_name` 或 `metadata_json`，避免泄露加密元数据样本。
- 当前后端已支持同步协议 V1 的服务端最小能力：上传密文版本、拉取变更列表、下载密文对象。
- 当前 `sync_cursors` 按 `(user_id, device_id)` 保存最新游标，未传 `device_id` 的旧调用使用 `__legacy__` 兼容键。
- V1 后端不表达远端删除；客户端本地清理策略不得被解释为删除远端对象。
- 后端只保存 `cleanup_policy` 和 `archive_path`，实际删除或归档本地文件由客户端执行。
- 后端不得根据 `cleanup_policy=delete` 删除远端密文对象。
- 后端支持远端删除墓碑：`DELETE /api/v1/objects/{object_id}` 只追加 `file_tombstones` 和 `sync_events`，不删除历史密文对象。
- `changes` 响应包含 `change_type`，当前取值为 `upsert` 和 `delete`。

## 约定

- 文档尽量使用中文。
- 有意义的变更必须写入 `CHANGELOG.md`。
- 长期有效的决策写入 `docs/notes/`。
- 实现计划写入 `docs/superpowers/plans/`。
