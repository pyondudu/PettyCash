// 最小 service worker：讓手機可「加入主畫面」；資料一律走網路以確保即時
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()))
self.addEventListener('fetch', () => {})

// 推播：內容由 Edge Function petty-push 送來 { title, body, url, tag }
self.addEventListener('push', (e) => {
  let d = {}
  try { d = e.data ? e.data.json() : {} } catch { d = { body: e.data && e.data.text() } }
  e.waitUntil(self.registration.showNotification(d.title || '零用金申請', {
    body: d.body || '有新通知',
    icon: 'icon-192.png',
    badge: 'badge-96.png',   // Android 狀態列小圖示：透明背景單色，彩色圖會變白色方塊
    tag: d.tag,
    data: { url: d.url || './' },
  }))
})

// 點通知：已經開著就切過去，否則開新視窗
self.addEventListener('notificationclick', (e) => {
  e.notification.close()
  const url = new URL(e.notification.data?.url || './', self.registration.scope).href
  e.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const c of list) {
      if (c.url.startsWith(self.registration.scope)) {
        await c.focus()
        try { await c.navigate(url) } catch {}
        return
      }
    }
    await self.clients.openWindow(url)
  })())
})
