# 后端 MVP 记忆

## 当前实现

- 后端使用 Go + SQLite。
- SQLite 驱动使用 `modernc.org/sqlite`。
- 当前以单机 NAS 部署为目标，不考虑多实例或集群。
- 服务器端只保存密文对象与元数据索引。
- 上传流程包含会话创建、分片追加、完成落盘和文件版本记录。
- 下载接口按版本 ID 读取密文对象。
- 变更拉取接口当前使用 `file_versions` 的顺序行号作为最小游标。

## 约定

- 文档尽量使用中文。
- 有意义的变更必须写入 `CHANGELOG.md`。
- 长期有效的决策写入 `docs/notes/`。
- 实现计划写入 `docs/superpowers/plans/`。
