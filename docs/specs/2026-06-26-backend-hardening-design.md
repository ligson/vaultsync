# 后端隔离与上传链路硬化设计

## 目标

本阶段补强 Go + SQLite 后端 MVP 的安全边界，重点保证用户只能操作自己的设备、同步目录、上传会话和文件版本，并让上传链路在大小、状态和完整性上可被服务器端明确校验。

## 范围

- 同步目录创建时校验 `device_id` 必须属于当前登录用户。
- 上传会话创建时校验 `device_id` 和 `sync_root_id` 必须属于当前登录用户，且同步目录与设备归属一致。
- 分片追加前校验上传会话属于当前用户、状态仍为 `pending`，并拒绝超过 `total_size` 的数据。
- 上传完成前校验已接收字节数等于 `total_size`，否则拒绝完成。
- 下载继续按当前用户和 `version_id` 查询密文对象，补充跨用户访问测试。
- 错误语义先保持简单：鉴权失败由中间件返回 `401`；业务校验失败返回 `400`；不存在或无权限的对象统一按业务错误处理，避免暴露其他用户资源是否存在。

## 非范围

- 不实现真正的客户端加密协议，服务器仍把内容和元数据视为不透明密文。
- 不实现共享文件夹和跨用户授权。
- 不实现多实例、集群锁、分布式上传。
- 不实现客户端本地清理策略。

## 设计

### 权限归属校验

新增仓储查询方法：

- `DeviceRepo.ExistsForUser(ctx, userID, deviceID)`：判断设备是否属于用户。
- `SyncRootRepo.GetForUser(ctx, userID, rootID)`：读取当前用户可见的同步目录。

`SyncRootService` 注入 `DeviceRepo`，创建同步目录前先确认设备归属。`UploadService` 注入 `DeviceRepo` 和 `SyncRootRepo`，创建上传会话前确认设备与同步目录均属于当前用户，并要求 `sync_roots.device_id` 与请求 `device_id` 一致。

### 上传状态与大小校验

`AppendChunk` 在写入临时文件前先读取上传会话：

1. 会话不存在或不属于当前用户时返回错误。
2. `status != pending` 时拒绝继续追加。
3. 读取分片内容到内存后检查 `received_size + len(chunk) <= total_size`，超过则拒绝，不写入磁盘。

当前系统目标为 1-3 人小规模私有同步，MVP 阶段可接受单个 HTTP 分片在内存中完成大小校验。后续如果支持大分片或流式限速，再把该逻辑替换为限长 reader。

`Complete` 在落盘前读取会话并检查：

- 会话状态必须为 `pending`。
- `received_size == total_size`。

只有完整上传才调用 `FinalizeUpload`，生成 `file_versions` 并把会话状态改为 `completed`。

### 测试策略

新增集成测试覆盖跨用户访问和上传边界：

- 用户 B 不能用用户 A 的设备创建同步目录。
- 用户 B 不能用用户 A 的同步目录创建上传会话。
- 分片总大小超过 `total_size` 时被拒绝。
- 未传满时不能完成上传。
- 上传完成后不能继续追加分片。
- 用户 B 不能下载用户 A 的文件版本。

所有测试先以失败测试落地，再做最小实现通过。

## 验收标准

- `rtk go test ./...` 通过。
- `rtk make build` 通过。
- `CHANGELOG.md` 记录本阶段变更。
- `docs/notes/` 记录长期有效的后端硬化约定。
