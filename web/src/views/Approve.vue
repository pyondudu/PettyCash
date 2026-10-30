<script setup>
import { onMounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { store, refreshCounts, errText } from '../lib/store'
import { canApprove } from '../lib/petty'
import RequestCard from '../components/RequestCard.vue'

const pending = ref([])
const recent = ref([])
const loading = ref(true)
const msg = ref('')
const rejecting = ref(null)   // 正在填退回原因的申請 id
const reason = ref('')
const busy = ref(false)

async function load() {
  loading.value = true
  const [p, r] = await Promise.all([
    supabase.from('petty_requests').select('*, petty_vouchers(*)').eq('status', 'pending').order('submitted_at'),
    supabase.from('petty_requests').select('*, petty_vouchers(*)').eq('approver_id', store.uid)
      .order('approved_at', { ascending: false, nullsFirst: false }).limit(20),
  ])
  loading.value = false
  if (p.error || r.error) msg.value = '讀取失敗：' + errText(p.error || r.error)
  pending.value = p.data ?? []
  recent.value = r.data ?? []
  refreshCounts()
}

async function decide(req, status) {
  msg.value = ''
  if (status === 'approved' && !confirm(`核准 ${req.request_no}（${req.applicant_name}，$${req.amount.toLocaleString()}）？`)) return
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

    <template v-if="recent.length">
      <h3 class="sub-title">最近處理</h3>
      <div class="list">
        <RequestCard v-for="r in recent" :key="r.id" :request="r" show-applicant />
      </div>
    </template>
  </div>
</template>
