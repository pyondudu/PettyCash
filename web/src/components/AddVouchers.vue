<script setup>
import { onBeforeUnmount, ref } from 'vue'
import { supabase } from '../lib/supabase'
import { errText } from '../lib/store'
import { voucherError, duplicateWarning, uploadVouchers, removeUploaded, releaseVouchers } from '../lib/vouchers'
import VoucherEditor from './VoucherEditor.vue'

// 補憑證：申請人在「我的申請」補自己的；管理者在登記資料區塊替申請人補
const props = defineProps({ request: { type: Object, required: true } })
const emit = defineEmits(['saved', 'cancel'])

const list = ref([])
const tried = ref(false)
const busy = ref(false)
const progress = ref('')
const msg = ref('')

onBeforeUnmount(() => releaseVouchers(list.value))

async function save() {
  tried.value = true
  msg.value = ''
  if (!list.value.length) { msg.value = '請先加照片'; return }
  if (list.value.some(voucherError)) { msg.value = '每張憑證都要有照片、日期和金額'; return }
  busy.value = true
  let uploaded = []
  try {
    progress.value = '檢查重複憑證…'
    const warn = await duplicateWarning(list.value)
    if (warn && !confirm(warn)) return
    const up = await uploadVouchers(props.request.id, list.value, (t) => (progress.value = t))
    uploaded = up.uploaded
    progress.value = '儲存…'
    const { error } = await supabase.rpc('petty_add_vouchers', { p_request_id: props.request.id, p_vouchers: up.items })
    if (error) throw error
    uploaded = []
    emit('saved')
  } catch (e) {
    msg.value = '補憑證失敗：' + errText(e)
    await removeUploaded(uploaded)
  } finally {
    busy.value = false
    progress.value = ''
  }
}
</script>

<template>
  <div class="add-vouchers">
    <VoucherEditor v-model="list" :tried="tried" title="補憑證" />
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <div class="form-actions">
      <span v-if="progress" class="muted">{{ progress }}</span>
      <button type="button" class="btn small ghost" :disabled="busy" @click="emit('cancel')">取消</button>
      <button type="button" class="btn small primary" :disabled="busy" @click="save">{{ busy ? '儲存中…' : '儲存憑證' }}</button>
    </div>
  </div>
</template>
