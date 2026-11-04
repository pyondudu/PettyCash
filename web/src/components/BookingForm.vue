<script setup>
import { computed, reactive, ref, watch } from 'vue'
import { supabase } from '../lib/supabase'
import { errText } from '../lib/store'
import { NO_RECEIPT_NO, bookingMissing, fmtDate, fmtMoney } from '../lib/petty'
import AddVouchers from './AddVouchers.vue'

// 管理頁「已核准」分頁未登記的卡片下方：由管理者填類別、領收人、各憑證收據號碼（登記時寫入 Google 試算表）
const props = defineProps({
  request: { type: Object, required: true },
  categories: { type: Array, default: () => [] },
})
const emit = defineEmits(['saved'])

const vouchers = computed(() => [...(props.request.petty_vouchers ?? [])].sort((a, b) => a.id - b.id))
const form = reactive({ category: '', payee_name: '', receipts: {} })
const busy = ref(false)
const msg = ref('')
const ok = ref('')
const adding = ref(false)   // 管理者替申請人補憑證

function reset() {
  const r = props.request
  form.category = r.category ?? ''
  form.payee_name = r.payee_name ?? r.applicant_name ?? ''
  form.receipts = Object.fromEntries(vouchers.value.map((v) => [v.id, v.receipt_no ?? '']))
}
// 同一筆重新讀取（例如補了憑證）時，保留還沒儲存的輸入，只補上新憑證的欄位
watch(() => props.request, (r, old) => {
  if (!old || old.id !== r.id) return reset()
  for (const v of vouchers.value) if (!(v.id in form.receipts)) form.receipts[v.id] = v.receipt_no ?? ''
}, { immediate: true })

function vouchersSaved() {
  adding.value = false
  emit('saved')
}

const saved = computed(() => {
  const r = props.request
  return (r.category ?? '') === form.category.trim()
    && (r.payee_name ?? '') === form.payee_name.trim()
    && vouchers.value.every((v) => (v.receipt_no ?? '') === (form.receipts[v.id] ?? '').trim())
})
const missing = computed(() => bookingMissing(props.request, form))
// 設定裡已刪掉、但這筆已選的舊類別仍要顯示
const options = computed(() => form.category && !props.categories.includes(form.category)
  ? [form.category, ...props.categories] : props.categories)

async function save() {
  msg.value = ok.value = ''
  busy.value = true
  const { error } = await supabase.rpc('petty_save_booking', {
    p_request_id: props.request.id,
    p_category: form.category,
    p_payee: form.payee_name,
    p_receipts: vouchers.value.map((v) => ({ id: v.id, receipt_no: form.receipts[v.id] ?? '' })),
  })
  busy.value = false
  if (error) { msg.value = '儲存失敗：' + errText(error); return }
  ok.value = '已儲存'
  emit('saved')
}
</script>

<template>
  <div class="booking">
  <form class="booking-form" @submit.prevent="save">
    <div class="booking-title">登記資料<span class="muted small">（寫入試算表用，可在列印前或核發後填）</span></div>
    <div class="booking-row">
      <label>類別
        <select v-model="form.category">
          <option value="">請選擇</option>
          <option v-for="c in options" :key="c" :value="c">{{ c }}</option>
        </select>
      </label>
      <label>領收人<input v-model="form.payee_name" /></label>
    </div>
    <div v-for="(v, i) in vouchers" :key="v.id" class="booking-receipt">
      <span class="muted small">憑證 {{ i + 1 }}：{{ fmtDate(v.voucher_date) }}　${{ fmtMoney(v.amount) }}</span>
      <input v-model="form.receipts[v.id]" placeholder="收據／發票號碼" />
      <button type="button" class="btn small ghost" @click="form.receipts[v.id] = NO_RECEIPT_NO">無號碼</button>
    </div>
    <div class="booking-foot">
      <span v-if="missing.length" class="muted small">還缺：{{ missing.join('、') }}</span>
      <span v-else-if="!saved" class="muted small">已填完，記得儲存</span>
      <span v-else class="small ok-text">登記資料已完成</span>
      <span class="spacer" />
      <span v-if="msg" class="small error-text">{{ msg }}</span>
      <span v-else-if="ok && saved" class="small ok-text">{{ ok }}</span>
      <button class="btn small" :class="{ primary: !saved }" :disabled="busy || saved">儲存</button>
    </div>
  </form>
  <AddVouchers v-if="adding" :request="request" @saved="vouchersSaved" @cancel="adding = false" />
  <button v-else type="button" class="btn small ghost booking-add" @click="adding = true">＋ 替申請人補憑證</button>
  </div>
</template>
