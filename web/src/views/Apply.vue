<script setup>
import { computed, reactive, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { store, errText } from '../lib/store'
import { MAX_AMOUNT, validateAmount, normalizeAmount, fmtMoney, todayTaipei } from '../lib/petty'
import { uuid } from '../lib/photos'
import { voucherError, duplicateWarning, uploadVouchers, removeUploaded, releaseVouchers } from '../lib/vouchers'
import VoucherEditor from '../components/VoucherEditor.vue'

const form = reactive({ fill_date: todayTaipei(), reason: '', amount: '', note: '' })
const vouchers = ref([])
const busy = ref(false)
const progress = ref('')
const msg = ref('')
const done = ref(null)  // 送出成功的申請
const tried = ref(false)

const amountError = computed(() => (form.amount === '' && !tried.value ? null : validateAmount(form.amount)))
const amountPreview = computed(() => {
  const n = normalizeAmount(form.amount)
  return n !== null && !amountError.value ? `$${fmtMoney(n)}` : ''
})

function reset() {
  releaseVouchers(vouchers.value)
  vouchers.value = []
  Object.assign(form, { fill_date: todayTaipei(), reason: '', amount: '', note: '' })
  tried.value = false
  msg.value = ''
}

async function submit() {
  tried.value = true
  msg.value = ''
  if (!form.fill_date || !form.reason.trim() || validateAmount(form.amount)) {
    msg.value = validateAmount(form.amount) || '請填寫必填欄位'
    return
  }
  if (vouchers.value.some(voucherError)) { msg.value = '請檢查憑證：每張都要有照片、日期和金額'; return }

  busy.value = true
  const id = uuid()
  let uploaded = []
  try {
    progress.value = '檢查重複憑證…'
    const warn = await duplicateWarning(vouchers.value)
    if (warn && !confirm(warn)) return

    const up = await uploadVouchers(id, vouchers.value, (t) => (progress.value = t))
    uploaded = up.uploaded

    progress.value = '送出申請…'
    const { data, error } = await supabase.rpc('petty_submit', {
      p: { id, fill_date: form.fill_date, reason: form.reason, amount: normalizeAmount(form.amount), note: form.note, vouchers: up.items },
    })
    if (error) throw error
    done.value = { ...data, voucherCount: up.items.length }
    reset()
  } catch (e) {
    msg.value = '送出失敗：' + errText(e)
    await removeUploaded(uploaded)
  } finally {
    busy.value = false
    progress.value = ''
  }
}
</script>

<template>
  <div v-if="done" class="card center done-box">
    <h2>已送出</h2>
    <p>申請編號 <strong>{{ done.request_no }}</strong>，金額 ${{ fmtMoney(done.amount) }}</p>
    <p class="muted">等待主管核准，可以在「我的申請」查看進度。</p>
    <p v-if="!done.voucherCount" class="muted">這次沒有附憑證，有收據後請到「我的申請」按「補憑證」。</p>
    <div class="form-actions center-actions">
      <router-link to="/mine" class="btn">我的申請</router-link>
      <button class="btn primary" @click="done = null">再填一筆</button>
    </div>
  </div>

  <form v-else class="form" @submit.prevent="submit">
    <h2>零用金申請</h2>
    <fieldset class="card">
      <div class="grid">
        <label>申請人<input :value="store.member.name" disabled /></label>
        <label>申請單位<input :value="store.member.unit || '—'" disabled /></label>
        <label :class="{ invalid: tried && !form.fill_date }">填寫日期*<input v-model="form.fill_date" type="date" /></label>
        <label :class="{ invalid: !!amountError }">
          申請金額*（上限 ${{ fmtMoney(MAX_AMOUNT) }}）
          <input v-model="form.amount" type="text" inputmode="numeric" placeholder="例：1,200" />
          <span v-if="amountError" class="field-msg">{{ amountError }}</span>
          <span v-else-if="amountPreview" class="field-hint">{{ amountPreview }}</span>
        </label>
        <label class="span2" :class="{ invalid: tried && !form.reason.trim() }">申請事由*<textarea v-model="form.reason" rows="3" /></label>
        <label class="span2">備註<textarea v-model="form.note" rows="2" /></label>
      </div>
    </fieldset>

    <fieldset class="card">
      <VoucherEditor v-model="vouchers" :tried="tried" title="憑證（選填）">
        <template #hint>
          <p class="muted small">
            還沒有收據可以先送出，之後在「我的申請」按「補憑證」。
            每張憑證都要有照片、日期、金額，日期可寫 2026/9/30 或 115/9/30。
          </p>
        </template>
      </VoucherEditor>
    </fieldset>

    <p v-if="msg" class="msg error">{{ msg }}</p>
    <div class="form-actions">
      <span v-if="progress" class="muted">{{ progress }}</span>
      <button class="btn primary" :disabled="busy">{{ busy ? '送出中…' : '送出申請' }}</button>
    </div>
  </form>
</template>
