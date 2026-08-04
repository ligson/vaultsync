# GitHub tag 发版工作流

## 目标

VaultSync 使用 `.github/workflows/release.yml` 统一构建并发布 GitHub Release。工作流只接受已经推送到 GitHub 的正式 tag，并始终检出 tag 指向的准确 commit，避免从后续变化的 `main` 构建。

一次成功发版包含三组制品：

- App：Android 签名 APK、Android 签名 AAB，以及 iOS、macOS x64、macOS arm64、Windows x64 客户端包。Apple Developer 或 Windows 代码签名凭据完整时自动签名；完全未配置时发布明确标注 `unsigned` 的包。
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

以 `v1.0.0+2026080402` 为例，GitHub Release 应包含 11 个构建制品和 1 个校验文件：

```text
vaultsync-app-1.0.0+2026080402-android.apk
vaultsync-app-1.0.0+2026080402-android.aab
vaultsync-app-1.0.0+2026080402-ios-unsigned.ipa
vaultsync-app-1.0.0+2026080402-macos-x64-unsigned.zip
vaultsync-app-1.0.0+2026080402-macos-arm64-unsigned.zip
vaultsync-app-1.0.0+2026080402-windows-x64-unsigned.zip
vaultsync-fe-1.0.0+2026080402.zip
vaultsync-be-1.0.0+2026080402-linux-amd64.tar.gz
vaultsync-be-1.0.0+2026080402-linux-arm64.tar.gz
vaultsync-be-1.0.0+2026080402-macos-amd64.tar.gz
vaultsync-be-1.0.0+2026080402-macos-arm64.tar.gz
SHA256SUMS.txt
```

工作流会在发布前校验 11 个构建制品是否全部存在。Apple 或 Windows 凭据完整时，对应平台使用不带 `unsigned` 后缀的正式文件名。任何平台构建失败，或已启用的签名、验签、公证失败，整个 Release 都不会发布。

无签名客户端制品的边界：

- iOS `*-unsigned.ipa` 只供后续重签名或开发测试，普通 iPhone 不能直接安装。
- macOS `*-unsigned.zip` 未使用 Developer ID 签名、未经过 Apple 公证，用户首次打开时可能被 Gatekeeper 阻止。
- Windows `*-unsigned.zip` 未使用代码签名，解压后可直接运行完整目录中的 `vaultsync_app.exe`，但 Windows SmartScreen 可能显示安全提示。
- `unsigned` 只描述对应平台的分发签名状态，不影响应用业务功能；工作流不会使用临时证书伪装成正式发布包。

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

### Windows Secrets

| 名称 | 内容 |
| --- | --- |
| `WINDOWS_CODE_SIGNING_CERTIFICATE_BASE64` | Authenticode 代码签名 `.pfx` 文件的 Base64 |
| `WINDOWS_CODE_SIGNING_CERTIFICATE_PASSWORD` | `.pfx` 密码 |

Windows 使用官方 `windows-2022` x64 runner 及 Visual Studio 2022 稳定工具链，构建后将 `vaultsync_app.exe`、Flutter 运行库、插件 DLL 和 `data/` 一起打包。两项 Secret 完全未配置时发布 `*-windows-x64-unsigned.zip`；两项完整时使用 SHA-256 和可信时间戳签名主 EXE，并在打包前执行 `signtool verify`。只配置一项时直接失败，避免静默发布未签名包。

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

iOS 使用官方 `macos-26` arm64 runner，确保 iOS SDK 与当前 Flutter 插件依赖匹配。4 项必填 Secret 完全未配置时，工作流自动执行 `flutter build ios --release --no-codesign` 并发布 `*-ios-unsigned.ipa`。如果只配置了一部分，工作流会直接失败并指出凭据不完整，避免把误配置静默降级为无签名包。

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

macOS 的 6 项 Secret 完全未配置时，工作流仍构建两个架构，但文件名标注 `*-unsigned.zip`，且不执行 Developer ID 签名、公证、staple 或 Gatekeeper 放行检查。如果只配置了一部分，工作流会直接失败。未来补齐全部 Apple 凭据后无需再改工作流，会自动恢复正式签名和公证。

## 标准发版过程

当用户明确说“发版”时，按以下顺序执行：

1. 检查工作区改动、版本说明和现有数据影响，完成后端测试、前端构建、Flutter analyze/test。
2. 更新 `CHANGELOG.md`，提交全部属于本次发版的代码并推送当前分支。
3. 确认远端 commit 与本地提交一致，创建新的 annotated tag，例如 `git tag -a v1.0.0+2026080402 -m "VaultSync v1.0.0+2026080402"`。
4. 推送该 tag；GitHub Actions 自动从该 tag 构建并发布 Release。
5. 回查所有 job、签名验证、公证结果、12 个 Release assets 和 `SHA256SUMS.txt`。
6. 需要安装 Android 真机时，只使用 `adb install -r <apk>` 并回查 `firstInstallTime`、登录状态和权限，禁止先卸载旧版。

工作流也支持手动运行并输入一个已经存在的 tag，用于网络故障后的原 tag 重跑。手动运行不会创建 tag，也不会改动 tag 指向；若 Release 已存在，只覆盖同名 assets。

## 失败与回滚

- 构建失败：修复代码后创建更高 build number 的新 tag，不移动旧 tag。
- 上传制品失败但 tag 代码没有问题：对原 tag 手动重跑 workflow。
- 签名或公证失败：修正 GitHub Secrets/Variables 后对原 tag 手动重跑；不得自动降级为 debug 签名。只有对应平台的 Apple 或 Windows 凭据全部未配置时，才允许走文件名明确标注 `unsigned` 的预定分支。
- 已发布版本有问题：保留原 Release 和 tag，回滚代码后以新 build number 再发版。

CI 构建和 GitHub Release 本身不修改 NAS `data/`、SQLite、密文对象、下载目录或客户端本地状态。后续 NAS 部署仍必须先备份并按仓库数据安全规则单独验证。
