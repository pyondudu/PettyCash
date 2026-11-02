<script setup>
import { computed, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { supabase } from '../lib/supabase'
import { store, errText } from '../lib/store'
import { MAX_AMOUNT, validateAmount, normalizeAmount, fmtMoney, fmtDate, todayTaipei } from '../lib/petty'
import { BUCKET, uuid, signedUrls } from '../lib/photos'
import { voucherError, duplicateWarning, uploadVouchers, removeUploaded, releaseVouchers } from '../lib/vouchers'
import VoucherEditor from '../components/VoucherEditor.vue'

const route = useRoute()
const router = useRouter()

const form = reactive({ fill_date: todayTaipei(), reason: '', amount: '', note: '' })
const vouchers = ref([])        // 這次新加、還沒上傳的憑證
const saved = ref([])           // 草稿裡已儲存的憑證
const removed = ref([])         // 要從草稿移除的已存憑證
const photoUrls = ref({})
const draftId = ref(null)       // 正在編輯的草稿；新申請為 null
const busy = ref(false)
const progress = ref('')
const msg = ref('')
const ok = ref('')
const done = ref(null)          // 送出成功的申請
const tried = ref(false)

const amountError = computed(() => (form.amount === '' && !tried.value ? null : validateAmount(form.amount)))
const amountPreview = computed(() => {
  const n = normalizeAmount(form.amount)
  return n !== null && !amountError.value ? `$${fmtMoney(n)}` : ''
})
const keptSaved = computed(() => saved.value.filter((v) => !removed.value.includes(v.id)))

function reset() {
  releaseVouchers(vouchers.value)
  vouchers.value = []
  saved.value = []
  removed.value = []
  photoUrls.value = {}
  draftId.value = null
  Object.assign(form, { fill_date: todayTaipei(), reason: '', amount: '', note: '' })
  tried.value = false
  msg.value = ok.value = ''
}

// 從「我的申請」按「編輯」進來：/apply?draft=<id>
async function loadDraft(id) {
  reset()
  if (!id) return
  const { data, error } = await supabase.from('petty_requests').select('*, petty_vouchers(*)').eq('id', id).maybeSingle()
  if (error || !data || data.status !== 'draft') {
    msg.value = error ? '讀取失敗：' + errText(error) : '找不到這筆草稿，可能已經送出或刪除。'
    return
  }
  draftId.value = data.id
  Object.assign(form, { fill_date: data.fill_date, reason: data.reason ?? '', amount: data.amount ? String(data.amount) : '', note: data.note ?? '' })
  saved.value = [...data.petty_vouchers].sort((a, b) => a.id - b.id)
  try { photoUrls.value = await signedUrls(saved.value.map((v) => v.photo_path)) } catch { /* 照片顯示失敗不影響編輯 */ }
}
watch(() => route.query.draft, (id) => loadDraft(id), { immediate: true })

// 儲存草稿（送出前也會先存）；回傳申請 id
async function saveDraft() {
  if (form.amount !== '' && validateAmount(form.amount)) throw new Error(validateAmount(form.amount))
  if (vouchers.value.some(voucherError)) throw new Error('請檢查憑證：每張都要有照片、日期和金額')
  const id = draftId.value ?? uuid()
  let uploaded = []
  try {
    const up = await uploadVouchers(id, vouchers.value, (t) => (progress.value = t))
    uploaded = up.uploaded
    progress.value = '儲存…'
    const removedPaths = saved.value.filter((v) => removed.value.includes(v.id)).map((v) => v.photo_path)
    const { error } = await supabase.rpc('petty_save_draft', {
      p: {
        id, fill_date: form.fill_date, reason: form.reason, amount: form.amount === '' ? null : normalizeAmount(form.amount),
        note: form.note, vouchers: up.items, remove_voucher_ids: removed.value,
      },
    })
    if (error) throw error
    if (removedPaths.length) await supabase.storage.from(BUCKET).remove(removedPaths)
  } catch (e) {
    await removeUploaded(uploaded)
    throw e
  }
  draftId.value = id
  return id
}

async function save() {
  msg.value = ok.value = ''
  busy.value = true
  try {
    const id = await saveDraft()
    if (route.query.draft !== id) await router.replace({ path: '/apply', query: { draft: id } })
    else await loadDraft(id)
    ok.value = '已儲存。還沒送出，主管看不到；內容確定後再按「送出申請」。'
  } catch (e) {
    msg.value = '儲存失敗：' + errText(e)
  } finally {
    busy.value = false
    progress.value = ''
  }
}

async function submit() {
  tried.value = true
  msg.value = ok.value = ''
  if (!form.fill_date || !form.reason.trim() || validateAmount(form.amount)) {
    msg.value = validateAmount(form.amount) || '請填寫必填欄位'
    return
  }
  if (vouchers.value.some(voucherError)) { msg.value = '請檢查憑證：每張都要有照片、日期和金額'; return }

  busy.value = true
  let savedId = null
  try {
    progress.value = '檢查重複憑證…'
    const all = [...keptSaved.value.map((v) => ({ date: v.voucher_date, amount: v.amount })), ...vouchers.value]
    const warn = await duplicateWarning(all)
    if (warn && !confirm(warn)) return
    const id = await saveDraft()
    savedId = id
    progress.value = '送出申請…'
    const { data, error } = await supabase.rpc('petty_submit_draft', { p_id: id })
    if (error) throw error
    const count = keptSaved.value.length + vouchers.value.length
    reset()
    done.value = { ...data, voucherCount: count }
    if (route.query.draft) router.replace({ path: '/apply' })
  } catch (e) {
    // 已經存成草稿但送出失敗：重新讀取草稿，避免再按一次時重複上傳照片
    if (savedId) {
      if (route.query.draft !== savedId) await router.replace({ path: '/apply', query: { draft: savedId } })
      else await loadDraft(savedId)
      msg.value = '已儲存為草稿，但送出失敗：' + errText(e)
    } else {
      msg.value = '送出失敗：' + errText(e)
    }
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
    <h2>{{ draftId ? '零用金申請（草稿）' : '零用金申請' }}</h2>
    <p v-if="draftId" class="muted small">這筆還沒送出，主管看不到。可以繼續修改，確定後按「送出申請」。</p>
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
      <div v-if="keptSaved.length" class="saved-vouchers">
        <h3>已儲存的憑證（{{ keptSaved.length }} 張）</h3>
        <ul class="voucher-edit">
          <li v-for="v in keptSaved" :key="v.id">
            <img v-if="photoUrls[v.photo_path]" :src="photoUrls[v.photo_path]" alt="" />
            <span>{{ fmtDate(v.voucher_date) }}<br /><strong>${{ fmtMoney(v.amount) }}</strong></span>
            <span class="spacer" />
            <button type="button" class="btn ghost small danger" @click="removed = [...removed, v.id]">刪除</button>
          </li>
        </ul>
      </div>
      <VoucherEditor v-model="vouchers" :tried="tried" :title="keptSaved.length ? '再加憑證' : '憑證（選填）'">
        <template #hint>
          <p class="muted small">
            還沒有收據可以先送出，之後在「我的申請」按「補憑證」。
            每張憑證都要有照片、日期、金額。
          </p>
        </template>
      </VoucherEditor>
    </fieldset>

    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="ok" class="msg success">{{ ok }}</p>
    <div class="form-actions">
      <span v-if="progress" class="muted">{{ progress }}</span>
      <button type="button" class="btn" :disabled="busy" @click="save">儲存</button>
      <button class="btn primary" :disabled="busy">{{ busy ? '處理中…' : '送出申請' }}</button>
    </div>
  </form>
</template>
