# API 错误响应规范

## 目标

为 VaultSync 后端 API 提供稳定的 JSON 错误响应格式，方便后续桌面端、移动端和脚本客户端统一处理失败场景。

## 范围

- 统一业务接口错误体为 JSON。
- 保留当前 HTTP 状态码的大体语义。
- 给常见错误提供稳定 `code`。
- 不引入国际化、多语言错误文本。
- 不改动成功响应结构。

## 错误格式

所有 API 错误响应使用：

```json
{
  "error": {
    "code": "invalid_request",
    "message": "invalid json"
  }
}
```

字段说明：

- `error.code`：稳定机器可读错误码，客户端优先依赖此字段。
- `error.message`：面向调试的简短说明，不承诺长期稳定。

## 错误码

- `invalid_request`：请求格式、参数或业务前置条件不满足。
- `unauthorized`：缺少或无效认证。
- `not_found`：资源不存在。MVP 阶段多数无权限场景会继续返回 `invalid_request`，避免暴露其他用户资源是否存在。
- `internal_error`：服务端未知错误。

## HTTP 状态码约定

- `400 Bad Request`：请求 JSON 无效、参数缺失、越权业务操作、上传状态错误。
- `401 Unauthorized`：缺少 Bearer Token 或 Token 无效。
- `404 Not Found`：路由不存在。
- `500 Internal Server Error`：非预期服务端错误。

## 实现策略

新增 `handlers.writeError(w, status, code, message)` 统一 handler 内错误响应。认证中间件因不在 handlers 包内，使用同样 JSON 结构返回 `401`。

本阶段先覆盖已有 API handler 和鉴权中间件。后续如果需要更精细错误码，可以在 service 层引入哨兵错误或领域错误类型。

## 验收标准

- 认证失败返回 JSON 错误体。
- 无效 JSON 请求返回 JSON 错误体。
- 业务校验失败返回 JSON 错误体。
- 下载不存在或无权限版本返回 JSON 错误体。
- `rtk go test ./...` 通过。
- `rtk make build` 通过。
