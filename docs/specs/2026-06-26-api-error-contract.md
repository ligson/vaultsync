# API 统一 JSON 响应规范

## 目标

为 VaultSync 后端 API 提供稳定的统一 JSON 响应格式，方便后续桌面端、移动端和脚本客户端统一处理成功与失败场景。

## 范围

- 统一业务接口成功/错误体为 JSON envelope。
- 保留当前 HTTP 状态码的大体语义。
- 给常见错误提供稳定 `data.code`。
- 不引入国际化、多语言错误文本。
- 下载等非 JSON 资源接口保持原样。

## 错误格式

所有对外 JSON 接口使用：

```json
{
  "success": true,
  "message": "",
  "httpCode": 200,
  "data": {}
}
```

字段说明：

- `success`：接口处理是否成功。
- `message`：面向前端显示的说明信息。
- `httpCode`：必须与 HTTP 状态码一致。
- `data`：业务数据主体，没有数据时返回空对象。

错误响应同样使用这个 envelope，失败时 `success=false`，`data` 内携带错误码，例如：

```json
{
  "success": false,
  "message": "invalid json",
  "httpCode": 400,
  "data": {
    "code": "invalid_request"
  }
}
```

## 错误码

- `invalid_request`：请求格式、参数或业务前置条件不满足。
- `unauthorized`：缺少或无效认证。
- `not_found`：资源不存在。MVP 阶段多数无权限场景会继续返回 `invalid_request`，避免暴露其他用户资源是否存在。
- `internal_error`：服务端未知错误。

## HTTP 状态码约定

- `200 OK` / `201 Created` / `204 No Content`：成功响应状态。
- `400 Bad Request`：请求 JSON 无效、参数缺失、越权业务操作、上传状态错误。
- `401 Unauthorized`：缺少 Bearer Token 或 Token 无效。
- `404 Not Found`：路由不存在。
- `500 Internal Server Error`：非预期服务端错误。

## 实现策略

新增共享 `internal/httpapi/response` 包统一写入 envelope。`handlers.writeError(w, status, code, message)` 和认证中间件都复用它，避免每个 handler 手写不同格式。

本阶段先覆盖已有 API handler 和鉴权中间件。后续如果需要更精细错误码，可以在 service 层引入哨兵错误或领域错误类型。

## 验收标准

- 认证失败返回统一 JSON envelope。
- 无效 JSON 请求返回统一 JSON envelope。
- 业务校验失败返回统一 JSON envelope。
- 下载不存在或无权限版本返回统一 JSON envelope。
- `rtk go test ./...` 通过。
- `rtk make build` 通过。
