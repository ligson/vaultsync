# VaultSync Flutter 客户端 MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建一个单代码库的 Flutter 客户端 MVP，先跑通登录、设备绑定、同步目录查看、变更拉取、密文下载和本地落地这条跨平台主链路。

**Architecture:** 客户端采用 Flutter 单工程同时支持移动端和桌面端。UI 层只负责登录、设备和同步目录选择、变更列表查看与下载触发；网络与同步逻辑放在独立 service 层；本地持久化只保存最小同步状态和下载缓存，避免把业务逻辑散落在页面里。

**Tech Stack:** Flutter, Dart, `http`, `flutter_riverpod`, `path_provider`, `shared_preferences`, `crypto`

---

## 文件结构

- Create: `vaultsync-app/pubspec.yaml`
- Create: `vaultsync-app/lib/main.dart`
- Create: `vaultsync-app/lib/app.dart`
- Create: `vaultsync-app/lib/core/config/app_config.dart`
- Create: `vaultsync-app/lib/core/network/api_client.dart`
- Create: `vaultsync-app/lib/core/storage/app_storage.dart`
- Create: `vaultsync-app/lib/features/auth/login_screen.dart`
- Create: `vaultsync-app/lib/features/sync/sync_home_screen.dart`
- Create: `vaultsync-app/lib/features/sync/sync_service.dart`
- Create: `vaultsync-app/lib/features/sync/sync_models.dart`
- Create: `vaultsync-app/lib/features/download/download_service.dart`
- Create: `vaultsync-app/lib/features/download/download_models.dart`
- Create: `vaultsync-app/test/app_config_test.dart`
- Create: `vaultsync-app/README.md`
- Modify: `vaultsync-app/README.md`：补充开发说明。
- Modify: `CHANGELOG.md`
- Modify: `docs/specs/2026-06-25-vaultsync-design.md`
- Modify: `docs/specs/2026-06-26-sync-protocol.md`
- Modify: `docs/specs/2026-06-26-encryption-format.md`
- Modify: `docs/specs/2026-06-26-local-cleanup-policy.md`
- Modify: `docs/notes/backend-mvp.md`
- Modify: `docs/notes/decisions.md`

## Task 1: Flutter 工程骨架

**Files:**
- Create: `vaultsync-app/pubspec.yaml`
- Create: `vaultsync-app/lib/main.dart`
- Create: `vaultsync-app/lib/app.dart`
- Create: `vaultsync-app/test/app_config_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/config/app_config.dart';

void main() {
  test('AppConfig uses default API base url when env is empty', () {
    final config = AppConfig.fromEnvironment(const {});
    expect(config.apiBaseUrl.toString(), 'http://127.0.0.1:8080');
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd vaultsync-app && flutter test`

Expected: FAIL，`AppConfig` 尚未实现。

- [ ] **Step 3: 写最小实现**

```dart
class AppConfig {
  final Uri apiBaseUrl;
  const AppConfig({required this.apiBaseUrl});

  factory AppConfig.fromEnvironment(Map<String, String> env) {
    final value = env['VAULTSYNC_API_BASE_URL'];
    return AppConfig(
      apiBaseUrl: Uri.parse(value == null || value.isEmpty ? 'http://127.0.0.1:8080' : value),
    );
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd vaultsync-app && flutter test`

Expected: PASS。

## Task 2: HTTP 客户端与登录接口

**Files:**
- Create: `vaultsync-app/lib/core/network/api_client.dart`
- Create: `vaultsync-app/lib/features/auth/login_screen.dart`
- Create: `vaultsync-app/lib/features/auth/auth_service.dart`
- Create: `vaultsync-app/lib/features/auth/auth_models.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/core/network/api_client.dart';

void main() {
  test('ApiClient builds register request path', () {
    final client = ApiClient(baseUrl: Uri.parse('http://127.0.0.1:8080'));
    expect(client.registerPath().toString(), 'http://127.0.0.1:8080/api/v1/auth/register');
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd vaultsync-app && flutter test`

