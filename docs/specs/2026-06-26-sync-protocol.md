# VaultSync 同步协议 V1

## 1. 目标

本规范定义 VaultSync 第一版同步协议。它面向 1-3 人、小规模、多设备私有同步场景，优先保证数据隔离、可恢复、可解释和实现简单。

第一版同步协议采用文件级增量同步：客户端上传完整密文版本，服务端记录版本并提供按游标拉取的变更列表。块级差量、实时推送和共享目录不属于 V1 范围。

## 2. 核心原则

- 服务端只处理密文对象和密文元数据。
- 同一用户多个设备通过变更游标同步状态。
- 同一文件的每次上传生成一个新版本。
- 冲突不自动合并，客户端保留双方版本并生成冲突副本。
- 上传成功且服务端完成校验后，客户端才允许执行本地清理策略。

## 3. 角色与对象

- `user_id`：用户隔离边界。
- `device_id`：客户端设备标识，用于同步目录绑定和上传归属。
- `sync_root_id`：用户选择的同步根目录。
- `object_id`：客户端为同一逻辑文件生成的稳定 ID。
- `version_id`：客户端为每次文件版本生成的唯一 ID。
- `cursor`：服务端变更列表的单调位置。

## 4. 设备初始化流程

1. 客户端登录，获得 Bearer Token。
2. 客户端注册设备，获得 `device_id`。
3. 客户端创建或读取同步目录，获得 `sync_root_id`。
4. 客户端准备本地同步数据库，记录：
   - `device_id`
   - `sync_root_id`
   - 本地路径
   - 本地 `cursor`
   - `object_id` 与本地文件路径映射

## 5. 本地扫描模型

客户端维护本地索引：

```text
sync_root_id
relative_path
object_id
last_local_mtime
last_local_size
last_uploaded_version_id
last_remote_version_id
local_state
```

推荐状态：

- `clean`：本地与远端已知版本一致。
- `local_modified`：本地有待上传变更。
- `remote_modified`：远端有待下载变更。
- `conflict`：本地与远端同时变更。
- `archived`：上传后已移动到本地归档目录。
- `deleted_local`：上传后本地已删除。

## 6. 上传协议

### 6.1 触发条件

客户端发现本地文件新增或修改后，执行：

1. 为新文件生成 `object_id`；已有文件复用原 `object_id`。
2. 为本次上传生成 `version_id`。
3. 按加密格式规范加密内容和元数据。
4. 创建上传会话。
5. 上传密文分片。
6. 完成上传。
7. 服务端返回版本记录后，客户端更新本地索引。
8. 根据同步目录的本地清理策略处理本地文件。

### 6.2 上传会话

客户端创建上传会话时传入：

```json
{
  "device_id": "device-id",
  "sync_root_id": "root-id",
  "object_id": "object-id",
  "version_id": "version-id",
  "total_size": 1048600,
  "chunk_size": 1048576,
  "encrypted_name": "base64url...",
  "metadata_json": "{\"format\":\"vaultsync-metadata-v1\",...}"
}
```

`total_size` 是密文对象大小，不是明文大小。

### 6.3 分片上传

第一版分片上传使用顺序上传：

```text
PUT /api/v1/upload-sessions/{session_id}/parts/{part_index}
```

约定：

- `part_index` 从 `0` 开始。
- 客户端应按顺序上传。
- 服务端当前主要校验累计大小不超过 `total_size`。
- 客户端网络失败后可重新创建上传会话并重新上传完整密文对象。

### 6.4 完成上传

```text
POST /api/v1/upload-sessions/{session_id}/complete
```

服务端只有在 `received_size == total_size` 时生成版本记录。客户端只有收到成功响应后，才可把该版本标记为已上传。

## 7. 变更拉取协议

客户端按本地游标拉取远端变更：

```text
GET /api/v1/changes?cursor={cursor}
```

响应包含：

```json
{
  "items": [
    {
      "id": "version-id",
      "sync_root_id": "root-id",
      "object_id": "object-id",
      "encrypted_name": "base64url...",
      "content_hash": "sha256...",
      "size_bytes": 1048600,
      "metadata_json": "{\"format\":\"vaultsync-metadata-v1\",...}",
      "created_at": "2026-06-26T00:00:00Z"
    }
  ],
  "next_cursor": 42
}
```

V1 游标语义：

- 游标是用户维度的单调位置。
- `cursor=0` 表示从头拉取。
- 客户端成功处理本批所有变更后，保存 `next_cursor`。
- 如果客户端处理中断，继续使用旧游标重拉；处理逻辑必须幂等。

## 8. 下载协议

客户端根据变更项中的版本 ID 下载密文对象：

```text
GET /api/v1/objects/{version_id}
```

下载后客户端必须：

1. 校验密文对象哈希是否与 `content_hash` 一致。
2. 按加密格式规范校验 magic、算法 ID 和 AAD。
3. 解密内容和元数据。
4. 根据冲突策略决定写入本地文件或生成冲突副本。

## 9. 冲突处理

### 9.1 冲突判定

客户端拉取远端变更时，如果本地同一 `object_id` 满足以下条件，则判定冲突：

- 本地状态为 `local_modified`，且远端出现新的 `version_id`。
- 本地记录的 `last_remote_version_id` 与变更项版本不一致。

### 9.2 冲突解决

V1 不自动合并文件内容。客户端应：

1. 保留远端版本为正常文件。
2. 将本地未上传版本保存为冲突副本。
3. 冲突副本命名由客户端在解密后生成，例如：

```text
{原文件名} (conflict {device_name} {yyyyMMdd-HHmmss}).ext
```

4. 冲突副本后续作为新文件上传，使用新的 `object_id`。

## 10. 删除语义

V1 暂不实现远端删除墓碑。上传后本地清理策略中的“删除本地文件”仅表示客户端本地删除，不表示远端删除。

后续如需远端删除，应引入 `change_type = delete` 和墓碑记录，不能复用本地清理策略表达远端删除。

## 11. 本地清理策略触发点

同步目录可配置：

- `keep`：保留本地文件。
- `delete`：上传完成后删除本地文件。
- `archive`：上传完成后移动到本地归档目录。

触发条件：

- 上传会话完成成功。
- 客户端已记录 `last_uploaded_version_id`。
- 客户端本地索引已经持久化。

如果清理失败，客户端不得回滚远端上传，只记录本地待处理任务并提示用户。

## 12. 幂等与重试

- 登录、设备注册、同步目录创建由客户端避免重复创建。
- 上传失败后，V1 客户端优先重新创建上传会话并完整重传。
- 拉取变更可重复执行，客户端用 `version_id` 去重。
- 下载失败可重试同一 `version_id`。
- 本地清理失败可单独重试，不影响远端版本。

## 13. 当前后端支持度

已支持：

- 用户认证与设备注册。
- 同步目录创建与查询。
- 密文上传会话、分片追加、完成上传。
- 用户隔离与上传大小校验。
- 变更列表与密文下载。
- JSON 错误响应。

尚未实现：

- 客户端本地索引。
- 客户端加密与解密。
- 客户端冲突副本生成。
- 远端删除墓碑。
- 块级差量同步。
- 实时推送。

## 14. 后续升级方向

- 为 `changes` 响应增加 `change_type`。
- 将游标从用户维度升级为设备维度，避免多设备游标互相覆盖。
- 支持远端删除墓碑。
- 支持服务端返回分页限制和 `has_more`。
- 支持后台轮询策略和移动端省电策略。
