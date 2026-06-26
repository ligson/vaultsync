# VaultSync 加密格式规范 V1

## 1. 目标

本规范定义 VaultSync 第一版客户端加密格式。目标是让客户端在上传前完成文件内容、文件名、路径和元数据加密，后端只保存密文与少量同步所需索引，无法解密用户数据。

## 2. 威胁模型

### 2.1 防护目标

- NAS 管理员或后端进程不能读取文件明文。
- 数据库泄露时，攻击者不能直接恢复文件名、路径、目录结构和文件内容。
- 对象存储目录泄露时，攻击者只能看到密文对象和随机化文件名。
- 不同用户之间使用独立密钥材料，不能互相解密。

### 2.2 非目标

- 不防护客户端设备已被完全攻陷的情况。
- 不提供忘记密码后的零知识恢复。
- 不实现多人共享文件夹密钥交换。
- 不隐藏每个用户的大致数据量、版本数量和密文对象大小。

## 3. 算法选择

第一版推荐算法：

- 密码派生：`Argon2id`
- 密钥扩展：`HKDF-SHA256`
- 内容加密：`XChaCha20-Poly1305`
- 哈希/指纹：`SHA-256`，仅用于密文完整性辅助和本地去重判断，不作为明文泄露通道
- 随机数：操作系统 CSPRNG

选择 `XChaCha20-Poly1305` 的原因是 nonce 为 24 字节，随机 nonce 在移动端和桌面端实现更稳妥，降低 nonce 重用风险。

## 4. 密钥层级

### 4.1 用户主密钥

客户端使用用户输入的加密密码派生用户主密钥：

```text
user_master_key = Argon2id(
  password = user_encryption_password,
  salt = user_kdf_salt,
  memory = 64 MiB,
  iterations = 3,
  parallelism = 1,
  output = 32 bytes
)
```

`user_kdf_salt` 可存储在服务器端用户加密配置中，因为 salt 不是秘密。服务器不得保存用户加密密码或派生出的明文密钥。

### 4.2 同步目录密钥

每个同步目录生成独立 `sync_root_key`：

```text
sync_root_key = HKDF-SHA256(
  ikm = user_master_key,
  salt = sync_root_id,
  info = "vaultsync/v1/sync-root"
)
```

`sync_root_id` 为后端已存在的同步目录 ID。该 ID 不是秘密，但可作为派生上下文，保证不同同步目录密钥隔离。

### 4.3 文件版本密钥

每个文件版本生成独立 `version_key`：

```text
version_key = HKDF-SHA256(
  ikm = sync_root_key,
  salt = object_id || version_id,
  info = "vaultsync/v1/file-version"
)
```

同一文件多版本使用不同 `version_id`，因此每个版本有独立密钥。

### 4.4 元数据密钥

文件名、路径、目录信息使用：

```text
metadata_key = HKDF-SHA256(
  ikm = sync_root_key,
  salt = object_id,
  info = "vaultsync/v1/metadata"
)
```

元数据密钥按对象隔离，避免同一目录内所有元数据长期使用完全相同的 AEAD key。

## 5. 密文对象格式

文件内容加密后的二进制格式：

```text
magic        8 bytes   "VSENC001"
alg_id       1 byte    0x01 = XChaCha20-Poly1305
nonce_len    1 byte    固定 24
nonce        24 bytes  随机 nonce
ciphertext   N bytes   AEAD 输出，末尾包含 Poly1305 tag
```

AEAD 附加认证数据 `AAD`：

```text
"vaultsync/v1/content" || user_id || sync_root_id || object_id || version_id
```

客户端上传的是完整密文对象。后端不解析该格式，只把字节作为不透明对象保存。客户端下载后按本格式解析和解密。

## 6. 元数据格式

上传请求中的 `metadata_json` 继续保持 JSON 字符串，但其中只允许保存密文元数据：

```json
{
  "format": "vaultsync-metadata-v1",
  "alg": "XChaCha20-Poly1305",
  "nonce": "base64url...",
  "ciphertext": "base64url...",
  "aad": {
    "sync_root_id": "root-id",
    "object_id": "object-id"
  }
}
```

明文元数据建议结构：

```json
{
  "name": "IMG_0001.JPG",
  "relative_path": "Camera/2026/06",
  "kind": "file",
  "mtime_unix_ms": 1782470400000,
  "client_size": 1048576
}
```

客户端必须先序列化明文元数据，再使用 `metadata_key` 加密。服务器不得要求或保存明文 `name`、`relative_path`。

## 7. 加密文件名字段

当前后端已有 `encrypted_name` 字段。第一版客户端应把它作为短展示索引密文，而不是明文文件名：

```text
encrypted_name = base64url(XChaCha20-Poly1305(metadata_key, nonce, plaintext_name, aad))
```

其中 `plaintext_name` 仅为文件名，不包含路径。完整路径仍放在加密后的 `metadata_json` 中。

## 8. 客户端上传流程

1. 客户端登录并注册设备。
2. 客户端选择同步目录，后端返回 `sync_root_id`。
3. 客户端根据用户加密密码派生 `user_master_key`。
4. 客户端派生 `sync_root_key`、`metadata_key`、`version_key`。
5. 客户端加密文件内容，生成密文对象。
6. 客户端加密文件名和元数据。
7. 客户端创建上传会话，传入 `encrypted_name`、加密后的 `metadata_json`、密文大小。
8. 客户端上传密文分片。
9. 后端校验密文大小、保存对象和版本记录。
10. 客户端确认完成后再执行本地清理策略。

## 9. 客户端下载流程

1. 客户端拉取变更列表。
2. 客户端读取版本中的 `sync_root_id`、`object_id`、`version_id` 和加密元数据。
3. 客户端派生对应密钥。
4. 客户端下载密文对象。
5. 客户端验证 magic、算法 ID、AAD 并解密。
6. 客户端解密元数据，恢复本地路径和文件名。

## 10. 兼容与升级

- `magic = VSENC001` 表示内容格式 V1。
- `metadata_json.format = vaultsync-metadata-v1` 表示元数据格式 V1。
- 后续格式升级必须新增版本号，不得改变 V1 语义。
- 后端继续把密文格式当作不透明内容，避免服务端升级阻塞旧客户端。

## 11. 后端约束

- 后端不得记录明文文件名、明文路径或明文元数据。
- 后端日志不得输出 `metadata_json` 和 `encrypted_name` 的完整内容。
- 后端可保存密文大小、密文哈希、版本 ID、对象 ID、同步目录 ID 和用户 ID。
- 后端 API 错误不得把客户端上传的密文元数据原样回显。

## 12. 待后续设计

- 设备密钥缓存与系统钥匙串集成。
- 多设备首次登录时的密钥输入体验。
- 密钥轮换。
- 零知识恢复短语。
- 共享文件夹密钥封装。
