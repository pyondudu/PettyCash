import { reactive } from 'vue'
import { supabase } from './supabase'

export const store = reactive({
  session: null,
  member: null,       // petty_members 自己那一列；null = 不是成員或已停用
  loaded: false,      // 成員資料已讀取
  counts: { pending: 0, approved: 0 },  // 導覽列待處理筆數
  get uid() { return this.session?.user?.id ?? null },
  get role() { return this.member?.role ?? null },
  get isApprover() { return this.role === 'approver' },
  get isAdmin() { return this.role === 'admin' },
})

export async function initAuth() {
  const { data } = await supabase.auth.getSession()
  await setSession(data.session)
  supabase.auth.onAuthStateChange((_event, session) => {
    if (session?.user?.id !== store.session?.user?.id) setSession(session)
    else store.session = session
  })
}

async function setSession(session) {
  store.session = session
  store.member = null
  store.loaded = false
  store.counts = { pending: 0, approved: 0 }
  if (!session) return
  const { data } = await supabase.from('petty_members').select('*').eq('user_id', session.user.id).maybeSingle()
  store.member = data?.active ? data : null
  store.loaded = true
  await refreshCounts()
}

// 主管：待核准筆數；管理者：已核准待列印筆數
export async function refreshCounts() {
  if (!store.isApprover && !store.isAdmin) return
  const status = store.isApprover ? 'pending' : 'approved'
  const { count } = await supabase.from('petty_requests').select('id', { count: 'exact', head: true }).eq('status', status)
  store.counts[status] = count ?? 0
}

// Supabase / Postgres 錯誤訊息：trigger 的 raise exception 直接顯示中文
export function errText(e) {
  return e?.message || String(e)
}
