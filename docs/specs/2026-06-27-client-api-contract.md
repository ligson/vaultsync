# 客户端 API 对接约定 V1

## 目标

本约定用于指导 Flutter 客户端、脚本客户端和后续网页管理端对接 VaultSync 后端 API。客户端只需要识别一种 JSON envelope，就能统一处理成功、失败、提示和业务数据。

## JSON 响应 envelope

除密文下载等二进制接口外，所有对外 JSON 接口返回：

```json
{
  "success": true,
  "message": "",
  "httpCode": 200,
  "data": {}
}
```

客户端处理规则：

- 先检查 HTTP 状态码，再校验 `httpCode` 是否一致。
- `success=true` 时从 `data` 读取业务数据。
- `success=false` 时展示 `message`，并优先根据 `data.code` 做程序化处理。
- `data` 没有业务数据时按空对象处理，不按 `null` 处理。

## 错误码

当前稳定错误码：

- `invalid_request`：请求 JSON、参数、上传状态或业务前置条件不满足。
- `unauthorized`：缺少 Bearer Token、Token 无效、登录凭证无效。
- `not_found`：资源不存在，或当前用户无权访问该资源且服务端不希望暴露资源存在性。
- `internal_error`：服务端未知异常。客户端可提示稍后重试，并记录本地诊断日志。

客户端不要依赖 `message` 做流程判断，`message` 主要用于显示或调试。

## 下载接口例外

`GET /api/v1/objects/{versionID}` 成功时返回 `application/octet-stream`，响应体是密文字节流，不使用 JSON envelope。

如果下载失败，例如版本不存在或无权限访问，则仍返回 JSON envelope：

```json
{
  "success": false,
  "message": "object version not found",
  "httpCode": 404,
  "data": {
    "code": "not_found"
  }
}
```

客户端应根据 `Content-Type` 和 HTTP 状态区分成功密文流与失败 JSON。

## Flutter 客户端建议

建议客户端定义统一响应模型：

```dart
class ApiEnvelope<T> {
  final bool success;
  final String message;
  final int httpCode;
  final T data;
}
```

建议网络层统一做：

- 自动注入 Bearer Token。
- 解码 JSON envelope。
- 当 `success=false` 时抛出统一 `ApiException`，包含 `statusCode`、`code`、`message`。
- 下载接口单独处理成功的二进制流；失败时复用 JSON envelope 解码。

## 验收标准

- 客户端不需要为每个 API 单独判断不同错误体结构。
- 登录失败、鉴权失败、业务校验失败和资源不存在都能通过 `data.code` 稳定分支。
- 二进制下载成功路径不被 JSON envelope 包裹。
