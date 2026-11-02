<script setup>
import { computed } from 'vue'
import { printFields } from '../lib/petty'
import approvedStamp from '../assets/approved.png'

// 照「申請單格式.png」重畫的零用金申請單，印在 A4 直式的上半部（一筆一頁）
const props = defineProps({
  request: { type: Object, required: true },
  keeper: { type: String, default: '' },
})
const f = computed(() => printFields(props.request, props.keeper))
// 總經理、表單申請人欄：姓名後換行（「姓名」／「已於 … 核准／送出」）
const breakName = (t) => t.replace(' 已於 ', '\n已於 ')
const approverLines = computed(() => breakName(f.value.approver))
const submitterLines = computed(() => breakName(f.value.submitter))
</script>

<template>
  <section class="sheet">
    <table>
      <colgroup><col style="width: 18.5%" /><col style="width: 39.5%" /><col style="width: 22%" /><col style="width: 20%" /></colgroup>
      <tbody>
        <tr class="r-title">
          <td colspan="4">
            <h1>零用金申請單</h1>
            <div class="fill-date">填寫日期*：{{ f.fillDate }}</div>
          </td>
        </tr>
        <tr class="r-line">
          <th>申請人*</th><td>{{ f.applicant }}</td>
          <th>申請單位*</th><td>{{ f.unit }}</td>
        </tr>
        <tr class="r-reason">
          <th>申請事由*</th><td colspan="3" class="multi">{{ f.reason }}</td>
        </tr>
        <tr class="r-line">
          <th>申請金額*</th><td colspan="3">{{ f.amount }}</td>
        </tr>
        <tr class="r-line">
          <th>零用金負責人*</th><td>{{ f.keeper }}</td>
          <th>零用金核發日期*</th><td>{{ f.disbursedDate }}</td>
        </tr>
        <tr class="r-note">
          <th>備註</th><td colspan="3" class="multi">{{ f.note }}</td>
        </tr>
        <tr class="r-rules">
          <td colspan="4">
            <div>1. 此單星號為必填欄位，請務必照實填寫。</div>
            <div>2. 申請金額不得高於$10,000，如高於$10,000請填寫請款單。</div>
            <div>3.此單由申請人送出，經總經理/主管核准後，即完成表單申請。</div>
          </td>
        </tr>
        <tr class="r-sign">
          <td colspan="4">
            <div class="signs">
              <div class="sign-approver">
                <div class="sign-label">總 經 理：</div>
                <div class="sign-text">{{ approverLines }}</div>
                <img v-if="f.approver" :src="approvedStamp" class="stamp" alt="核准" />
              </div>
              <div><div class="sign-label">領收人：</div><div class="sign-text">{{ f.payee }}</div></div>
              <div><div class="sign-label">表單申請人：</div><div class="sign-text">{{ submitterLines }}</div></div>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
  </section>
</template>

<style scoped>
/* A4 直式上半部（＝A5 橫式大小 210×148mm），邊界 6mm → 198×135mm */
.sheet {
  width: 198mm; height: 135mm; box-sizing: border-box;
  background: #fff; color: #000;
  font-family: "Microsoft JhengHei", "Noto Sans TC", "Noto Sans CJK TC", "PingFang TC", sans-serif;
  -webkit-print-color-adjust: exact; print-color-adjust: exact;
}
table { width: 100%; height: 100%; border-collapse: collapse; table-layout: fixed; border: 0.8mm solid #000; }
th, td { border: 0.25mm solid #000; padding: 0 2mm; font-size: 4.2mm; vertical-align: middle; text-align: left; overflow: hidden; }
th { background: #f2f2f2; font-weight: 400; white-space: nowrap; }
.multi { white-space: pre-wrap; word-break: break-all; line-height: 1.35; font-size: 3.8mm; }
.r-title { height: 21mm; }
.r-title td { position: relative; text-align: center; vertical-align: top; padding-top: 1.5mm; }
h1 { margin: 0; font-size: 9mm; font-weight: 700; letter-spacing: 0.5mm; line-height: 1.2; }
.fill-date { position: absolute; right: 3mm; bottom: 1.5mm; font-size: 4.2mm; text-align: right; }
.r-line { height: 9.5mm; }
.r-reason { height: 24mm; }
.r-note { height: 17mm; }
.r-rules { height: 17mm; }
.r-rules td { font-size: 3.6mm; line-height: 1.45; padding: 0.5mm 1.5mm; }
.r-sign td { position: relative; padding: 0; }
.signs { position: absolute; inset: 0; display: grid; grid-template-columns: repeat(3, 1fr); }
.signs > div { border-left: 0.25mm solid #000; text-align: center; padding: 1mm 1.5mm; }
.signs > div:first-child { border-left: 0; }
.sign-label { font-size: 4.4mm; }
.sign-text { margin-top: 3mm; font-size: 3.4mm; line-height: 1.4; white-space: pre-line; }
.sign-approver { position: relative; }
.sign-approver .sign-text { margin-top: 8mm; }
.stamp { position: absolute; right: 5mm; top: 4mm; width: 14mm; height: 14mm; }
</style>
