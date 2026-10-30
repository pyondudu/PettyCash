<script setup>
import { onMounted, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { store, errText } from '../lib/store'
import { canAddVouchers } from '../lib/petty'
import { voucherError, duplicateWarning, uploadVouchers, removeUploaded, releaseVouchers } from '../lib/vouchers'
import RequestCard from '../components/RequestCard.vue'
import VoucherEditor from '../components/VoucherEditor.vue'

const rows = ref([])
const loading = ref(true)
const msg = ref('')
// 補憑證
const adding = ref(null)    // 正在補憑證的申請 id
const list = ref([])
const tried = ref(false)
const busy = ref(false)
const progress = ref('')
const addMsg = ref('')

async function load() {
  loading.value = true
  const { data, error } = await supabase.from('petty_requests').select('*, petty_vouchers(*)')
    .eq('applicant_id', store.uid).order('submitted_at', { ascending: false })
  loading.value = false
  if (error) msg.value = '讀取失敗：' + errText(error)
  else rows.value = data
}

function startAdding(r) {
  closeAdding()
  adding.value = r.id
}

function closeAdding() {
  releaseVouchers(list.value)
  list.value = []
  tried.value = false
  addMsg.value = ''
  adding.value = null
}

async function saveVouchers(r) {
  tried.value = true
  addMsg.value = ''
  if (!list.value.length) { addMsg.value = '請先加照片'; return }
  if (list.value.some(voucherError)) { addMsg.value = '每張憑證都要有照片、日期和金額'; return }
  busy.value = true
  let uploaded = []
  try {
    progress.value = '檢查重複憑證…'
    const warn = await duplicateWarning(list.value)
    if (warn && !confirm(warn)) return
    const up = await uploadVouchers(r.id, list.value, (t) => (progress.value = t))
    uploaded = up.uploaded
    progress.value = '儲存…'
    const { error } = await supabase.rpc('petty_add_vouchers', { p_request_id: r.id, p_vouchers: up.items })
    if (error) throw error
    closeAdding()
    await load()
  } catch (e) {
    addMsg.value = '補憑證失敗：' + errText(e)
    await removeUploaded(uploaded)
  } finally {
    busy.value = false
    progress.value = ''
  }
}

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>我的申請</h2>
      <button class="btn small" @click="load">重新整理</button>
    </div>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="loading" class="muted">載入中…</p>
    <p v-else-if="!rows.length" class="muted center empty">還沒有申請。</p>
    <div class="list">
      <RequestCard v-for="r in rows" :key="r.id" :request="r">
        <template #actions>
          <button v-if="canAddVouchers(r) && adding !== r.id" class="btn small" @click="startAdding(r)">
            補憑證<span v-if="!r.petty_vouchers.length" class="badge">!</span>
          </button>
        </template>
        <template v-if="adding === r.id" #extra>
          <div class="add-vouchers">
            <VoucherEditor v-model="list" :tried="tried" title="補憑證" />
            <p v-if="addMsg" class="msg error">{{ addMsg }}</p>
            <div class="form-actions">
              <span v-if="progress" class="muted">{{ progress }}</span>
              <button class="btn small ghost" :disabled="busy" @click="closeAdding">取消</button>
              <button class="btn small primary" :disabled="busy" @click="saveVouchers(r)">{{ busy ? '儲存中…' : '儲存憑證' }}</button>
            </div>
          </div>
        </template>
      </RequestCard>
    </div>
  </div>
</template>
