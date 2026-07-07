<script setup lang="ts">
import { onMounted, ref } from 'vue';
import { message } from 'ant-design-vue';
import { fetchSettings, updateSettings, type AdminSettings } from '../api/admin';
import AdminLayout from '../layouts/AdminLayout.vue';

const loading = ref(true);
const settings = ref<AdminSettings>({
  admin_registration_enabled: false,
  default_user_quota_bytes: 0,
  version_retention_count: 5,
  max_upload_bytes: 0,
  default_cleanup_policy: 'keep',
});

onMounted(async () => {
  await loadSettings();
});

async function loadSettings() {
  loading.value = true;
  try {
    const resp = await fetchSettings();
    settings.value = resp.data;
  } finally {
    loading.value = false;
  }
}

async function saveSettings() {
  const resp = await updateSettings({
    version_retention_count: settings.value.version_retention_count,
    max_upload_bytes: settings.value.max_upload_bytes,
    default_cleanup_policy: settings.value.default_cleanup_policy,
  });
  settings.value = resp.data;
  message.success('系统配置已保存');
}
</script>

<template>
  <AdminLayout>
    <div class="page-title">
      <div class="with-action">
        <div>
          <h2>系统配置</h2>
          <p>配置注册策略、版本保留、上传限制和默认清理策略。</p>
        </div>
        <a-button type="primary" @click="saveSettings">保存配置</a-button>
      </div>
    </div>
    <a-spin :spinning="loading">
    <a-row :gutter="20">
      <a-col :span="12">
        <a-card title="同步策略">
          <a-form layout="vertical">
            <a-form-item label="版本历史保留数量">
              <a-input-number v-model:value="settings.version_retention_count" :min="1" :max="20" class="wide-input" />
            </a-form-item>
            <a-form-item label="单文件上传上限">
              <a-select value="20GB">
                <a-select-option value="5GB">5 GB</a-select-option>
                <a-select-option value="20GB">20 GB</a-select-option>
                <a-select-option value="unlimited">不限</a-select-option>
              </a-select>
            </a-form-item>
            <a-form-item label="默认本地清理策略">
              <a-segmented v-model:value="settings.default_cleanup_policy" :options="['keep', 'delete']" />
            </a-form-item>
          </a-form>
        </a-card>
      </a-col>
      <a-col :span="12">
        <a-card title="安全配置">
          <a-form layout="vertical">
            <a-form-item label="开放注册">
              <a-switch v-model:checked="settings.admin_registration_enabled" />
            </a-form-item>
            <a-form-item label="管理员二次验证">
              <a-switch checked />
            </a-form-item>
            <a-form-item label="审计日志保留">
              <a-select value="180">
                <a-select-option value="90">90 天</a-select-option>
                <a-select-option value="180">180 天</a-select-option>
                <a-select-option value="365">365 天</a-select-option>
              </a-select>
            </a-form-item>
          </a-form>
        </a-card>
      </a-col>
    </a-row>
    </a-spin>
  </AdminLayout>
</template>
