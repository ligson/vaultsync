import { ApiError, requestJson, type ApiEnvelope, type RequestOptions } from '@vaultsync/api-client';

const tokenKey = 'vaultsync_admin_token';

export interface AdminSession {
  token: string;
  token_id: string;
  user_id: string;
  expires_at: string;
}

export interface AdminUser {
  id: string;
  email: string;
  role: string;
  status: string;
  quota_bytes: number;
  used_bytes: number;
  created_at: string;
}

export interface AdminOverview {
  user_count: number;
  device_count: number;
  storage_bytes: number;
  recent_error_count: number;
  recent_events: AuditLog[];
}

export interface AuditLog {
  id: string;
  actor_user_id: string;
  action: string;
  details_json: string;
  created_at: string;
}

export interface SystemStatus {
  status: string;
  http_addr: string;
  data_dir: string;
  database_path: string;
  download_dir: string;
  storage_used_bytes: number;
  database_bytes: number;
  download_bytes: number;
  user_count: number;
  device_count: number;
}

export interface AdminSettings {
  admin_registration_enabled: boolean;
  default_user_quota_bytes: number;
  version_retention_count: number;
  max_upload_bytes: number;
  default_cleanup_policy: string;
}

export interface DownloadRelease {
  platform: string;
  file_name: string;
  version: string;
  download_url: string;
  size_bytes: number;
  updated_at: string;
}

export function getAdminToken() {
  return localStorage.getItem(tokenKey) || '';
}

export function saveAdminToken(token: string) {
  localStorage.setItem(tokenKey, token);
}

export function clearAdminToken() {
  localStorage.removeItem(tokenKey);
}

async function adminRequest<T>(path: string, options: RequestOptions = {}): Promise<ApiEnvelope<T>> {
  try {
    return await requestJson<T>(path, options);
  } catch (error) {
    if (error instanceof ApiError && (error.status === 401 || error.status === 403)) {
      clearAdminToken();
      window.dispatchEvent(
        new CustomEvent('vaultsync-admin-auth-expired', {
          detail: { message: error.message || '登录已过期，请重新登录' },
        }),
      );
    }
    throw error;
  }
}

export async function registerAdmin(email: string, password: string) {
  return adminRequest<{ id: string; email: string; role: string }>('/api/v1/admin/auth/register', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
}

export async function loginAdmin(email: string, password: string) {
  return adminRequest<AdminSession>('/api/v1/admin/auth/login', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
}

export async function fetchMe() {
  return adminRequest<AdminUser>('/api/v1/admin/me', { token: getAdminToken() });
}

export async function fetchOverview() {
  return adminRequest<AdminOverview>('/api/v1/admin/overview', { token: getAdminToken() });
}

export async function fetchAuditLogs(limit = 100) {
  return adminRequest<{ items: AuditLog[] }>(`/api/v1/admin/audit-logs?limit=${limit}`, { token: getAdminToken() });
}

export async function fetchSystemStatus() {
  return adminRequest<SystemStatus>('/api/v1/admin/system/status', { token: getAdminToken() });
}

export async function fetchUsers() {
  return adminRequest<{ items: AdminUser[] }>('/api/v1/admin/users', { token: getAdminToken() });
}

export async function createUser(payload: { email: string; password: string; quota_bytes: number }) {
  return adminRequest<AdminUser>('/api/v1/admin/users', {
    method: 'POST',
    token: getAdminToken(),
    body: JSON.stringify(payload),
  });
}

export async function updateUser(id: string, payload: { status: string; quota_bytes: number }) {
  return adminRequest<AdminUser>(`/api/v1/admin/users/${id}`, {
    method: 'PATCH',
    token: getAdminToken(),
    body: JSON.stringify(payload),
  });
}

export async function resetUserPassword(id: string, password: string) {
  return adminRequest<Record<string, never>>(`/api/v1/admin/users/${id}/reset-password`, {
    method: 'POST',
    token: getAdminToken(),
    body: JSON.stringify({ password }),
  });
}

export async function fetchSettings() {
  return adminRequest<AdminSettings>('/api/v1/admin/settings', { token: getAdminToken() });
}

export async function updateSettings(payload: Partial<AdminSettings>) {
  return adminRequest<AdminSettings>('/api/v1/admin/settings', {
    method: 'PUT',
    token: getAdminToken(),
    body: JSON.stringify(payload),
  });
}

export async function fetchDownloads() {
  return adminRequest<{ items: DownloadRelease[] }>('/api/v1/admin/downloads', { token: getAdminToken() });
}

export async function updateDownload(
  platform: string,
  payload: Pick<DownloadRelease, 'file_name' | 'version' | 'download_url'>,
) {
  return adminRequest<DownloadRelease>(`/api/v1/admin/downloads/${platform}`, {
    method: 'PUT',
    token: getAdminToken(),
    body: JSON.stringify(payload),
  });
}

export async function uploadDownload(platform: string, payload: { version: string; file: File }) {
  const form = new FormData();
  form.set('version', payload.version);
  form.set('file', payload.file);
  return adminRequest<DownloadRelease>(`/api/v1/admin/downloads/${platform}/upload`, {
    method: 'POST',
    token: getAdminToken(),
    body: form,
  });
}

export async function uploadDownloadWithProgress(
  platform: string,
  payload: { version: string; file: File },
  onProgress: (percent: number) => void,
) {
  const form = new FormData();
  form.set('version', payload.version);
  form.set('file', payload.file);

  return new Promise<ApiEnvelope<DownloadRelease>>((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open('POST', `/api/v1/admin/downloads/${platform}/upload`);
    request.setRequestHeader('Authorization', `Bearer ${getAdminToken()}`);
    request.setRequestHeader('Accept', 'application/json');
    request.upload.onprogress = (event) => {
      if (event.lengthComputable) {
        onProgress(Math.round((event.loaded / event.total) * 100));
      }
    };
    request.onload = () => {
      let payloadEnvelope: ApiEnvelope<DownloadRelease> | undefined;
      try {
        payloadEnvelope = JSON.parse(request.responseText) as ApiEnvelope<DownloadRelease>;
      } catch {
        reject(new ApiError('服务器返回内容格式不正确', request.status));
        return;
      }
      if (request.status === 401 || request.status === 403) {
        clearAdminToken();
        window.dispatchEvent(
          new CustomEvent('vaultsync-admin-auth-expired', {
            detail: { message: payloadEnvelope.message || '登录已过期，请重新登录' },
          }),
        );
      }
      if (payloadEnvelope.httpCode !== request.status) {
        reject(new ApiError('接口状态码不一致', request.status, payloadEnvelope as ApiEnvelope<unknown>));
        return;
      }
      if (request.status < 200 || request.status >= 300 || !payloadEnvelope.success) {
        reject(new ApiError(payloadEnvelope.message || '上传失败', request.status, payloadEnvelope as ApiEnvelope<unknown>));
        return;
      }
      resolve(payloadEnvelope);
    };
    request.onerror = () => reject(new ApiError('网络连接失败，请检查后端服务', 0));
    request.send(form);
  });
}

export async function deleteDownloadFile(platform: string) {
  return adminRequest<Record<string, never>>(`/api/v1/admin/downloads/${platform}/file`, {
    method: 'DELETE',
    token: getAdminToken(),
  });
}
