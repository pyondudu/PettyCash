<script setup>
import { computed, reactive, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { store, errText } from '../lib/store'
import {
  MAX_AMOUNT, validateAmount, normalizeAmount, normalizeDate, fmtDate, fmtMoney, todayTaipei,
  voucherKey, findLocalDuplicates, voucherPairs,
} from '../lib/petty'
import { BUCKET, compressImage, uuid } from '../lib/photos'

const form = reactive({ fill_date: todayTaipei(), reason: '', amount: '', note: '' })
// 每張憑證：{ key, file, preview, date, amount }
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
const voucherTotal = computed(() => vouchers.value.reduce((s, v) => s + (normalizeAmount(v.amount) ?? 0), 0))

function voucherError(v) {
  if (!v.file) return '請附照片'
  if (!normalizeDate(v.date)) return '日期格式不正確'
  const a = normalizeAmount(v.amount)
  if (a === null || a <= 0) return '請填憑證金額'
  return null
}

function addPhotos(e) {
  for (const file of e.target.files) {
    vouchers.value.push({ key: uuid(), file, preview: URL.createObjectURL(file), date: '', amount: '' })
  }
  e.target.value = ''
}

function removeVoucher(i) {
  URL.revokeObjectURL(vouchers.value[i].preview)
  vouchers.value.splice(i, 1)
}

function reset() {
  vouchers.value.forEach((v) => URL.revokeObjectURL(v.preview))
  vouchers.value = []
  Object.assign(form, { fill_date: todayTaipei(), reason: '', amount: '', note: '' })
  tried.value = false
  msg.value = ''
}

// 重複提示：同一筆裡重複，或和其他未退回的申請相同（日期＋憑證金額）
async function duplicateWarning() {
  const local = findLocalDuplicates(vouchers.value)
  const { data, error } = await supabase.rpc('petty_duplicate_vouchers', { pairs: voucherPairs(vouchers.value) })
  if (error) throw error
  const remote = (data ?? []).map((d) => voucherKey(d.dup_date, d.dup_amount))
  const lines = [
    ...local.map((k) => `・${fmtDate(k.split('|')[0])} $${fmtMoney(k.split('|')[1])}：這次申請裡有兩張相同`),
    ...remote.map((k) => `・${fmtDate(k.split('|')[0])} $${fmtMoney(k.split('|')[1])}：已經出現在其他申請`),
  ]
  return lines.length ? `下列憑證的日期和金額重複：\n${lines.join('\n')}\n\n確定仍要送出嗎？` : null
}

async function submit() {
  tried.value = true
  msg.value = ''
  if (!form.fill_date || !form.reason.trim() || validateAmount(form.amount)) {
    msg.value = validateAmount(form.amount) || '請填寫必填欄位'
    return
  }
  if (!vouchers.value.length) { msg.value = '至少要附一張憑證'; return }
  if (vouchers.value.some(voucherError)) { msg.value = '請檢查憑證：每張都要有照片、日期和金額'; return }

  busy.value = true
  const id = uuid()
  const uploaded = []
  try {
    progress.value = '檢查重複憑證…'
    const warn = await duplicateWarning()
    if (warn && !confirm(warn)) return

    const items = []
    for (const [i, v] of vouchers.value.entries()) {
      progress.value = `上傳照片 ${i + 1}／${vouchers.value.length}…`
      const blob = await compressImage(v.file)
      const path = `${store.uid}/${id}/${i + 1}.jpg`
      const { error } = await supabase.storage.from(BUCKET).upload(path, blob, { contentType: 'image/jpeg' })
      if (error) throw error
      uploaded.push(path)
      items.push({ date: normalizeDate(v.date), amount: normalizeAmount(v.amount), photo_path: path })
    }

    progress.value = '送出申請…'
    const { data, error } = await supabase.rpc('petty_submit', {
      p: { id, fill_date: form.fill_date, reason: form.reason, amount: normalizeAmount(form.amount), note: form.note, vouchers: items },
    })
    if (error) throw error
    done.value = data
    reset()
  } catch (e) {
    msg.value = '送出失敗：' + errText(e)
    // 申請沒建立成功時，刪掉剛上傳的照片
    if (uploaded.length) await supabase.storage.from(BUCKET).remove(uploaded)
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
      <div class="section-head">
        <h3>憑證（{{ vouchers.length }} 張，合計 ${{ fmtMoney(voucherTotal) }}）</h3>
        <label class="btn small primary file-btn">
          ＋ 加照片
          <input type="file" accept="image/*" multiple @change="addPhotos" />
        </label>
      </div>
      <p class="muted small">每張憑證都要有照片、日期、金額。日期可寫 2026/9/30 或 115/9/30。</p>
      <p v-if="!vouchers.length" class="muted center empty-small">還沒有憑證，請按「加照片」拍照或選擇照片。</p>
      <ul class="voucher-edit">
        <li v-for="(v, i) in vouchers" :key="v.key" :class="{ bad: tried && voucherError(v) }">
          <img :src="v.preview" alt="" />
          <div class="voucher-fields">
            <label>憑證日期*<input v-model="v.date" type="text" inputmode="numeric" placeholder="115/9/30" /></label>
            <label>憑證金額*<input v-model="v.amount" type="text" inputmode="decimal" placeholder="500" /></label>
            <span v-if="tried && voucherError(v)" class="field-msg">{{ voucherError(v) }}</span>
            <span v-else-if="normalizeDate(v.date)" class="field-hint">{{ fmtDate(normalizeDate(v.date)) }}</span>
          </div>
          <button type="button" class="btn ghost small danger" @click="removeVoucher(i)">刪除</button>
        </li>
      </ul>
    </fieldset>

    <p v-if="msg" class="msg error">{{ msg }}</p>
    <div class="form-actions">
      <span v-if="progress" class="muted">{{ progress }}</span>
      <button class="btn primary" :disabled="busy">{{ busy ? '送出中…' : '送出申請' }}</button>
    </div>
  </form>
</template>
