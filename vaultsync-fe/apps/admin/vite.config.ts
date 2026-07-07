import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

const apiProxyTarget = process.env.VAULTSYNC_API_PROXY_TARGET || 'http://127.0.0.1:8080';

export default defineConfig({
  plugins: [vue()],
  base: '/admin/',
  server: {
    proxy: {
      '/api': apiProxyTarget,
    },
  },
  build: {
    outDir: '../../dist/admin',
    emptyOutDir: true,
  },
});
