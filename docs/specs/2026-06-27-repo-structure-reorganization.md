# VaultSync 仓库目录重构设计

## 1. 背景

当前 VaultSync 仓库同时承载后端代码、后端文档和项目规则。随着 Flutter 客户端即将加入，继续把所有内容放在根目录会让边界越来越糊。需要把仓库按产品边界拆清楚，方便后续分别演进后端、客户端和网页管理端。

## 2. 目标

- 后端统一放到 `vaultsync-be/`
- Flutter 客户端统一放到 `vaultsync-app/`
- 未来网页管理端统一预留到 `vaultsync-fe/`
- 根目录只保留项目总入口、规则和跨端文档
- 尽量保持历史链接和文档可读性

## 3. 重构后目录

```text
vaultsync/
  AGENTS.md
  CHANGELOG.md
  README.md
  docs/
  vaultsync-be/
  vaultsync-app/
  vaultsync-fe/
```

### 3.1 `vaultsync-be/`

放置后端所有运行时代码和部署文件：

- `cmd/`
- `internal/`
- `migrations/`
- `docker/`
- `go.mod`
- `go.sum`
- `Makefile`

### 3.2 `vaultsync-app/`

放置 Flutter 客户端工程：

- `pubspec.yaml`
- `lib/`
- `android/`
- `ios/`
- `macos/`
- `windows/`
- `linux/`
- `web/`

### 3.3 `vaultsync-fe/`

预留网页管理端位置，先放一个占位说明，后续再初始化前端工程。

## 4. 迁移原则

- 后端代码整体平移，不做业务重构
- 文档继续保留在根目录 `docs/`
- 后端 README 改成子项目说明，根目录 README 变成仓库总索引
- 路径引用统一更新，避免旧链接失效
- 先完成目录搬迁，再补 Flutter 客户端工程

## 5. 兼容策略

- 根目录保留总 README，指出后端、客户端和预留前端目录的位置
- 后端启动、构建、测试命令改为在 `vaultsync-be/` 下执行
- 现有 worktree 需要重新指向新路径或清理重建

## 6. 风险与处理

- 风险：大范围移动后路径引用失效
  - 处理：统一更新 README、Docker、计划文档和脚本引用
- 风险：Flutter 工程与后端重构同时进行导致分支混乱
  - 处理：先完成目录重构，再在 `vaultsync-app/` 初始化 Flutter
- 风险：历史文档链接变得难找
  - 处理：保留根目录索引 README，并在文档中明确新路径

## 7. 验收标准

- 后端代码已经全部位于 `vaultsync-be/`
- 根目录不再直接放后端运行代码
- 根目录 README 清楚说明各子目录职责
- `CHANGELOG.md` 记录本次重构
- 后端测试和构建在新路径下可运行

