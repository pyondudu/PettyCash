<script setup>
import { computed, ref, watch } from 'vue'
import { STATUS, fmtDate, fmtMoney, fmtTaipei, approvedText, submittedText } from '../lib/petty'
import { signedUrls } from '../lib/photos'

// request 需含 petty_vouchers（select('*, petty_vouchers(*)')）
const props = defineProps({
  request: { type: Object, required: true },
  showApplicant: { type: Boolean, default: false },
  open: { type: Boolean, default: false },
})

const expanded = ref(props.open)
const urls = ref({})
const lightbox = ref(null)
const photoError = ref('')

const vouchers = computed(() => [...(props.request.petty_vouchers ?? [])].sort((a, b) => a.id - b.id))
const voucherTotal = computed(() => vouchers.value.reduce((s, v) => s + Number(v.amount), 0))

async function loadPhotos() {
  if (props.request.archived_at || Object.keys(urls.value).length) return
  try {
    urls.value = await signedUrls(vouchers.value.map((v) => v.photo_path))
  } catch (e) {
    photoError.value = '照片載入失敗：' + e.message
  }
}

watch(expanded, (v) => { if (v) loadPhotos() }, { immediate: true })
</script>

<template>
  <article class="req card" :class="'st-' + request.status">
    <header class="req-head" @click="expanded = !expanded">
      <div class="req-title">
        <span class="pill" :class="request.status">{{ STATUS[request.status].label }}</span>
        <strong>{{ request.request_no }}</strong>
        <span v-if="showApplicant">{{ request.applicant_name }}<span v-if="request.applicant_unit" class="muted">（{{ request.applicant_unit }}）</span></span>
      </div>
      <div class="req-amount">${{ fmtMoney(request.amount) }}</div>
    </header>
    <p class="req-reason" @click="expanded = !expanded">{{ request.reason }}</p>
    <p v-if="request.reject_reason && ['rejected', 'returned'].includes(request.status)" class="reject">
      退回原因：{{ request.reject_reason }}
    </p>

    <div v-if="expanded" class="req-body">
      <dl class="kv">
        <dt>填寫日期</dt><dd>{{ fmtDate(request.fill_date) }}</dd>
        <template v-if="request.note"><dt>備註</dt><dd class="pre">{{ request.note }}</dd></template>
        <dt>送出</dt><dd>{{ submittedText(request.applicant_name, request.submitted_at) }}</dd>
        <template v-if="request.approved_at"><dt>核准</dt><dd>{{ approvedText(request.approver_name, request.approved_at) }}</dd></template>
        <template v-if="request.status === 'rejected'"><dt>退回</dt><dd>{{ request.approver_name }} 於 {{ fmtTaipei(request.rejected_at) }}</dd></template>
        <template v-if="request.status === 'returned'"><dt>退回</dt><dd>{{ fmtTaipei(request.rejected_at) }}</dd></template>
        <template v-if="request.disbursed_date"><dt>核發日期</dt><dd>{{ fmtDate(request.disbursed_date) }}</dd></template>
        <template v-if="request.printed_at"><dt>列印</dt><dd>{{ fmtTaipei(request.printed_at) }}</dd></template>
        <template v-if="request.booked_at"><dt>入帳</dt><dd>{{ fmtTaipei(request.booked_at) }}</dd></template>
      </dl>

      <h4>憑證 {{ vouchers.length }} 張，合計 ${{ fmtMoney(voucherTotal) }}</h4>
      <p v-if="request.archived_at" class="muted small">照片已封存（{{ fmtTaipei(request.archived_at) }}）</p>
      <p v-if="photoError" class="msg error">{{ photoError }}</p>
      <ul class="vouchers">
        <li v-for="(v, i) in vouchers" :key="v.id">
          <button v-if="urls[v.photo_path]" class="thumb" @click="lightbox = urls[v.photo_path]">
            <img :src="urls[v.photo_path]" :alt="`憑證 ${i + 1}`" loading="lazy" />
          </button>
          <span v-else class="thumb empty">{{ request.archived_at ? '已封存' : '…' }}</span>
          <span>{{ fmtDate(v.voucher_date) }}<br /><strong>${{ fmtMoney(v.amount) }}</strong></span>
        </li>
      </ul>
    </div>

    <div class="req-foot">
      <button class="btn link small" @click="expanded = !expanded">{{ expanded ? '收合' : '詳細與照片' }}</button>
      <slot name="actions" />
    </div>

    <div v-if="lightbox" class="lightbox" @click="lightbox = null">
      <img :src="lightbox" alt="憑證照片" />
      <button class="lightbox-close" aria-label="關閉">✕</button>
    </div>
  </article>
</template>
