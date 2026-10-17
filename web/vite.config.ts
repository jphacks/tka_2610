import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// 開発中は Rust (8080) に API・メディア・家具などの GLB（/home-assets）を中継する
const backend = 'http://localhost:8080'

export default defineConfig({
  plugins: [react()],
  server: {
    host: true,
    port: 5173,
    proxy: {
      '/api': backend,
      '/media': backend,
      '/home-assets': backend,
    },
  },
  build: {
    target: 'es2022',
    chunkSizeWarningLimit: 1500,
  },
})
