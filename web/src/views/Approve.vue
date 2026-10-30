<script setup>
import { onMounted, reactive, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { store, refreshCounts, errText } from '../lib/store'
import { canApprove } from '../lib/petty'
import RequestCard from '../components/RequestCard.vue'

const PAGE = 10

const pending = ref([])
const loading = ref(true)
const msg = ref('')
const rejecting = ref(null)   // 正在填退回原因的申請 id
const reason = ref('')
const busy = ref(false)

// 最近處理：依填寫日期由新到舊，一次 10 筆；可用日期區間、姓名搜尋
const recent = ref([])
const recentMore = ref(false)
const recentLoading = ref(false)
const search = reactive({ from: '', to: '', name: '' })

async function loadPending() {
  loading.value = true
  const { data, error } = await supabase.from('petty_requests').select('*, petty_vouchers(*)')
    .eq('status', 'pending').order('submitted_at')
  loading.value = false
  if (error) msg.value = '讀取失敗：' + errText(error)
  pending.value = data ?? []
  refreshCounts()
}

// more = true 時接著載入下一頁
async function loadRecent(more = false) {
  recentLoading.value = true
  const offset = more ? recent.value.length : 0
  let q = supabase.from('petty_requests').select('*, petty_vouchers(*)').eq('approver_id', store.uid)
  if (search.from) q = q.gte('fill_date', search.from)
  if (search.to) q = q.lte('fill_date', search.to)
  if (search.name.trim()) q = q.ilike('applicant_name', `%${search.name.trim()}%`)
  // 多抓一筆，用來判斷還有沒有下一頁
  const { data, error } = await q.order('fill_date', { ascending: false }).order('submitted_at', { ascending: false })
    .range(offset, offset + PAGE)
  recentLoading.value = false
  if (error) { msg.value = '讀取失敗：' + errText(error); return }
  recentMore.value = data.length > PAGE
  const page = data.slice(0, PAGE)
  recent.value = more ? [...recent.value, ...page] : page
}

function clearSearch() {
  Object.assign(search, { from: '', to: '', name: '' })
  loadRecent()
}

async function load() {
  await Promise.all([loadPending(), loadRecent()])
}

async function decide(req, status) {
  msg.value = ''
  if (status === 'approved' && !confirm(`核准 ${req.applicant_name} 的申請（${req.reason}，$${req.amount.toLocaleString()}）？`)) return
  if (status === 'rejected' && !reason.value.trim()) { msg.value = '請填寫退回原因'; return }
  busy.value = true
  const patch = status === 'rejected' ? { status, reject_reason: reason.value } : { status }
  const { error } = await supabase.from('petty_requests').update(patch).eq('id', req.id)
  busy.value = false
  if (error) { msg.value = '處理失敗：' + errText(error); return }
  rejecting.value = null
  reason.value = ''
  await load()
}

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>待核准（{{ pending.length }}）</h2>
      <button class="btn small" @click="load">重新整理</button>
    </div>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="loading" class="muted">載入中…</p>
    <p v-else-if="!pending.length" class="muted center empty">目前沒有待核准的申請。</p>
    <div class="list">
      <RequestCard v-for="r in pending" :key="r.id" :request="r" show-applicant open>
        <template #actions>
          <template v-if="canApprove(r, store.role)">
            <template v-if="rejecting === r.id">
              <input v-model="reason" class="reason-input" placeholder="退回原因" />
              <button class="btn small danger" :disabled="busy" @click="decide(r, 'rejected')">確定退回</button>
              <button class="btn small ghost" @click="rejecting = null">取消</button>
            </template>
            <template v-else>
              <button class="btn small danger" @click="rejecting = r.id; reason = ''">退回</button>
              <button class="btn small primary" :disabled="busy" @click="decide(r, 'approved')">核准</button>
            </template>
          </template>
        </template>
      </RequestCard>
    </div>

    <h3 class="sub-title">最近處理</h3>
    <form class="search-bar card" @submit.prevent="loadRecent()">
      <label>日期從<input v-model="search.from" type="date" /></label>
      <label>到<input v-model="search.to" type="date" /></label>
      <label>姓名<input v-model="search.name" type="search" placeholder="申請人姓名" /></label>
      <div class="search-actions">
        <button class="btn small primary">搜尋</button>
        <button type="button" class="btn small ghost" @click="clearSearch">清除</button>
      </div>
    </form>
    <p v-if="!recentLoading && !recent.length" class="muted center empty-small">沒有符合的紀錄。</p>
    <div class="list">
      <RequestCard v-for="r in recent" :key="r.id" :request="r" show-applicant />
    </div>
    <button v-if="recentMore" class="btn block" :disabled="recentLoading" @click="loadRecent(true)">
      {{ recentLoading ? '載入中…' : '顯示更多' }}
    </button>
  </div>
</template>
