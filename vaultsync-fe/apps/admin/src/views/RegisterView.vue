<script setup lang="ts">
import { message } from 'ant-design-vue';
import { reactive, ref } from 'vue';
import { useRouter } from 'vue-router';
import { registerAdmin } from '../api/admin';

const router = useRouter();
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
  password: [
    { required: true, message: '请输入密码' },
    { min: 8, message: '密码至少需要 8 位' },
  ],
};

async function submit() {
  loading.value = true;
  try {
    await registerAdmin(form.email, form.password);
    message.success('管理员注册成功，请登录');
    await router.push('/login');
  } catch (error) {
    message.error(error instanceof Error ? error.message : '注册失败');
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
          <h1>注册管理员</h1>
          <p>注册功能可由后端配置关闭。创建首个管理员后建议关闭注册。</p>
        </div>
      </div>
      <a-alert
        class="auth-alert"
        type="warning"
        show-icon
        message="仅用于初始化或受控维护"
        description="如果服务器已关闭管理员注册，此页面会显示后端返回的中文提示。"
      />
      <a-form :model="form" :rules="rules" layout="vertical" @finish="submit">
        <a-form-item label="管理员邮箱" name="email">
          <a-input v-model:value="form.email" size="large" autocomplete="username" />
        </a-form-item>
        <a-form-item label="密码" name="password">
          <a-input-password v-model:value="form.password" size="large" autocomplete="new-password" />
        </a-form-item>
        <a-button type="primary" size="large" block html-type="submit" :loading="loading">注册</a-button>
      </a-form>
      <p class="auth-switch">已有账号？<RouterLink to="/login">返回登录</RouterLink></p>
    </section>
  </main>
</template>
