import { createApp } from 'vue'
import { createRouter, createWebHashHistory } from 'vue-router'
import App from './App.vue'
import Apply from './views/Apply.vue'
import Mine from './views/Mine.vue'
import Approve from './views/Approve.vue'
import Reviewed from './views/Reviewed.vue'
import Admin from './views/Admin.vue'
import Members from './views/Members.vue'
import Settings from './views/Settings.vue'
import Password from './views/Password.vue'
import { store, refreshCounts } from './lib/store'
import './style.css'

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    // 登入後一律先到「我的申請」
    { path: '/', redirect: '/mine' },
    { path: '/apply', component: Apply },
    { path: '/mine', component: Mine },
    { path: '/approve', component: Approve, meta: { role: 'approver' } },
    { path: '/reviewed', component: Reviewed, meta: { role: 'approver' } },
    { path: '/admin', component: Admin, meta: { role: 'admin' } },
    { path: '/members', component: Members, meta: { role: 'admin' } },
    { path: '/settings', component: Settings, meta: { role: 'admin' } },
    { path: '/password', component: Password },
  ],
  scrollBehavior: () => ({ top: 0 }),
})

// 沒有權限的頁面回首頁（真正的權限由資料庫 RLS 把關）
router.beforeEach((to) => {
  if (to.meta.role && store.loaded && store.role !== to.meta.role) return '/'
})
router.afterEach(() => { refreshCounts() })

createApp(App).use(router).mount('#app')

if ('serviceWorker' in navigator && import.meta.env.PROD) {
  navigator.serviceWorker.register('./sw.js').catch(() => {})
}
