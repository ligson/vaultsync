<script setup lang="ts">
import { brand } from '@vaultsync/ui-theme';

const features = [
  { title: '零知识存储', body: '文件在客户端加密后再上传，服务器只保存密文和必要同步状态。' },
  { title: 'NAS 私有部署', body: '后端运行在自己的 NAS，数据边界、备份策略和访问入口都由你掌握。' },
  { title: '多端同步身份', body: '电脑、手机、平板使用同一账号同步，设备状态和同步目录清晰可查。' },
  { title: '相册空间释放', body: '上传成功并校验后，可按目录选择保留本地或清理本地副本。' },
];

const downloads = [
  { name: 'macOS', note: 'Apple Silicon / Intel', file: '/downloads/vaultsync-macos-latest.dmg' },
  { name: 'Windows', note: 'Windows 10 及以上', file: '/downloads/vaultsync-windows-latest.exe' },
  { name: 'Android', note: '相册自动备份', file: '/downloads/vaultsync-android-latest.apk' },
  { name: 'Linux', note: '桌面同步客户端', file: '/downloads/vaultsync-linux-latest.AppImage' },
];
</script>

<template>
  <main class="page-shell">
    <section class="hero">
      <nav class="nav">
        <a class="brand" href="/">
          <img class="brand-icon" src="/vaultsync-icon.png" alt="VaultSync" />
          <span>{{ brand.name }}</span>
        </a>
        <div class="nav-links">
          <a href="#features">能力</a>
          <a href="#download">下载</a>
          <a href="/admin/">管理后台</a>
        </div>
      </nav>

      <div class="hero-grid">
        <div class="hero-copy">
          <p class="eyebrow">Private encrypted sync for every device</p>
          <h1>把你的文件云，重新放回自己手里。</h1>
          <p class="lead">
            VaultSync 面向个人和小团队，把 NAS、端到端加密、多端同步和相册清理组合成一套可自控的私有同步系统。
          </p>
          <div class="hero-actions">
            <a class="primary-action" href="#download">下载客户端</a>
            <a class="secondary-action" href="/api/v1/health">检查服务状态</a>
          </div>
          <div class="trust-row" aria-label="系统特性">
            <span>端到端加密</span>
            <span>单机 NAS 部署</span>
            <span>统一同步身份</span>
          </div>
        </div>

        <div class="orbit-card" aria-hidden="true">
          <div class="vault-core">
            <span class="vault-lock"></span>
            <strong>Vault</strong>
          </div>
          <span class="orbit orbit-a"></span>
          <span class="orbit orbit-b"></span>
          <span class="device device-phone">手机</span>
          <span class="device device-desktop">电脑</span>
          <span class="device device-nas">NAS</span>
          <span class="sync-line line-a"></span>
          <span class="sync-line line-b"></span>
          <span class="sync-line line-c"></span>
        </div>
      </div>
    </section>

    <section id="features" class="section">
      <div class="section-heading">
        <p class="eyebrow">Designed for private ownership</p>
        <h2>不是又一个网盘，而是一套自己能掌控的同步底座。</h2>
      </div>
      <div class="feature-grid">
        <article v-for="feature in features" :key="feature.title" class="feature-card">
          <h3>{{ feature.title }}</h3>
          <p>{{ feature.body }}</p>
        </article>
      </div>
    </section>

    <section id="download" class="section download-section">
      <div class="download-panel">
        <div>
          <p class="eyebrow">Latest clients</p>
          <h2>下载最新客户端</h2>
          <p class="download-copy">这里只保留各平台最新版本。文件上传到服务器后，链接会自动指向 latest 包。</p>
        </div>
        <div class="download-grid">
          <a v-for="item in downloads" :key="item.name" class="download-card" :href="item.file">
            <span>{{ item.name }}</span>
            <small>{{ item.note }}</small>
          </a>
        </div>
      </div>
    </section>
  </main>
</template>
