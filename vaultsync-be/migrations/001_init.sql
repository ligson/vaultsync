PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'user',
    status TEXT NOT NULL DEFAULT 'active',
    quota_bytes INTEGER NOT NULL DEFAULT 107374182400,
    used_bytes INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    username TEXT NOT NULL DEFAULT '',
    nickname TEXT NOT NULL DEFAULT ''
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username
ON users(username)
WHERE username <> '';

CREATE TABLE IF NOT EXISTS sessions (
    token_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_id TEXT,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    client_key TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_user_client_key
ON devices(user_id, client_key)
WHERE client_key <> '';

CREATE TABLE IF NOT EXISTS sync_roots (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    encrypted_path TEXT NOT NULL,
    encryption_enabled INTEGER NOT NULL DEFAULT 0,
    cleanup_policy TEXT NOT NULL,
    archive_path TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (device_id) REFERENCES devices(id)
);

CREATE TABLE IF NOT EXISTS upload_sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    sync_root_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    version_id TEXT NOT NULL,
    total_size INTEGER NOT NULL,
    chunk_size INTEGER NOT NULL,
    received_size INTEGER NOT NULL,
    status TEXT NOT NULL,
    metadata_json TEXT NOT NULL,
    media_index_json TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (device_id) REFERENCES devices(id),
    FOREIGN KEY (sync_root_id) REFERENCES sync_roots(id)
);

CREATE TABLE IF NOT EXISTS media_assets (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    sync_root_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    version_id TEXT NOT NULL,
    media_type TEXT NOT NULL,
    captured_at TEXT NOT NULL,
    captured_year INTEGER NOT NULL,
    captured_month INTEGER NOT NULL,
    width INTEGER NOT NULL DEFAULT 0,
    height INTEGER NOT NULL DEFAULT 0,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    thumbnail_path TEXT NOT NULL DEFAULT '',
    thumbnail_size_bytes INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    UNIQUE(user_id, sync_root_id, object_id),
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (device_id) REFERENCES devices(id),
    FOREIGN KEY (sync_root_id) REFERENCES sync_roots(id),
    FOREIGN KEY (version_id) REFERENCES file_versions(id)
);

CREATE INDEX IF NOT EXISTS idx_media_assets_timeline
ON media_assets(user_id, captured_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_media_assets_device_timeline
ON media_assets(user_id, device_id, captured_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_media_assets_type_timeline
ON media_assets(user_id, media_type, captured_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_media_assets_months
ON media_assets(user_id, captured_year DESC, captured_month DESC);

CREATE INDEX IF NOT EXISTS idx_media_assets_month_timeline
ON media_assets(
    user_id, captured_year, captured_month, captured_at DESC, id DESC
);

CREATE TABLE IF NOT EXISTS file_versions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    sync_root_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    encrypted_name TEXT NOT NULL,
    content_path TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    metadata_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (sync_root_id) REFERENCES sync_roots(id)
);

CREATE TABLE IF NOT EXISTS sync_cursors (
    user_id TEXT PRIMARY KEY,
    cursor_value INTEGER NOT NULL,
    version_id TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_logs (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    action TEXT NOT NULL,
    details_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE IF NOT EXISTS system_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS download_releases (
    platform TEXT PRIMARY KEY,
    file_name TEXT NOT NULL,
    version TEXT NOT NULL,
    download_url TEXT NOT NULL,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
);
