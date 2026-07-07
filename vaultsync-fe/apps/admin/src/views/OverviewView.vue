<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { fetchOverview, type AdminOverview } from '../api/admin';
import AdminLayout from '../layouts/AdminLayout.vue';

const loading = ref(true);
const overview = ref<AdminOverview>({
  user_count: 0,
  device_count: 0,
  storage_bytes: 0,
  recent_error_count: 0,
  recent_events: [],
});

const recentEvents = computed(() => overview.value.recent_events || []);

const stats = computed(() => [
  { label: '用户数', value: String(overview.value.user_count), trend: '已注册账号' },
  { label: '设备数', value: String(overview.value.device_count), trend: '已绑定同步设备' },
  { label: '存储占用', value: formatBytes(overview.value.storage_bytes), trend: '密文对象总量' },
  { label: '最近错误', value: String(overview.value.recent_error_count), trend: '审计日志统计' },
]);

onMounted(async () => {
  try {
    const resp = await fetchOverview();
    overview.value = resp.data;
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
      <h2>运行概览</h2>
      <p>集中查看用户、设备、存储和同步任务的健康状态。</p>
    </div>
    <a-spin :spinning="loading">
    <div class="metric-grid">
      <a-card v-for="item in stats" :key="item.label" class="metric-card">
        <span>{{ item.label }}</span>
        <strong>{{ item.value }}</strong>
        <small>{{ item.trend }}</small>
      </a-card>
    </div>
    <a-row :gutter="20" class="content-row">
      <a-col :span="15">
        <a-card title="同步吞吐">
          <div class="chart-placeholder">
            <span v-for="height in [42, 68, 52, 88, 74, 104, 92, 126]" :key="height" :style="{ height: `${height}px` }" />
          </div>
        </a-card>
      </a-col>
      <a-col :span="9">
        <a-card title="最近事件">
          <a-timeline>
            <a-timeline-item v-for="item in recentEvents" :key="item.id">
              {{ item.action }} {{ item.created_at }}
            </a-timeline-item>
            <a-empty v-if="recentEvents.length === 0" description="暂无审计事件" />
          </a-timeline>
        </a-card>
      </a-col>
    </a-row>
    </a-spin>
  </AdminLayout>
</template>
