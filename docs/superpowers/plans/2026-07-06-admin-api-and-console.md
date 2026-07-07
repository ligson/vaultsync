# 管理后台真实 API 与控制台接入计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 VaultSync 增加管理员登录/注册、后台真实数据 API，并让 `vaultsync-fe/apps/admin` 从后端读取数据。

**Architecture:** 后端继续使用现有 `users` 表，增加角色、状态、限额字段；后台接口统一走 `/api/v1/admin/*`，并通过管理员权限中间件保护。前端管理后台增加登录/注册页，保存管理员 token 后访问真实 API。

**Tech Stack:** Go + SQLite + 统一 JSON envelope；Vue 3 + Vite + TypeScript + Ant Design Vue。

---

## 任务

- [ ] 扩展后端配置：增加 `app.admin.registration_enabled`、默认限额和默认系统设置。
- [ ] 扩展 SQLite schema：`users` 增加 `role/status/quota_bytes/used_bytes`，增加 `system_settings`、`download_releases`。
- [ ] 增加管理员认证接口：注册、登录、当前管理员信息。
- [ ] 增加管理员鉴权中间件：只有 `role=admin` 可访问 `/api/v1/admin/*`。
- [ ] 增加后台数据接口：概览、用户列表、系统配置、下载列表。
- [ ] 改造管理后台前端：增加登录/注册页，页面数据改为请求真实接口。
- [ ] 更新示例配置、文档和 `CHANGELOG.md`。
- [ ] 执行后端测试、前端构建和关键接口验证。
