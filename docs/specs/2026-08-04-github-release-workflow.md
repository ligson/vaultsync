# GitHub tag 发版工作流

## 目标

VaultSync 使用 `.github/workflows/release.yml` 统一构建并发布 GitHub Release。工作流只接受已经推送到 GitHub 的正式 tag，并始终检出 tag 指向的准确 commit，避免从后续变化的 `main` 构建。

一次成功发版包含三组制品：

- App：Android 签名 APK、Android 签名 AAB、iOS 签名 IPA、macOS x64 和 arm64 签名公证包。
- 前端：包含构建后静态文件及 Docker 配置的 zip。
- 后端：Linux 和 macOS 的 amd64、arm64 二进制 tar.gz。

所有制品发布到同一个 GitHub Release，并附带 `SHA256SUMS.txt`。

## Tag 规则

tag 格式固定为：

```text
v<major>.<minor>.<patch>+<build-number>
```

示例：

```text
v1.0.0+2026080402
```

- `1.0.0` 写入 Flutter 的 `build-name`。
- `2026080402` 写入 Flutter 的 `build-number`，必须为纯数字并且高于已发布安装包的构建号。
- 制品文件名使用完整版本 `1.0.0+2026080402`，方便区分同一语义版本的不同构建。
- 已发布 tag 不允许移动、覆盖或复用；修复后必须使用新的 build number 创建新 tag。

## 发布制品

以 `v1.0.0+2026080402` 为例，GitHub Release 应包含 10 个构建制品和 1 个校验文件：

```text
vaultsync-app-1.0.0+2026080402-android.apk
vaultsync-app-1.0.0+2026080402-android.aab
vaultsync-app-1.0.0+2026080402-ios.ipa
vaultsync-app-1.0.0+2026080402-macos-x64.zip
vaultsync-app-1.0.0+2026080402-macos-arm64.zip
vaultsync-fe-1.0.0+2026080402.zip
vaultsync-be-1.0.0+2026080402-linux-amd64.tar.gz
vaultsync-be-1.0.0+2026080402-linux-arm64.tar.gz
vaultsync-be-1.0.0+2026080402-macos-amd64.tar.gz
vaultsync-be-1.0.0+2026080402-macos-arm64.tar.gz
SHA256SUMS.txt
```

工作流会在发布前校验 10 个构建制品是否全部存在。任何平台构建、签名、验签或公证失败，整个 Release 都不会发布。

## GitHub 签名配置

在仓库 `Settings > Secrets and variables > Actions` 中配置以下内容。签名材料只保存为 GitHub Actions Secrets，不提交到仓库。

### Android Secrets

| 名称 | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | release keystore 文件的 Base64 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 签名 key alias |
| `ANDROID_KEY_PASSWORD` | 签名 key 密码 |

Android 必须使用当前已发布 App 的同一 keystore。更换 keystore 会导致现有安装无法通过覆盖升级保留客户端登录态、目录绑定、上传队列和加密密钥。工作流不提供 debug 签名回退，任何 Secret 缺失都会失败。

### iOS Secrets 和 Variables

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Secret | `IOS_DISTRIBUTION_CERTIFICATE_BASE64` | Apple Distribution `.p12` 的 Base64 |
| Secret | `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD` | `.p12` 密码 |
| Secret | `IOS_PROVISIONING_PROFILE_BASE64` | provisioning profile 的 Base64 |
| Secret | `IOS_PROVISIONING_PROFILE_NAME` | profile 名称，可留空并从文件读取 |
| Secret | `IOS_TEAM_ID` | Apple Developer Team ID |
| Variable | `IOS_EXPORT_METHOD` | 默认 `ad-hoc`，按实际渠道设置 |

当前 iOS bundle ID 为 `com.example.vaultsyncApp`，provisioning profile 必须与它一致。后续如需改成正式 bundle ID，应单独评估应用身份、Keychain 和客户端数据迁移，不能在常规发版时直接替换。

### macOS Secrets

| 名称 | 内容 |
| --- | --- |
| `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64` | Developer ID Application `.p12` 的 Base64 |
| `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD` | `.p12` 密码 |
| `MACOS_SIGNING_IDENTITY` | 完整签名身份，如 `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID` | 用于 notarization 的 Apple ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | Apple ID app 专用密码 |
| `APPLE_TEAM_ID` | Apple Developer Team ID |

macOS x64 和 arm64 分别在对应架构的 GitHub runner 构建，完成 Developer ID 签名、Apple notarization、staple 和 Gatekeeper 检查后才打包。

## 标准发版过程

当用户明确说“发版”时，按以下顺序执行：

1. 检查工作区改动、版本说明和现有数据影响，完成后端测试、前端构建、Flutter analyze/test。
2. 更新 `CHANGELOG.md`，提交全部属于本次发版的代码并推送当前分支。
3. 确认远端 commit 与本地提交一致，创建新的 annotated tag，例如 `git tag -a v1.0.0+2026080402 -m "VaultSync v1.0.0+2026080402"`。
4. 推送该 tag；GitHub Actions 自动从该 tag 构建并发布 Release。
5. 回查所有 job、签名验证、公证结果、11 个 Release assets 和 `SHA256SUMS.txt`。
6. 需要安装 Android 真机时，只使用 `adb install -r <apk>` 并回查 `firstInstallTime`、登录状态和权限，禁止先卸载旧版。

工作流也支持手动运行并输入一个已经存在的 tag，用于网络故障后的原 tag 重跑。手动运行不会创建 tag，也不会改动 tag 指向；若 Release 已存在，只覆盖同名 assets。

## 失败与回滚

- 构建失败：修复代码后创建更高 build number 的新 tag，不移动旧 tag。
- 上传制品失败但 tag 代码没有问题：对原 tag 手动重跑 workflow。
- 签名或公证失败：修正 GitHub Secrets/Variables 后对原 tag 手动重跑；不得降级为 debug 签名或未签名包。
- 已发布版本有问题：保留原 Release 和 tag，回滚代码后以新 build number 再发版。

CI 构建和 GitHub Release 本身不修改 NAS `data/`、SQLite、密文对象、下载目录或客户端本地状态。后续 NAS 部署仍必须先备份并按仓库数据安全规则单独验证。
