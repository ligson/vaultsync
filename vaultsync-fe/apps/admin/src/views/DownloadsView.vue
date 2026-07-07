<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { Modal, message } from 'ant-design-vue';
import { InboxOutlined } from '@ant-design/icons-vue';
import {
  deleteDownloadFile,
  fetchDownloads,
  updateDownload,
  uploadDownloadWithProgress,
  type DownloadRelease,
} from '../api/admin';
import AdminLayout from '../layouts/AdminLayout.vue';

const loading = ref(true);
const releases = ref<DownloadRelease[]>([]);
const editing = ref<DownloadRelease | null>(null);
const uploadOpen = ref(false);
const saving = ref(false);
const uploadPercent = ref(0);
const uploadFileList = ref<any[]>([]);
const uploadForm = reactive({
  platform: 'android',
  version: '',
  file: null as File | null,
});
const platformOptions = [
  { label: 'Android', value: 'android' },
  { label: 'macOS', value: 'macos' },
  { label: 'Windows', value: 'windows' },
  { label: 'Linux', value: 'linux' },
];
const fileRules: Record<string, { suffix: string; label: string }> = {
  android: { suffix: '.apk', label: 'Android 安装包 .apk' },
  macos: { suffix: '.dmg', label: 'macOS 安装包 .dmg' },
  windows: { suffix: '.exe', label: 'Windows 安装包 .exe' },
  linux: { suffix: '.appimage', label: 'Linux 安装包 .AppImage' },
};
const uploadHint = computed(() => fileRules[uploadForm.platform]?.label || '对应平台安装包');

onMounted(async () => {
  await loadDownloads();
});

async function loadDownloads() {
  loading.value = true;
  try {
    const resp = await fetchDownloads();
    releases.value = resp.data.items || [];
  } finally {
    loading.value = false;
  }
}

function openEdit(record: DownloadRelease) {
  editing.value = { ...record };
}

function openUpload(record?: DownloadRelease) {
  uploadForm.platform = record?.platform || 'android';
  uploadForm.version = record?.version || '';
  uploadForm.file = null;
  uploadPercent.value = 0;
  uploadFileList.value = [];
  uploadOpen.value = true;
}

function beforeUpload(file: File) {
  if (!isAllowedFile(uploadForm.platform, file.name)) {
    message.warning(`当前平台只能上传 ${uploadHint.value}`);
    return false;
  }
  uploadForm.file = file;
  uploadFileList.value = [file];
  return false;
}

function removeUploadFile() {
  uploadForm.file = null;
  uploadPercent.value = 0;
  uploadFileList.value = [];
}

function isAllowedFile(platform: string, fileName: string) {
  const suffix = fileRules[platform]?.suffix;
  return suffix ? fileName.toLowerCase().endsWith(suffix) : false;
}

