# 变更记录

所有有意义的项目变更都应记录在这里。

## 2026-07-07

- Flutter 客户端统一包装网络连接失败，登录、注册、设备注册等请求无法连接后端时显示明确中文提示，不再兜底为“操作失败，请稍后重试”。
- 登录流程新增分阶段错误提示，区分“登录成功后注册设备失败”“生成本地加密密钥失败”“保存本地登录状态失败”，方便定位手机端登录卡点。
- 修复普通用户重复注册时后端返回 `500 internal server error` 的问题，改为统一 JSON envelope 返回中文提示“该邮箱已注册，请直接登录或更换邮箱”。
- 发布并部署后端镜像 `ligson/vaultsync-be:20260707100101-2e5a606-dupemail` 到 nas-proxy，线上注册接口已验证重复邮箱返回可读中文错误。
- 将完整 Flutter 客户端从功能工作区合并回主目录，恢复同步中心、目录绑定、本地清理策略、相册备份、退出登录、服务端备份浏览与删除等客户端能力。
- 重新生成 Android release 签名 APK，release 默认后端地址保持为 `https://files.ligson.xyz`，并上传到 nas-proxy 的最新 Android 下载位置。
- 修正前端 workspace 忽略规则，避免 `node_modules`、`tsconfig.tsbuildinfo` 和类型检查生成物污染提交。

## 2026-07-06

- 同步 nas-proxy 真实后端配置，补齐 `app.admin` 配置段，并沉淀“配置结构变更必须同步远程 config.yaml”的私有部署规则。
- 生成 Android release 签名 APK，并将后端与前端镜像发布部署到 nas-proxy；官网、管理后台、健康检查和 Android 下载链接已完成线上验证。
- 下载管理补齐安装包文件大小、平台文件类型校验、上传进度、复制下载链接和删除旧包能力；后端同步新增大小字段与删除接口。
- 修复管理后台注册/登录表单缺少字段绑定导致点击提交无反馈的问题，并补充中文校验提示。
- 修复管理后台概览接口空审计事件返回 `null` 导致首页渲染失败的问题，统一空列表为 `[]` 并补充前端兜底。
- 管理后台拆分“用户管理”和“配额管理”：用户管理支持新增用户、锁定/启用登录、重置密码；配额管理专注查看已用空间与调整限额。
- 后端新增管理员创建普通用户与重置用户密码接口，并保持统一 JSON envelope。
- 修复管理后台顶部栏压住页面标题的布局问题，调整为稳定的侧边栏、顶部栏和内容区结构。
- 优化管理后台顶部栏标题排版，覆盖 Ant Design Header 默认行高导致的文字上下错位问题。
- 管理后台右上角操作区改为统一工具栏样式，并复用客户端 VaultSync 应用图标作为官网与后台品牌标识。
- 官网和管理后台新增统一的 `shortcut icon`、`favicon` 与 Apple touch icon，全部使用 VaultSync 应用图标。
- 管理后台新增“系统状态”页面，展示后端状态、监听地址、数据目录、数据库、下载目录和容量占用。
- 管理后台新增“审计日志”页面，展示管理员创建用户、重置密码、更新配置、上传安装包等关键操作记录。
- 后端新增管理员审计日志列表和系统状态接口，并在关键管理员操作成功后写入审计日志。
- 管理后台右上角显示真实管理员邮箱，支持修改当前管理员密码并在成功后重新登录。
- 前端 API 错误新增 HTTP 状态信息，管理后台遇到 401/403 会清理 token、提示登录过期并跳转登录页。
- 下载管理新增真实安装包上传能力，上传后保存到后端下载目录、更新 latest 元数据，并通过 `/downloads/` 公开下载。
- 新增后端公开健康检查接口 `GET /api/v1/health`，返回统一 JSON envelope，便于部署后验证服务与反向代理链路。
- Flutter 客户端 release 构建默认后端地址改为 `https://files.ligson.xyz`，调试构建仍默认使用 `http://127.0.0.1:8080`，显式配置继续最高优先级，并将统一配置接入应用入口与登录页。
- 新增 `docs/private/` 忽略规则，用于保存本地私有部署记录；私有服务器信息和真实部署配置不得提交。
- 完成一次单机 NAS 部署验证：后端使用 Docker Compose 单容器运行，nginx 通过域名转发到后端健康检查接口。
- 后端部署方式切换为镜像仓库模式，镜像发布到 `ligson/vaultsync-be`，NAS Compose 直接使用远程镜像，不再在部署目录保留源码或 runtime 构建目录。
- 新增后端镜像发布规范、`docker/release.Dockerfile` 与 Makefile 发布目标，固定 `linux/amd64` 镜像构建和推送流程。
- 初始化 `vaultsync-fe` 前端源码工程，包含官网首页 `portal`、管理后台 `admin`、共享 API client、共享主题包和前端容器 nginx 配置。
- 新增管理后台真实 API：管理员注册/登录、管理员鉴权、概览、用户、系统配置和下载列表接口；后台页面接入真实接口并增加登录/注册页。
- 补齐管理后台写接口：支持修改用户状态和限额、保存系统配置、更新各平台最新下载信息；前端按钮已接入对应 API。
- 后端配置改为 `config.yaml` 文件方式，支持 `-config` 指定配置路径，不再要求用户通过环境变量配置服务端口和存储路径。
- 后端配置文件新增 `app` 根节点，配置按 `app.server`、`app.storage`、`app.security` 分类，避免顶层配置项持续膨胀。
- 新增 `vaultsync-be/config.example.yaml` 与 `vaultsync-be/docker/config.example.yaml`，示例配置包含中文注释；真实 `config.yaml` 已加入忽略规则。
- 明确后端默认存储规则：`app.storage.data_dir` 默认 `./data`，`app.storage.database_path` 默认 `{app.storage.data_dir}/vaultsync.db`，`app.security.token_secret` 必须显式填写。
- 更新 README、Docker Compose、Makefile 和后端配置规范文档，统一说明配置文件启动方式。

