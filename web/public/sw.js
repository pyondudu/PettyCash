// 最小 service worker：讓手機可「加入主畫面」；資料一律走網路以確保即時
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()))
self.addEventListener('fetch', () => {})
