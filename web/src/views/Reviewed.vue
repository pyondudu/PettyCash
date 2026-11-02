<script setup>
import { computed, onMounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { errText } from '../lib/store'
import { fmtMoney } from '../lib/petty'
import RequestCard from '../components/RequestCard.vue'

// 審核紀錄（主管）：列出所有已核准、已退回的申請，可依月份、結果、申請人篩選
const rows = ref([])
const loading = ref(true)
const msg = ref('')
const filter = ref({ month: '', result: '', name: '' })

async function load() {
  loading.value = true
  const { data, error } = await supabase.from('petty_requests').select('*, petty_vouchers(*)')
    .or('approved_at.not.is.null,status.eq.rejected')
    .order('fill_date', { ascending: false }).order('submitted_at', { ascending: false })
  loading.value = false
  if (error) msg.value = '讀取失敗：' + errText(error)
  rows.value = data ?? []
}

// 已核准＝主管核准過（之後可能已核發、已登記，或被管理者取消）；已退回＝主管退回
const isApproved = (r) => !!r.approved_at
const monthOptions = computed(() => [...new Set(rows.value.map((r) => r.fill_date?.slice(0, 7)).filter(Boolean))].sort().reverse())
const nameOptions = computed(() => [...new Set(rows.value.map((r) => r.applicant_name))].sort((a, b) => a.localeCompare(b, 'zh-Hant')))
const list = computed(() => rows.value.filter((r) =>
  (!filter.value.month || r.fill_date?.startsWith(filter.value.month)) &&
  (!filter.value.name || r.applicant_name === filter.value.name) &&
  (!filter.value.result || (filter.value.result === 'approved' ? isApproved(r) : r.status === 'rejected'))))
const total = computed(() => list.value.reduce((s, r) => s + Number(r.amount ?? 0), 0))
const filterOn = computed(() => !!(filter.value.month || filter.value.result || filter.value.name))
function clearFilter() { filter.value = { month: '', result: '', name: '' } }

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>審核紀錄</h2>
    </div>
    <div class="filter-bar">
      <label class="inline">月份
        <select v-model="filter.month">
          <option value="">全部月份</option>
          <option v-for="m in monthOptions" :key="m" :value="m">{{ m.replace('-', '/') }}</option>
        </select>
      </label>
      <label class="inline">結果
        <select v-model="filter.result">
          <option value="">全部</option>
          <option value="approved">已核准</option>
          <option value="rejected">已退回</option>
        </select>
      </label>
      <label class="inline">申請人
        <select v-model="filter.name">
          <option value="">全部人</option>
          <option v-for="n in nameOptions" :key="n" :value="n">{{ n }}</option>
        </select>
      </label>
      <button v-if="filterOn" class="btn small ghost" @click="clearFilter">清除篩選</button>
      <span class="spacer" />
      <span class="muted small">{{ list.length }} 筆，合計 ${{ fmtMoney(total) }}</span>
    </div>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="loading" class="muted">載入中…</p>
    <p v-else-if="!list.length" class="muted center empty">{{ filterOn ? '沒有符合篩選條件的申請。' : '還沒有審核過的申請。' }}</p>
    <div class="list">
      <RequestCard v-for="r in list" :key="r.id" :request="r" show-applicant />
    </div>
  </div>
</template>
