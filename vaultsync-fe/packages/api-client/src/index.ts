export interface ApiEnvelope<T> {
  success: boolean;
  message: string;
  httpCode: number;
  data: T;
}

export interface RequestOptions extends RequestInit {
  token?: string;
}

export class ApiError extends Error {
  status: number;
  payload?: ApiEnvelope<unknown>;

  constructor(message: string, status: number, payload?: ApiEnvelope<unknown>) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.payload = payload;
  }
}

export async function requestJson<T>(
  path: string,
  options: RequestOptions = {},
): Promise<ApiEnvelope<T>> {
  const headers = new Headers(options.headers);
  headers.set('Accept', 'application/json');
  if (options.body && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }
  if (options.token) {
    headers.set('Authorization', `Bearer ${options.token}`);
  }

  const response = await fetch(path, {
    ...options,
    headers,
  });
  const payload = (await response.json()) as ApiEnvelope<T>;
  if (payload.httpCode !== response.status) {
    throw new ApiError('接口状态码不一致', response.status, payload as ApiEnvelope<unknown>);
  }
  if (!response.ok || !payload.success) {
    throw new ApiError(payload.message || '请求失败', response.status, payload as ApiEnvelope<unknown>);
  }
  return payload;
}
