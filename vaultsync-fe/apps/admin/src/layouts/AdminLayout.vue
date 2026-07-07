<script setup lang="ts">
import {
  CloudServerOutlined,
  DashboardOutlined,
  DownloadOutlined,
  DatabaseOutlined,
  FileSearchOutlined,
  LogoutOutlined,
  MonitorOutlined,
  SettingOutlined,
  TeamOutlined,
  UserOutlined,
} from '@ant-design/icons-vue';
import { computed, onMounted, onUnmounted, ref } from 'vue';
import { message } from 'ant-design-vue';
import { useRoute, useRouter } from 'vue-router';
import { clearAdminToken, fetchMe, resetUserPassword, type AdminUser } from '../api/admin';

const route = useRoute();
const router = useRouter();
const currentUser = ref<AdminUser | null>(null);
const passwordOpen = ref(false);
const savingPassword = ref(false);
const passwordForm = ref({ password: '' });
const passwordRules = {
  password: [
    { required: true, message: '请输入新密码' },
    { min: 8, message: '密码至少需要 8 位' },
  ],
};

const userLabel = computed(() => currentUser.value?.email || '管理员');

const selectedKeys = computed(() => {
  if (route.path.startsWith('/users')) return ['users'];
  if (route.path.startsWith('/quotas')) return ['quotas'];
  if (route.path.startsWith('/system')) return ['system'];
  if (route.path.startsWith('/audit-logs')) return ['auditLogs'];
  if (route.path.startsWith('/settings')) return ['settings'];
  if (route.path.startsWith('/downloads')) return ['downloads'];
  return ['overview'];
});

function handleMenuSelect({ key }: { key: string }) {
  const pathMap: Record<string, string> = {
    overview: '/',
    users: '/users',
    quotas: '/quotas',
    system: '/system',
    auditLogs: '/audit-logs',
    settings: '/settings',
    downloads: '/downloads',
  };
  router.push(pathMap[key]);
}

async function logout() {
  clearAdminToken();
  await router.push('/login');
}

async function loadMe() {
  try {
    const resp = await fetchMe();
    currentUser.value = resp.data;
  } catch {
    // 登录过期由统一事件处理，这里不重复提示。
  }
}

function handleAuthExpired(event: Event) {
  const detail = (event as CustomEvent<{ message?: string }>).detail;
  message.warning(detail?.message || '登录已过期，请重新登录');
  router.push({ path: '/login', query: { redirect: route.fullPath } });
}

function openPasswordDialog() {
  passwordForm.value = { password: '' };
  passwordOpen.value = true;
}

async function submitPassword() {
  if (!currentUser.value) return;
  savingPassword.value = true;
  try {
    await resetUserPassword(currentUser.value.id, passwordForm.value.password);
    message.success('密码已修改，请重新登录');
    passwordOpen.value = false;
    clearAdminToken();
    await router.push('/login');
  } catch (error) {
    message.error(error instanceof Error ? error.message : '修改密码失败');
  } finally {
    savingPassword.value = false;
  }
}

onMounted(() => {
  window.addEventListener('vaultsync-admin-auth-expired', handleAuthExpired);
  void loadMe();
});

onUnmounted(() => {
  window.removeEventListener('vaultsync-admin-auth-expired', handleAuthExpired);
});
</script>

<template>
  <a-layout class="admin-shell">
    <a-layout-sider class="admin-sider" :width="248">
      <div class="sider-brand">
        <img class="brand-icon" src="/vaultsync-icon.png" alt="VaultSync" />
        <div>
          <strong>VaultSync</strong>
          <small>管理控制台</small>
        </div>
      </div>
      <a-menu
        theme="dark"
        mode="inline"
        :selected-keys="selectedKeys"
        class="admin-menu"
        @select="handleMenuSelect"
      >
        <a-menu-item key="overview">
          <template #icon><DashboardOutlined /></template>
          概览
        </a-menu-item>
        <a-menu-item key="users">
          <template #icon><TeamOutlined /></template>
          用户管理
        </a-menu-item>
        <a-menu-item key="quotas">
          <template #icon><DatabaseOutlined /></template>
          配额管理
        </a-menu-item>
        <a-menu-item key="system">
          <template #icon><MonitorOutlined /></template>
          系统状态
        </a-menu-item>
        <a-menu-item key="auditLogs">
          <template #icon><FileSearchOutlined /></template>
          审计日志
        </a-menu-item>
        <a-menu-item key="settings">
          <template #icon><SettingOutlined /></template>
          系统配置
        </a-menu-item>
        <a-menu-item key="downloads">
          <template #icon><DownloadOutlined /></template>
          下载管理
        </a-menu-item>
      </a-menu>
      <div class="sider-footer">
        <CloudServerOutlined />
        <span>files.ligson.xyz</span>
      </div>
    </a-layout-sider>

    <a-layout class="admin-main">
      <a-layout-header class="admin-header">
        <div class="header-title">
          <h1>VaultSync 管理后台</h1>
          <span>Private Sync Console</span>
        </div>
        <div class="admin-toolbar">
          <span class="service-status"><i></i>服务在线</span>
          <button class="admin-user" type="button" @click="openPasswordDialog">
            <UserOutlined /> {{ userLabel }}
          </button>
          <a-button class="logout-button" type="text" @click="logout">
            <template #icon><LogoutOutlined /></template>
            退出登录
          </a-button>
        </div>
      </a-layout-header>
      <a-layout-content class="admin-content">
        <slot />
      </a-layout-content>
    </a-layout>

    <a-modal v-model:open="passwordOpen" title="修改我的密码" :footer="null" destroy-on-close>
      <a-alert
        class="auth-alert"
        type="info"
        show-icon
        :message="`当前账号：${userLabel}`"
        description="密码修改成功后会退出当前登录，请使用新密码重新登录。"
      />
      <a-form :model="passwordForm" :rules="passwordRules" layout="vertical" @finish="submitPassword">
        <a-form-item label="新密码" name="password">
          <a-input-password v-model:value="passwordForm.password" autocomplete="new-password" />
        </a-form-item>
        <a-button type="primary" html-type="submit" block :loading="savingPassword">保存新密码</a-button>
      </a-form>
    </a-modal>
  </a-layout>
</template>