Expected: FAIL，`ApiClient` 尚未实现。

- [ ] **Step 3: 写最小实现**

```dart
class ApiClient {
  final Uri baseUrl;
  const ApiClient({required this.baseUrl});

  Uri registerPath() => baseUrl.resolve('/api/v1/auth/register');
  Uri loginPath() => baseUrl.resolve('/api/v1/auth/login');
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd vaultsync-app && flutter test`

Expected: PASS。

## Task 3: 同步状态与变更拉取

**Files:**
- Create: `vaultsync-app/lib/features/sync/sync_models.dart`
- Create: `vaultsync-app/lib/features/sync/sync_service.dart`
- Create: `vaultsync-app/lib/features/sync/sync_home_screen.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/sync/sync_models.dart';

void main() {
  test('SyncChangePage parses has_more', () {
    final page = SyncChangePage.fromJson({
      'items': [],
      'next_cursor': 42,
      'has_more': true,
    });
    expect(page.nextCursor, 42);
    expect(page.hasMore, true);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd vaultsync-app && flutter test`

Expected: FAIL，`SyncChangePage` 尚未实现。

- [ ] **Step 3: 写最小实现**

```dart
class SyncChangePage {
  final List<Map<String, dynamic>> items;
  final int nextCursor;
  final bool hasMore;

  const SyncChangePage({required this.items, required this.nextCursor, required this.hasMore});

  factory SyncChangePage.fromJson(Map<String, dynamic> json) => SyncChangePage(
    items: List<Map<String, dynamic>>.from(json['items'] as List),
    nextCursor: json['next_cursor'] as int,
    hasMore: json['has_more'] as bool,
  );
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd vaultsync-app && flutter test`

Expected: PASS。

## Task 4: 密文下载与本地落地

**Files:**
- Create: `vaultsync-app/lib/features/download/download_service.dart`
- Create: `vaultsync-app/lib/features/download/download_models.dart`
- Create: `vaultsync-app/lib/core/storage/app_storage.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_app/features/download/download_models.dart';

void main() {
  test('DownloadedObject stores version metadata', () {
    final object = DownloadedObject(
      versionId: 'ver-1',
      objectId: 'obj-1',
      syncRootId: 'root-1',
      fileName: 'hello.txt',
      bytes: const [1, 2, 3],
    );
    expect(object.versionId, 'ver-1');
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd vaultsync-app && flutter test`

Expected: FAIL，`DownloadedObject` 尚未实现。

- [ ] **Step 3: 写最小实现**

```dart
class DownloadedObject {
  final String versionId;
  final String objectId;
  final String syncRootId;
  final String fileName;
  final List<int> bytes;

  const DownloadedObject({
    required this.versionId,
    required this.objectId,
    required this.syncRootId,
    required this.fileName,
    required this.bytes,
  });
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd vaultsync-app && flutter test`

Expected: PASS。

## Task 5: 文档与最终验证

**Files:**
- Modify: `docs/specs/2026-06-25-vaultsync-design.md`
- Modify: `docs/specs/2026-06-26-sync-protocol.md`
- Modify: `docs/specs/2026-06-26-encryption-format.md`
- Modify: `docs/specs/2026-06-26-local-cleanup-policy.md`
- Modify: `docs/notes/backend-mvp.md`
- Modify: `docs/notes/decisions.md`
- Modify: `CHANGELOG.md`

- [x] **Step 1: 更新客户端范围文档**

补充 Flutter 客户端 MVP 的实际范围：

- 登录与设备绑定
- 同步目录查看
- 变更拉取
- 密文下载
- 本地落地

- [x] **Step 2: 更新变更记录**

记录 Flutter 客户端 MVP 工程已开始，作为后续同步闭环的前端载体。

- [x] **Step 3: 全量验证**

Run: `cd vaultsync-app && flutter test`

Expected: PASS。
