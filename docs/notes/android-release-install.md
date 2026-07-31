# Android 发布包安装约定

## 目标

在真机验证 VaultSync release APK 时，默认保留已有登录态、同步目录绑定、上传队列、相册备份记录、运行权限和加密密钥。

## 安装方式

先构建带递增 `versionCode` 的 release APK：

```bash
flutter build apk --release --build-name=1.0.0 --build-number=<versionCode>
```

再使用 Android SDK 的 `adb install -r` 覆盖升级：

```bash
adb -s <deviceId> install -r build/app/outputs/flutter-apk/app-release.apk
```

`-r` 表示保留应用数据重新安装。不要使用 `flutter install --use-application-binary`，当前 Flutter 工具链会先卸载旧版，导致本地应用数据和运行权限被重置。

## 安装后回查

```bash
adb -s <deviceId> shell dumpsys package com.example.vaultsync_app
```

重点确认：

- `versionCode` 是本次构建版本。
- `firstInstallTime` 没有变成本次安装时间。
- App 打开后仍保留登录态和同步目录。
- 相册、视频和所有文件访问权限没有被意外重置。

如果 `firstInstallTime` 发生变化，应立即按全新安装处理并如实告知：服务端账号、同步目录和已上传文件通常仍在，但客户端上传队列、相册扫描记录、本地映射和本地密钥可能无法完整恢复。
