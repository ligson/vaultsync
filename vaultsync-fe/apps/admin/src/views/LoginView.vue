<script setup lang="ts">
import { message } from 'ant-design-vue';
import { reactive, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { loginAdmin, saveAdminToken } from '../api/admin';

const router = useRouter();
const route = useRoute();
const loading = ref(false);
const form = reactive({
  email: '',
  password: '',
});
const rules = {
  email: [
    { required: true, message: '请输入管理员邮箱' },
    { type: 'email', message: '请输入正确的邮箱地址' },
  ],
  password: [{ required: true, message: '请输入密码' }],
};

async function submit() {
  loading.value = true;
  try {
    const resp = await loginAdmin(form.email, form.password);
    saveAdminToken(resp.data.token);
    message.success('登录成功');
    await router.push(String(route.query.redirect || '/'));
  } catch (error) {
    message.error(error instanceof Error ? error.message : '登录失败');
  } finally {
    loading.value = false;
  }
}
</script>

<template>
  <main class="auth-page">
    <section class="auth-card">
      <div class="auth-brand">
        <img class="brand-icon auth-brand-icon" src="/vaultsync-icon.png" alt="VaultSync" />
        <div>
          <h1>VaultSync 管理后台</h1>
          <p>登录后管理用户、限额、系统配置和客户端下载。</p>
        </div>
      </div>
      <a-form :model="form" :rules="rules" layout="vertical" @finish="submit">
        <a-form-item label="管理员邮箱" name="email">
          <a-input v-model:value="form.email" size="large" autocomplete="username" />
        </a-form-item>
        <a-form-item label="密码" name="password">
          <a-input-password v-model:value="form.password" size="large" autocomplete="current-password" />
        </a-form-item>
        <a-button type="primary" size="large" block html-type="submit" :loading="loading">登录</a-button>
      </a-form>
      <p class="auth-switch">还没有管理员账号？<RouterLink to="/register">注册管理员</RouterLink></p>
    </section>
  </main>
</template>