## 2026-06-26

- 重构仓库目录：后端代码迁移到 `vaultsync-be/`，预留 `vaultsync-app/` 和 `vaultsync-fe/`，并同步更新根 README、规则和后端入口文件。
- 完成变更列表分页：`GET /api/v1/changes` 支持 `limit`，响应新增 `has_more`，服务端使用 `LIMIT limit+1` 探测是否还有下一页。
- 对齐同步协议、决策记录和后端 MVP 记忆，修正设备维度游标与远端删除墓碑的当前支持状态。
- 完成删除墓碑与变更类型：新增 `file_tombstones`、`sync_events`、`DELETE /api/v1/objects/{object_id}`，变更列表返回 `upsert/delete` 并使用统一事件游标。
- 新增删除墓碑与变更类型实现计划，准备让变更列表同时表达 `upsert` 和 `delete`。
- 完成设备维度变更游标：`GET /api/v1/changes` 支持可选 `device_id`，`sync_cursors` 升级为 `(user_id, device_id)` 复合主键，并保留 `__legacy__` 兼容键。
- 新增设备维度变更游标实现计划，准备将 `sync_cursors` 从用户维度升级为用户+设备维度并保持旧调用兼容。
- 新增 VaultSync 客户端本地清理策略 V1，明确 `keep`、`delete`、`archive` 行为、安全触发条件、移动端相册权限、失败重试和后端边界。
- 新增客户端本地清理策略 V1 计划，开始沉淀 `keep`、`delete`、`archive` 的安全触发条件、失败重试和移动端权限边界。
- 新增 VaultSync 同步协议 V1，明确设备初始化、本地扫描、上传、变更拉取、下载、冲突副本、本地清理触发点和当前后端支持边界。
- 新增同步协议 V1 计划，开始沉淀文件级同步、变更游标、冲突副本和本地清理触发点。
- 新增 VaultSync 加密格式规范 V1，明确客户端密钥层级、内容密文对象格式、加密元数据格式和后端不解析密文的边界。
- 新增加密格式规范计划，开始沉淀客户端加密格式、密钥层级和后端密文处理边界。
- 完成 API 错误响应规范化：认证中间件和现有 API handler 统一返回 JSON 错误体，并补充认证、无效请求、上传和下载错误测试。
- 新增 API 错误响应规范与实现计划，下一步统一后端错误体为 JSON，方便客户端处理。
- 完成后端隔离与上传链路硬化：新增跨用户设备/同步目录/下载隔离测试，补充上传会话归属、状态、大小和完整性校验。
- 新增后端隔离与上传链路硬化设计、实现计划，下一阶段聚焦设备/同步目录归属校验、上传状态与大小完整性校验。
- 收口后端 MVP 的计划文件结构：补充独立的同步目录测试、下载服务拆分、聚合测试、更完整的 README / notes，并让 `sync_cursors` 实际参与变更游标持久化。
- 补齐后端 MVP 收尾：HTTP 服务实际监听启动、Docker 单机部署文件、README 与后端 MVP 记忆文档。