function formatBytes(value: number) {
  if (!value) return '未上传';
  const units = ['B', 'KB', 'MB', 'GB'];
  let size = value;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  return `${size.toFixed(size >= 10 || unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}

function platformName(platform: string) {
  return platformOptions.find((item) => item.value === platform)?.label || platform;
}

async function copyDownloadLink(record: DownloadRelease) {
  if (!record.download_url) {
    message.warning('当前平台还没有下载地址');
    return;
  }
  const url = new URL(record.download_url, window.location.origin).toString();
  try {
    await navigator.clipboard.writeText(url);
    message.success('下载链接已复制');
  } catch {
    message.error('复制失败，请手动复制下载地址');
  }
}

async function saveDownload() {
  if (!editing.value) return;
  saving.value = true;
  try {
    await updateDownload(editing.value.platform, {
      file_name: editing.value.file_name,
      version: editing.value.version,
      download_url: editing.value.download_url,
    });
    message.success('下载版本已更新');
    editing.value = null;
    await loadDownloads();
  } catch (error) {
    message.error(error instanceof Error ? error.message : '更新下载版本失败');
  } finally {
    saving.value = false;
  }
}

async function submitUpload() {
  if (!uploadForm.file) {
    message.warning('请选择要上传的安装包文件');
    return;
  }
  if (!isAllowedFile(uploadForm.platform, uploadForm.file.name)) {
    message.warning(`当前平台只能上传 ${uploadHint.value}`);
    return;
  }
  if (!uploadForm.version.trim()) {
    message.warning('请输入版本号');
    return;
  }
  saving.value = true;
  uploadPercent.value = 0;
  try {
    await uploadDownloadWithProgress(uploadForm.platform, {
      version: uploadForm.version,
      file: uploadForm.file,
    }, (percent) => {
      uploadPercent.value = percent;
    });
    message.success('新版本已上传');
    uploadOpen.value = false;
    await loadDownloads();
  } catch (error) {
    message.error(error instanceof Error ? error.message : '上传新版本失败');
  } finally {
    saving.value = false;
  }
}

function confirmDelete(record: DownloadRelease) {
  if (!record.size_bytes) {
    message.info('当前平台还没有已上传的安装包');
    return;
  }
  Modal.confirm({
    title: `删除 ${platformName(record.platform)} 安装包？`,
    content: '删除后官网和客户端下载入口将暂时没有可下载文件，后续可以重新上传新版本。',
    okText: '删除文件',
    cancelText: '取消',
    okType: 'danger',
    async onOk() {
      try {
        await deleteDownloadFile(record.platform);
        message.success('安装包文件已删除');
        await loadDownloads();
      } catch (error) {
        message.error(error instanceof Error ? error.message : '删除安装包失败');
      }
    },
  });
}
</script>

<template>
  <AdminLayout>
    <div class="page-title with-action">
      <div>
        <h2>下载管理</h2>
        <p>上传各平台最新安装包，官网和客户端下载入口会指向 latest 文件。</p>
      </div>
      <a-button type="primary" @click="openUpload()">上传新版本</a-button>
    </div>

    <a-card>
      <a-table :data-source="releases" :pagination="false" row-key="platform" :loading="loading">
        <a-table-column title="平台">
          <template #default="{ record }">
            <strong>{{ platformName(record.platform) }}</strong>
          </template>
        </a-table-column>
        <a-table-column title="最新文件">
          <template #default="{ record }">
            <div class="download-file-cell">
              <span>{{ record.file_name }}</span>
              <small>{{ record.download_url }}</small>
            </div>
          </template>
        </a-table-column>
        <a-table-column title="文件大小">
          <template #default="{ record }">
            {{ formatBytes(record.size_bytes) }}
          </template>
        </a-table-column>
        <a-table-column title="版本" data-index="version" />
        <a-table-column title="更新时间" data-index="updated_at" />
        <a-table-column title="操作">
          <template #default="{ record }">
            <a-space>
              <a-button type="link" size="small" @click="openUpload(record)">上传替换</a-button>
              <a-dropdown>
                <a-button type="link" size="small">更多</a-button>
                <template #overlay>
                  <a-menu>
                    <a-menu-item @click="copyDownloadLink(record)">复制链接</a-menu-item>
                    <a-menu-item>
                      <a :href="record.download_url" target="_blank">打开链接</a>
                    </a-menu-item>
                    <a-menu-item @click="openEdit(record)">编辑链接</a-menu-item>
                    <a-menu-item danger @click="confirmDelete(record)">删除文件</a-menu-item>
                  </a-menu>
                </template>
              </a-dropdown>
            </a-space>
          </template>
        </a-table-column>
      </a-table>
    </a-card>

    <a-modal
      v-model:open="uploadOpen"
      title="上传最新版本"
      ok-text="上传"
      cancel-text="取消"
      :confirm-loading="saving"
      @ok="submitUpload"
    >
      <a-form layout="vertical">
        <a-form-item label="平台">
          <a-select v-model:value="uploadForm.platform" :options="platformOptions" />
        </a-form-item>
        <a-form-item label="版本号">
          <a-input v-model:value="uploadForm.version" placeholder="例如 1.0.3" />
        </a-form-item>
        <a-form-item label="安装包文件">
          <a-upload-dragger
            :file-list="uploadFileList"
            :before-upload="beforeUpload"
            :max-count="1"
            @remove="removeUploadFile"
          >
            <p class="ant-upload-drag-icon"><InboxOutlined /></p>
            <p class="ant-upload-text">点击或拖拽安装包到这里</p>
            <p class="ant-upload-hint">当前平台要求：{{ uploadHint }}。上传成功后会替换该平台最新版本。</p>
          </a-upload-dragger>
          <a-progress v-if="saving || uploadPercent > 0" :percent="uploadPercent" size="small" />
        </a-form-item>
      </a-form>
    </a-modal>

    <a-modal
      :open="!!editing"
      title="编辑下载链接"
      ok-text="保存"
      cancel-text="取消"
      :confirm-loading="saving"
      @ok="saveDownload"
      @cancel="editing = null"
    >
      <a-form v-if="editing" layout="vertical">
        <a-form-item label="平台">
          <a-input v-model:value="editing.platform" disabled />
        </a-form-item>
        <a-form-item label="文件名">
          <a-input v-model:value="editing.file_name" />
        </a-form-item>
        <a-form-item label="版本号">
          <a-input v-model:value="editing.version" />
        </a-form-item>
        <a-form-item label="下载地址">
          <a-input v-model:value="editing.download_url" />
        </a-form-item>
      </a-form>
    </a-modal>
  </AdminLayout>
</template>
