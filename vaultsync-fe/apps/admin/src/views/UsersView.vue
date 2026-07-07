<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue';
import { message, Modal } from 'ant-design-vue';
import {
  createUser,
  fetchUsers,
  resetUserPassword,
  updateUser,
  type AdminUser,
} from '../api/admin';
import AdminLayout from '../layouts/AdminLayout.vue';

const loading = ref(true);
const saving = ref(false);
const users = ref<AdminUser[]>([]);
const createOpen = ref(false);
const resetOpen = ref(false);
const currentUser = ref<AdminUser | null>(null);
const createForm = reactive({
  email: '',
  password: '',
  quotaGB: 100,
});
const resetForm = reactive({
  password: '',
});
const createRules = {
  email: [
    { required: true, message: '请输入用户邮箱' },
    { type: 'email', message: '请输入正确的邮箱地址' },
  ],
  password: [
    { required: true, message: '请输入初始密码' },
    { min: 8, message: '密码至少需要 8 位' },
  ],
  quotaGB: [{ required: true, message: '请输入初始配额' }],
};
const resetRules = {
  password: [
    { required: true, message: '请输入新密码' },
    { min: 8, message: '密码至少需要 8 位' },
  ],
};

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

function statusText(status: string) {
  return status === 'active' ? '正常' : '已锁定';
}

function roleText(role: string) {
  return role === 'admin' ? '管理员' : '普通用户';
}

function openCreate() {
  createForm.email = '';
  createForm.password = '';
  createForm.quotaGB = 100;
  createOpen.value = true;
}

async function submitCreate() {
  saving.value = true;
  try {
    await createUser({
      email: createForm.email,
      password: createForm.password,
      quota_bytes: Math.round(createForm.quotaGB * 1024 * 1024 * 1024),
    });
    message.success('用户已创建');
    createOpen.value = false;
    await loadUsers();
  } catch (error) {
    message.error(error instanceof Error ? error.message : '创建用户失败');
  } finally {
    saving.value = false;
  }
}

function confirmToggleStatus(record: AdminUser) {
  const nextStatus = record.status === 'active' ? 'disabled' : 'active';
  Modal.confirm({
    title: nextStatus === 'active' ? '启用用户' : '锁定用户',
    content:
      nextStatus === 'active'
        ? `确定要恢复 ${record.email} 的登录权限吗？`
        : `锁定后 ${record.email} 将无法登录客户端和后台。`,
    okText: nextStatus === 'active' ? '启用' : '锁定',
    cancelText: '取消',
    async onOk() {
      await updateUser(record.id, {
        status: nextStatus,
        quota_bytes: record.quota_bytes,
      });
      message.success(nextStatus === 'active' ? '用户已启用' : '用户已锁定');
      await loadUsers();
    },
  });
}

function openResetPassword(record: AdminUser) {
  currentUser.value = record;
  resetForm.password = '';
  resetOpen.value = true;
}

async function submitResetPassword() {
  if (!currentUser.value) return;
  saving.value = true;
  try {
    await resetUserPassword(currentUser.value.id, resetForm.password);
    message.success('用户密码已重置');
    resetOpen.value = false;
  } catch (error) {
    message.error(error instanceof Error ? error.message : '重置密码失败');
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <AdminLayout>
    <div class="page-title with-action">
      <div>
        <h2>用户管理</h2>
        <p>创建用户、锁定登录权限和重置密码；容量限额请到配额管理调整。</p>
      </div>
      <a-button type="primary" @click="openCreate">新增用户</a-button>
    </div>

    <a-card>
      <a-table :data-source="users" :pagination="false" row-key="id" :loading="loading">
        <a-table-column title="邮箱" data-index="email" />
        <a-table-column title="角色">
          <template #default="{ record }">
            <a-tag :color="record.role === 'admin' ? 'blue' : 'default'">{{ roleText(record.role) }}</a-tag>
          </template>
        </a-table-column>
        <a-table-column title="状态">
          <template #default="{ record }">
            <a-tag :color="record.status === 'active' ? 'green' : 'orange'">{{ statusText(record.status) }}</a-tag>
          </template>
        </a-table-column>
        <a-table-column title="创建时间" data-index="created_at" />
        <a-table-column title="操作">
          <template #default="{ record }">
            <a-space>
              <a-button size="small" @click="confirmToggleStatus(record)">
                {{ record.status === 'active' ? '锁定登录' : '启用登录' }}
              </a-button>
              <a-button size="small" @click="openResetPassword(record)">重置密码</a-button>
            </a-space>
          </template>
        </a-table-column>
      </a-table>
    </a-card>

    <a-modal v-model:open="createOpen" title="新增用户" :footer="null" destroy-on-close>
      <a-form :model="createForm" :rules="createRules" layout="vertical" @finish="submitCreate">
        <a-form-item label="用户邮箱" name="email">
          <a-input v-model:value="createForm.email" autocomplete="username" />
        </a-form-item>
        <a-form-item label="初始密码" name="password">
          <a-input-password v-model:value="createForm.password" autocomplete="new-password" />
        </a-form-item>
        <a-form-item label="初始配额" name="quotaGB">
          <a-input-number v-model:value="createForm.quotaGB" :min="0" addon-after="GB" class="wide-input" />
        </a-form-item>
        <a-button type="primary" html-type="submit" block :loading="saving">创建用户</a-button>
      </a-form>
    </a-modal>

    <a-modal v-model:open="resetOpen" title="重置密码" :footer="null" destroy-on-close>
      <a-alert
        class="auth-alert"
        type="warning"
        show-icon
        :message="`正在重置 ${currentUser?.email || ''} 的登录密码`"
        description="保存后旧密码会立即失效，用户需要使用新密码重新登录。"
      />
      <a-form :model="resetForm" :rules="resetRules" layout="vertical" @finish="submitResetPassword">
        <a-form-item label="新密码" name="password">
          <a-input-password v-model:value="resetForm.password" autocomplete="new-password" />
        </a-form-item>
        <a-button type="primary" html-type="submit" block :loading="saving">保存新密码</a-button>
      </a-form>
    </a-modal>
  </AdminLayout>
</template>
