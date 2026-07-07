import { createRouter, createWebHistory } from 'vue-router';
import OverviewView from '../views/OverviewView.vue';
import UsersView from '../views/UsersView.vue';
import QuotaView from '../views/QuotaView.vue';
import SettingsView from '../views/SettingsView.vue';
import DownloadsView from '../views/DownloadsView.vue';
import AuditLogsView from '../views/AuditLogsView.vue';
import SystemStatusView from '../views/SystemStatusView.vue';
import LoginView from '../views/LoginView.vue';
import RegisterView from '../views/RegisterView.vue';
import { getAdminToken } from '../api/admin';

const router = createRouter({
  history: createWebHistory('/admin/'),
  routes: [
    { path: '/login', name: 'login', component: LoginView, meta: { public: true } },
    { path: '/register', name: 'register', component: RegisterView, meta: { public: true } },
    { path: '/', name: 'overview', component: OverviewView },
    { path: '/users', name: 'users', component: UsersView },
    { path: '/quotas', name: 'quotas', component: QuotaView },
    { path: '/system', name: 'system', component: SystemStatusView },
    { path: '/audit-logs', name: 'auditLogs', component: AuditLogsView },
    { path: '/settings', name: 'settings', component: SettingsView },
    { path: '/downloads', name: 'downloads', component: DownloadsView },
  ],
});

router.beforeEach((to) => {
  if (to.meta.public) {
    return true;
  }
  if (!getAdminToken()) {
    return { path: '/login', query: { redirect: to.fullPath } };
  }
  return true;
});

export default router;
