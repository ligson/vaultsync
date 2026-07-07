<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { message } from 'ant-design-vue';
import { fetchUsers, updateUser, type AdminUser } from '../api/admin';
import AdminLayout from '../layouts/AdminLayout.vue';

const loading = ref(true);
const users = ref<AdminUser[]>([]);

onMounted(async () => {
  await loadUsers();
});

async function loadUsers() {
  loading.value = true;
  try {
    const resp = await fetchUsers();
    users.value = resp.data.items || [];
  } finally {
    loading.value = false;
  }
}

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  return `${(value / 1024 / 1024 / 1024).toFixed(1)} GB`;
}

function usedPercent(record: AdminUser) {
  if (record.quota_bytes <= 0) return 0;
  return Math.min(100, Math.round((record.used_bytes / record.quota_bytes) * 100));
}

async function saveQuota(record: AdminUser, value: number) {
  await updateUser(record.id, {
    status: record.status,
    quota_bytes: Math.round(value * 1024 * 1024 * 1024),
  });
  message.success('用户配额已保存');
  await loadUsers();
}
</script>

<template>
  <AdminLayout>
    <div class="page-title">
      <h2>配额管理</h2>
      <p>查看每个用户的存储占用，并按用户调整可用容量。</p>
    </div>

    <a-card>
      <a-table :data-source="users" :pagination="false" row-key="id" :loading="loading">
        <a-table-column title="用户" data-index="email" />
        <a-table-column title="已用空间">
          <template #default="{ record }">
            {{ formatBytes(record.used_bytes) }}
          </template>
        </a-table-column>
        <a-table-column title="容量限额">
          <template #default="{ record }">
            <a-input-number
              :value="Math.round(record.quota_bytes / 1024 / 1024 / 1024)"
              :min="0"
              addon-after="GB"
              @press-enter="(event: KeyboardEvent) => saveQuota(record, Number((event.target as HTMLInputElement).value))"
            />
            <span class="quota-text">当前 {{ formatBytes(record.quota_bytes) }}</span>
          </template>
        </a-table-column>
        <a-table-column title="使用率">
          <template #default="{ record }">
            <a-progress :percent="usedPercent(record)" size="small" />
          </template>
        </a-table-column>
        <a-table-column title="状态">
          <template #default="{ record }">
            <a-tag :color="record.status === 'active' ? 'green' : 'orange'">
              {{ record.status === 'active' ? '正常' : '已锁定' }}
            </a-tag>
          </template>
        </a-table-column>
      </a-table>
    </a-card>
  </AdminLayout>
</template>