## 2026-06-27

- 统一后端对外 JSON 响应为 `success/message/httpCode/data` envelope，新增共享响应包 `internal/httpapi/response`，并让认证中间件复用同一结构返回 401。
- 新增轻量领域错误类型，服务层可返回稳定错误码，handler 统一映射为 JSON envelope；跨用户下载或版本不存在返回 `404 not_found`，不再暴露底层 SQL 错误。
- 将后端集成测试迁移到 `vaultsync-be/tests/integration/`，确保 `cd vaultsync-be && go test ./...` 覆盖 API 主流程。
- 新增客户端 API 对接约定文档，说明 Flutter 客户端如何处理 envelope、错误码和二进制下载例外。
- 更新所有主要 API handler 的成功响应为统一 envelope，下载接口继续保持二进制输出。
- 改造测试辅助函数以解析统一 envelope，补齐认证、注册、同步目录、上传和变更列表相关测试适配。
- 将 API 响应规范文档改为统一 JSON envelope 约定，并把这条规则写入仓库规则文件。

## 2026-06-25

- 新增变更拉取与密文下载接口，当前用 `file_versions` 的顺序行号充当最小游标。
- 新增上传会话、分片追加、完成落盘与文件版本记录的最小闭环。
- 新增设备注册与同步目录新增、查询接口，并将相关接口接入 Bearer Token 鉴权。
- 新增注册与登录认证链路，包括 bcrypt 密码哈希、HMAC Bearer Token、认证路由和集成测试辅助工具。
- 对齐 SQLite 初始化表结构与后端 MVP 实现计划，补充核心表和关键列的 schema 测试。
- 新增 SQLite 初始化与迁移层，启用 WAL，并创建后端 MVP 核心元数据表。
- 收紧 Go 后端工程骨架基线：降低 Go 版本目标、补充配置测试，并忽略本地构建产物。
- 初始化 Go 后端工程骨架，新增配置加载、应用装配、服务入口和基础测试。
- 新增 `.gitignore`，忽略 `.worktrees/` 隔离工作区目录。
- 新增 Go + SQLite 后端 MVP 实现计划文档，路径为 `docs/superpowers/plans/2026-06-25-go-sqlite-backend-mvp.md`。
- 补充规则：实现计划统一放在 `docs/superpowers/plans/`。
- 将根目录 `README.md` 中文化。
- 将项目文档规则改为尽可能使用中文编写，技术名词和代码标识可保留英文。
- 将现有规则、说明和决策文档中的英文说明改为中文。
- 新增 `AGENTS.md` 仓库规则。
- 新增 `docs/` 文档结构。
- 新增第一版 VaultSync 设计稿。
- 新增用于沉淀决策和项目记忆的 `docs/notes/`。
