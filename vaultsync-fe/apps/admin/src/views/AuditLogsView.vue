<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { fetchAuditLogs, type AuditLog } from '../api/admin';
import AdminLayout from '../layouts/AdminLayout.vue';

const loading = ref(true);
const logs = ref<AuditLog[]>([]);

onMounted(async () => {
  await loadLogs();
});

async function loadLogs() {
  loading.value = true;
  try {
    const resp = await fetchAuditLogs();
    logs.value = resp.data.items || [];
  } finally {
    loading.value = false;
  }
}

function actionText(action: string) {
  const map: Record<string, string> = {
    'admin.user.create': '创建用户',
    'admin.user.update': '更新用户',
    'admin.user.reset_password': '重置密码',
    'admin.settings.update': '更新系统配置',
    'admin.download.update': '编辑下载信息',
    'admin.download.upload': '上传安装包',
  };
  return map[action] || action;
}

function detailsText(value: string) {
  if (!value) return '{}';
  try {
    return JSON.stringify(JSON.parse(value), null, 2);
  } catch {
    return value;
  }
}
</script>

<template>
  <AdminLayout>
    <div class="page-title with-action">
      <div>
        <h2>审计日志</h2>
        <p>记录管理员创建用户、重置密码、调整配置和上传安装包等关键操作。</p>
      </div>
      <a-button @click="loadLogs">刷新</a-button>
    </div>

    <a-card>
      <a-table :data-source="logs" :pagination="{ pageSize: 12 }" row-key="id" :loading="loading">
        <a-table-column title="操作" data-index="action">
          <template #default="{ record }">
            <a-tag color="blue">{{ actionText(record.action) }}</a-tag>
          </template>
        </a-table-column>
        <a-table-column title="操作者" data-index="actor_user_id" />
        <a-table-column title="时间" data-index="created_at" />
        <a-table-column title="详情">
          <template #default="{ record }">
            <pre class="audit-details">{{ detailsText(record.details_json) }}</pre>
          </template>
        </a-table-column>
      </a-table>
    </a-card>
  </AdminLayout>
</template>
