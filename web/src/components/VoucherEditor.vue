<script setup>
import { computed } from 'vue'
import { normalizeAmount, normalizeDate, fmtDate, fmtMoney } from '../lib/petty'
import { newVoucher, voucherError } from '../lib/vouchers'

// v-model：編輯中的憑證陣列；tried = 按過送出後才顯示錯誤
const list = defineModel({ type: Array, required: true })
defineProps({ tried: { type: Boolean, default: false }, title: { type: String, default: '憑證' } })

const total = computed(() => list.value.reduce((s, v) => s + (normalizeAmount(v.amount) ?? 0), 0))

function addPhotos(e) {
  list.value = [...list.value, ...[...e.target.files].map(newVoucher)]
  e.target.value = ''
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
      <label class="btn small primary file-btn">
        ＋ 加照片
        <input type="file" accept="image/*" multiple @change="addPhotos" />
      </label>
    </div>
    <slot name="hint" />
    <ul class="voucher-edit">
      <li v-for="(v, i) in list" :key="v.key" :class="{ bad: tried && voucherError(v) }">
        <img :src="v.preview" alt="" />
        <div class="voucher-fields">
          <label>憑證日期*<input v-model="v.date" type="text" inputmode="numeric" placeholder="115/9/30" /></label>
          <label>憑證金額*<input v-model="v.amount" type="text" inputmode="decimal" placeholder="500" /></label>
          <span v-if="tried && voucherError(v)" class="field-msg">{{ voucherError(v) }}</span>
          <span v-else-if="normalizeDate(v.date)" class="field-hint">{{ fmtDate(normalizeDate(v.date)) }}</span>
        </div>
        <button type="button" class="btn ghost small danger" @click="remove(i)">刪除</button>
      </li>
    </ul>
  </div>
</template>
