import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 網頁名稱與主題色；圖示放在 public/（app-icon.svg、icon-192.png、icon-512.png）
const TITLE = '聲智零用金申請'
const SHORT_NAME = '零用金'
const THEME_COLOR = '#2f6f5e'
// 每次建置的版本號；同時寫進程式與 version.json，App 比對兩者就知道有沒有新版
const BUILD_ID = new Date().toISOString()

function siteFiles() {
  return {
    'manifest.webmanifest': JSON.stringify({
      name: TITLE, short_name: SHORT_NAME, start_url: './', scope: './', display: 'standalone',
      background_color: '#ffffff', theme_color: THEME_COLOR,
      icons: [
        { src: 'app-icon.svg', sizes: 'any', type: 'image/svg+xml' },
        { src: 'icon-192.png', sizes: '192x192', type: 'image/png' },
        { src: 'icon-512.png', sizes: '512x512', type: 'image/png' },
      ],
    }, null, 2),
    'version.json': JSON.stringify({ build: BUILD_ID }),
  }
}

function sitePlugin() {
  return {
    name: 'pettycash-site',
    transformIndexHtml: (html) => html.replaceAll('%SITE_TITLE%', TITLE).replaceAll('%SITE_THEME%', THEME_COLOR),
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const body = siteFiles()[req.url.split('?')[0].replace(/^\//, '')]
        if (!body) return next()
        res.setHeader('Content-Type', req.url.includes('.json') ? 'application/json' : 'application/manifest+json')
        res.end(body)
      })
    },
    generateBundle() {
      for (const [fileName, source] of Object.entries(siteFiles())) this.emitFile({ type: 'asset', fileName, source })
    },
  }
}

// base 設為相對路徑，部署到 GitHub Pages 子目錄也能用
export default defineConfig({
  base: './',
  define: { __SITE_NAME__: JSON.stringify(TITLE), __BUILD_ID__: JSON.stringify(BUILD_ID) },
  plugins: [vue(), sitePlugin()],
})
