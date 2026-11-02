<script setup>
import { onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { configured, supabase } from './lib/supabase'
import { store, initAuth } from './lib/store'
import { ROLES } from './lib/petty'
import Login from './views/Login.vue'
import { update, checkUpdate, applyUpdate, formatBuild, watchUpdates } from './lib/update'

const ICON = import.meta.env.BASE_URL + 'app-icon.svg'
const SITE_NAME = __SITE_NAME__
const router = useRouter()
const ready = ref(false)

onMounted(async () => {
  if (configured) await initAuth()
  ready.value = true
  watchUpdates()
  // 登入或換人後回首頁，依角色導向（重新整理時留在原頁）
  watch(() => store.member?.user_id, (v, old) => { if (v && v !== old) router.replace('/') })
})

// 「已是最新版／無法連線」顯示幾秒後恢復成按鈕
let resetTimer
watch(() => update.status, (v) => {
  clearTimeout(resetTimer)
  if (v === 'latest' || v === 'error') resetTimer = setTimeout(() => (update.status = 'idle'), 4000)
})

async function logout() {
  await supabase.auth.signOut()
  router.replace('/')
}
</script>

<template>
  <div v-if="!configured" class="center-box card">
    <h2>尚未設定 Supabase</h2>
    <p>請複製 <code>web/.env.example</code> 為 <code>web/.env</code>，填入 Project URL 與 anon key 後重新啟動。</p>
  </div>
  <template v-else-if="ready">
    <div v-if="update.status === 'available'" class="update-banner no-print">
      有新版本 <button class="btn small primary" @click="applyUpdate">立即更新</button>
    </div>
    <Login v-if="!store.session" />
    <div v-else-if="!store.loaded" class="center-box muted">載入中…</div>
    <div v-else-if="!store.member" class="center-box card">
      <h2>沒有使用權限</h2>
      <p class="muted">這個帳號還沒加入零用金系統，或已被停用。請洽管理者。</p>
      <button class="btn" @click="logout">登出</button>
    </div>
    <template v-else>
      <header class="topbar no-print">
        <router-link to="/" class="brand">
          <img :src="ICON" alt="" width="28" height="28" />
          <span>{{ SITE_NAME }}</span>
        </router-link>
        <div class="topbar-right">
          <span class="who">{{ store.member.name }}<span class="role-tag" :class="store.role">{{ ROLES[store.role] }}</span></span>
          <router-link to="/password" class="btn ghost small">改密碼</router-link>
          <button class="btn ghost small" @click="logout">登出</button>
        </div>
      </header>
      <nav class="tabs no-print">
        <router-link to="/mine">我的申請</router-link>
        <router-link to="/apply">申請</router-link>
        <router-link v-if="store.isApprover" to="/approve">待核准<span v-if="store.counts.pending" class="badge">{{ store.counts.pending }}</span></router-link>
        <router-link v-if="store.isAdmin" to="/admin">管理<span v-if="store.counts.approved" class="badge">{{ store.counts.approved }}</span></router-link>
        <router-link v-if="store.isAdmin" to="/members">成員</router-link>
        <router-link v-if="store.isAdmin" to="/settings">設定</router-link>
      </nav>
      <main class="container">
        <router-view />
      </main>
    </template>
    <footer class="version-bar no-print">
      版本 {{ formatBuild() || '開發版' }} ·
      <span v-if="update.status === 'checking'">檢查中…</span>
      <span v-else-if="update.status === 'latest'">已是最新版</span>
      <span v-else-if="update.status === 'error'">無法連線，稍後再試</span>
      <button v-else-if="update.status === 'available'" class="btn link update-link" @click="applyUpdate">有新版本，立即更新</button>
      <button v-else class="btn link" @click="checkUpdate()">檢查更新</button>
    </footer>
  </template>
</template>
