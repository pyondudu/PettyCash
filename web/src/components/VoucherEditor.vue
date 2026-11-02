<script setup>
import { computed, ref } from 'vue'
import { normalizeAmount, fmtMoney, todayTaipei } from '../lib/petty'
import { newVoucher, voucherError } from '../lib/vouchers'
import { detectCorners, warp } from '../lib/scanner'
import { loadImage, canvasToBlob, releaseCanvas } from '../lib/scanImage'
import CornerEditor from './CornerEditor.vue'

// v-model：編輯中的憑證陣列；tried = 按過送出後才顯示錯誤
const list = defineModel({ type: Array, required: true })
defineProps({ tried: { type: Boolean, default: false }, title: { type: String, default: '憑證' } })

const today = todayTaipei()
const total = computed(() => list.value.reduce((s, v) => s + (normalizeAmount(v.amount) ?? 0), 0))

// 加照片：每張先自動偵測憑證四角，用綠框讓使用者微調，拉平後存成 JPG
const busy = ref('')
const note = ref('')
const editing = ref(null)   // { source, corners, label, resolve }

function askCorners(source, corners, label) {
  return new Promise((resolve) => { editing.value = { source, corners, label, resolve } })
}
function cornersDone(result) {
  const r = editing.value.resolve
  editing.value = null
  r(result)
}

async function addPhotos(e) {
  const files = [...e.target.files]
  e.target.value = ''
  note.value = ''
  for (const [i, file] of files.entries()) {
    const label = files.length > 1 ? `第 ${i + 1}／${files.length} 張` : ''
    let source = null
    try {
      busy.value = `讀取照片${label ? '（' + label + '）' : ''}…`
      source = await loadImage(file)
      busy.value = '偵測憑證邊緣…（第一次要下載影像處理模組，約需數秒）'
      const detected = await detectCorners(source)
      busy.value = ''
      const corners = await askCorners(source, detected, label)
      if (!corners) continue
      busy.value = '拉平照片…'
      const out = await warp(source, corners)
      const blob = await canvasToBlob(out)
      releaseCanvas(out)
      list.value = [...list.value, newVoucher(new File([blob], 'voucher.jpg', { type: 'image/jpeg' }))]
    } catch (err) {
      // 影像處理失敗（例如沒網路載不到模組）時，直接用原圖
      list.value = [...list.value, newVoucher(file)]
      note.value = `有照片無法自動裁切，已使用原圖：${err.message}`
    } finally {
      if (source) releaseCanvas(source)
      busy.value = ''
    }
  }
}

function remove(i) {
  URL.revokeObjectURL(list.value[i].preview)
  list.value = list.value.filter((_, j) => j !== i)
}
</script>

<template>
  <div class="voucher-editor">
    <div class="section-head">
      <h3>{{ title }}（{{ list.length }} 張，合計 ${{ fmtMoney(total) }}）</h3>
      <div class="photo-btns">
        <!-- 拍照：手機直接開後鏡頭；選照片：從相簿挑，可多選 -->
        <label class="btn small primary file-btn">
          拍照
          <input type="file" accept="image/*" capture="environment" :disabled="!!busy || !!editing" @change="addPhotos" />
        </label>
        <label class="btn small file-btn file-btn-alt">
          選照片
          <input type="file" accept="image/*" multiple :disabled="!!busy || !!editing" @change="addPhotos" />
        </label>
      </div>
    </div>
    <slot name="hint" />
    <p v-if="busy" class="msg">{{ busy }}</p>
    <p v-if="note" class="msg error">{{ note }}</p>
    <CornerEditor v-if="editing" :source="editing.source" :corners="editing.corners" :label="editing.label" @done="cornersDone" />
    <ul class="voucher-edit">
      <li v-for="(v, i) in list" :key="v.key" :class="{ bad: tried && voucherError(v) }">
        <img :src="v.preview" alt="" />
        <div class="voucher-fields">
          <label>憑證日期*<input v-model="v.date" type="date" :max="today" /></label>
          <label>憑證金額*<input v-model="v.amount" type="text" inputmode="decimal" placeholder="500" /></label>
          <span v-if="tried && voucherError(v)" class="field-msg">{{ voucherError(v) }}</span>
        </div>
        <button type="button" class="btn ghost small danger" @click="remove(i)">刪除</button>
      </li>
    </ul>
  </div>
</template>
