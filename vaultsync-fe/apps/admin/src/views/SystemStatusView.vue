<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { fetchSystemStatus, type SystemStatus } from '../api/admin';
import AdminLayout from '../layouts/AdminLayout.vue';

const loading = ref(true);
const status = ref<SystemStatus | null>(null);

const metrics = computed(() => {
  const value = status.value;
  if (!value) return [];
  return [
    { label: '服务状态', value: value.status === 'ok' ? '正常' : value.status, trend: '后端健康检查' },
    { label: '用户数', value: String(value.user_count), trend: '已注册账号' },
    { label: '设备数', value: String(value.device_count), trend: '已绑定设备' },
    { label: '存储占用', value: formatBytes(value.storage_used_bytes), trend: '数据目录总量' },
  ];
});

onMounted(async () => {
  try {
    const resp = await fetchSystemStatus();
    status.value = resp.data;
  } finally {
    loading.value = false;
  }
});

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  return `${(value / 1024 / 1024 / 1024).toFixed(1)} GB`;
}
</script>

<template>
  <AdminLayout>
    <div class="page-title">
      <h2>系统状态</h2>
      <p>查看后端运行状态、存储目录、数据库和下载目录占用。</p>
    </div>

    <a-spin :spinning="loading">
      <div class="metric-grid">
        <a-card v-for="item in metrics" :key="item.label" class="metric-card">
          <span>{{ item.label }}</span>
          <strong>{{ item.value }}</strong>
          <small>{{ item.trend }}</small>
        </a-card>
      </div>

      <a-card v-if="status" title="运行路径">
        <a-descriptions :column="1" bordered>
          <a-descriptions-item label="监听地址">{{ status.http_addr }}</a-descriptions-item>
          <a-descriptions-item label="数据目录">{{ status.data_dir }}</a-descriptions-item>
          <a-descriptions-item label="数据库文件">{{ status.database_path }}</a-descriptions-item>
          <a-descriptions-item label="下载目录">{{ status.download_dir }}</a-descriptions-item>
          <a-descriptions-item label="数据库大小">{{ formatBytes(status.database_bytes) }}</a-descriptions-item>
          <a-descriptions-item label="下载目录大小">{{ formatBytes(status.download_bytes) }}</a-descriptions-item>
        </a-descriptions>
      </a-card>
    </a-spin>
  </AdminLayout>
</template>
