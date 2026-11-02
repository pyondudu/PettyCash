<script setup>
import { computed, onMounted, ref, watch } from 'vue'
import { zipSync } from 'fflate'
import { supabase } from '../lib/supabase'
import { refreshCounts, errText } from '../lib/store'
import {
  STATUS, fmtMoney, todayTaipei, canTransition, parseCategories, bookingMissing,
  archiveMonths, archiveZipName, archivePhotoPath, fmtMonth, requestMonth,
} from '../lib/petty'
import { BUCKET, downloadPhoto, saveBlob } from '../lib/photos'
import RequestCard from '../components/RequestCard.vue'
import PrintSheet from '../components/PrintSheet.vue'
import BookingForm from '../components/BookingForm.vue'

const TABS = [
  { key: 'all', label: '全部' },
  { key: 'approved', label: '待列印' },
  { key: 'pending', label: STATUS.pending.label },
  { key: 'printed', label: STATUS.printed.label },
  { key: 'booked', label: STATUS.booked.label },
  { key: 'rejected', label: STATUS.rejected.label },
  { key: 'returned', label: STATUS.returned.label },
  { key: 'archive', label: '封存' },
]

const rows = ref([])
const keeper = ref('')
const categories = ref([])
const tab = ref('approved')
const loading = ref(true)
const msg = ref('')
const busy = ref(false)
const selected = ref(new Set())
const disbursedDate = ref(todayTaipei())
const preview = ref(null)        // 列印預覽中的申請（已套用核發日期）
const returning = ref(null)      // 正在填取消原因的申請 id
const reason = ref('')
const archiving = ref('')        // 封存進度文字

// 篩選：月份（填寫日期的年月）、申請人；分頁筆數也跟著篩選
const filter = ref({ month: '', name: '' })
const monthOptions = computed(() => [...new Set(rows.value.map((r) => r.fill_date?.slice(0, 7)).filter(Boolean))].sort().reverse())
const nameOptions = computed(() => [...new Set(rows.value.map((r) => r.applicant_name).filter(Boolean))].sort((a, b) => a.localeCompare(b, 'zh-Hant')))
const filtered = computed(() => rows.value.filter((r) =>
  (!filter.value.month || r.fill_date?.startsWith(filter.value.month)) &&
  (!filter.value.name || r.applicant_name === filter.value.name)))
const filterOn = computed(() => !!(filter.value.month || filter.value.name))
const inTab = (r, key) => key === 'all' || r.status === key
const counts = computed(() => Object.fromEntries(TABS.map((t) => [t.key, filtered.value.filter((r) => inTab(r, t.key)).length])))
const list = computed(() => filtered.value.filter((r) => inTab(r, tab.value)))
const listTotal = computed(() => list.value.reduce((s, r) => s + Number(r.amount), 0))
watch(filter, () => { selected.value = new Set(); returning.value = null }, { deep: true })
function clearFilter() { filter.value = { month: '', name: '' } }
const selectable = computed(() => ['approved', 'printed'].includes(tab.value))
const selectedRows = computed(() => list.value.filter((r) => selected.value.has(r.id)))
// A4 直式一頁兩筆（上、下半部）
const previewPages = computed(() => {
  const pages = []
  for (let i = 0; i < (preview.value?.length ?? 0); i += 2) pages.push(preview.value.slice(i, i + 2))
  return pages
})
const months = computed(() => archiveMonths(rows.value))

async function load() {
  loading.value = true
  const [r, s] = await Promise.all([
    supabase.from('petty_requests').select('*, petty_vouchers(*)').order('submitted_at', { ascending: false }),
    supabase.from('petty_settings').select('key, value').in('key', ['keeper_name', 'categories']),
  ])
  loading.value = false
  if (r.error) msg.value = '讀取失敗：' + errText(r.error)
  rows.value = r.data ?? []
  const settings = Object.fromEntries((s.data ?? []).map((x) => [x.key, x.value]))
  keeper.value = settings.keeper_name ?? ''
  categories.value = parseCategories(settings.categories)
  selected.value = new Set([...selected.value].filter((id) => list.value.some((x) => x.id === id)))
  refreshCounts()
}

function switchTab(key) {
  tab.value = key
  selected.value = new Set()
  returning.value = null
  msg.value = ''
}

function toggle(id) {
  const s = new Set(selected.value)
  s.has(id) ? s.delete(id) : s.add(id)
  selected.value = s
}

function toggleAll() {
  selected.value = selected.value.size === list.value.length ? new Set() : new Set(list.value.map((r) => r.id))
}

// ── 列印 ──
function openPreview() {
  msg.value = ''
  if (!selectedRows.value.length) { msg.value = '請先勾選要列印的申請'; return }
  if (!disbursedDate.value) { msg.value = '請選擇零用金核發日期'; return }
  preview.value = selectedRows.value.map((r) => ({ ...r, disbursed_date: disbursedDate.value }))
}

// Chrome 會記住上次的「縮放比例」，被設成自訂（例如 70）時申請單會印小；網頁無法強制設定，只能提醒
const PRINT_TIP = '列印設定請確認：紙張 A4、縮放比例選「預設值」（或自訂 100）、邊界「預設值」。若印出來變小，多半是縮放比例被設成自訂。'
const TIP_KEY = 'petty-print-tip-seen'
function firstPrintTip() {
  let seen = false
  try { seen = localStorage.getItem(TIP_KEY) === '1' } catch {}
  if (seen) return true
  if (!confirm(PRINT_TIP + '\n\n按「確定」開啟列印視窗。')) return false
  try { localStorage.setItem(TIP_KEY, '1') } catch {}
  return true
}

async function printNow() {
  if (!firstPrintTip()) return
  window.print()
  const n = preview.value.length
  if (!confirm(`已經印好了嗎？\n按「確定」把這 ${n} 筆標為「已核發」，核發日期 ${disbursedDate.value.replaceAll('-', '/')}。`)) return
  busy.value = true
  const { error } = await supabase.from('petty_requests')
    .update({ status: 'printed', disbursed_date: disbursedDate.value })
    .in('id', preview.value.map((r) => r.id))
  busy.value = false
  if (error) { msg.value = '更新狀態失敗：' + errText(error); return }
  preview.value = null
  selected.value = new Set()
  await load()
}

// 只重新讀一筆（儲存登記資料後用，不影響其他卡片還沒儲存的輸入）
async function reloadOne(id) {
  const { data, error } = await supabase.from('petty_requests').select('*, petty_vouchers(*)').eq('id', id).single()
  if (error) { msg.value = '讀取失敗：' + errText(error); return }
  rows.value = rows.value.map((x) => (x.id === id ? data : x))
}

// ── 登記、取消 ──
async function markBooked() {
  msg.value = ''
  if (!selectedRows.value.length) { msg.value = '請先勾選申請'; return }
  const notReady = selectedRows.value
    .map((r) => [r, bookingMissing(r)])
    .filter(([, m]) => m.length)
  if (notReady.length) {
    msg.value = '以下申請的登記資料還沒填完或還沒儲存：\n' +
      notReady.map(([r, m]) => `${r.applicant_name} $${fmtMoney(r.amount)}（${r.reason}）：缺 ${m.join('、')}`).join('\n')
    return
  }
  if (!confirm(`把 ${selectedRows.value.length} 筆標為「已登記」？\n登記後約 1 分鐘內會自動寫入 Google 試算表。`)) return
  busy.value = true
  const { error } = await supabase.from('petty_requests').update({ status: 'booked' }).in('id', selectedRows.value.map((r) => r.id))
  busy.value = false
  if (error) { msg.value = '更新失敗：' + errText(error); return }
  selected.value = new Set()
  await load()
}

async function returnRequest(r) {
  if (!reason.value.trim()) { msg.value = '請填寫取消原因'; return }
  busy.value = true
  const { error } = await supabase.from('petty_requests').update({ status: 'returned', reject_reason: reason.value }).eq('id', r.id)
  busy.value = false
  if (error) { msg.value = '取消失敗：' + errText(error); return }
  returning.value = null
  reason.value = ''
  await load()
}

// ── 整月封存：下載 zip → 標記封存 → 刪雲端照片 ──
async function archive(m) {
  msg.value = ''
  const reqs = rows.value.filter((r) => requestMonth(r.request_no) === m.month && !r.archived_at)
  const vouchers = reqs.flatMap((r) => [...r.petty_vouchers].sort((a, b) => a.id - b.id)
    .map((v, i) => ({ path: v.photo_path, name: archivePhotoPath(r.request_no, i) })))
  if (!confirm(`封存 ${fmtMonth(m.month)}：${reqs.length} 筆申請、${vouchers.length} 張照片。\n會先下載 zip，確認保存好後才刪除雲端照片。`)) return
  busy.value = true
  try {
    const files = {}
    for (const [i, v] of vouchers.entries()) {
      archiving.value = `下載照片 ${i + 1}／${vouchers.length}…`
      files[v.name] = [await downloadPhoto(v.path), { level: 0 }]
    }
    archiving.value = '產生 zip…'
    saveBlob(new Blob([zipSync(files)], { type: 'application/zip' }), archiveZipName(m.month))
    archiving.value = ''
    if (!confirm(`已下載「${archiveZipName(m.month)}」。\n請確認檔案已保存好（例如放到公司雲端硬碟），再按「確定」刪除雲端照片。\n按「取消」則不封存。`)) return
    archiving.value = '標記封存…'
    const { error } = await supabase.rpc('petty_archive_month', { p_month: m.month })
    if (error) throw error
    archiving.value = '刪除雲端照片…'
    for (let i = 0; i < vouchers.length; i += 100) {
      const { error: e } = await supabase.storage.from(BUCKET).remove(vouchers.slice(i, i + 100).map((v) => v.path))
      if (e) throw e
    }
    msg.value = `${fmtMonth(m.month)} 已封存。`
    await load()
  } catch (e) {
    msg.value = '封存失敗：' + errText(e)
  } finally {
    busy.value = false
    archiving.value = ''
  }
}

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="page-head">
      <h2>管理</h2>
      <button class="btn small" @click="load">重新整理</button>
    </div>
    <div class="seg-tabs">
      <button v-for="t in TABS" :key="t.key" :class="{ on: tab === t.key }" @click="switchTab(t.key)">
        {{ t.label }}<span v-if="t.key !== 'archive'" class="cnt">{{ counts[t.key] }}</span>
      </button>
    </div>
    <p v-if="msg" class="msg error">{{ msg }}</p>
    <p v-if="loading" class="muted">載入中…</p>

    <!-- 封存 -->
    <template v-else-if="tab === 'archive'">
      <p class="muted small">封存以「送出申請的月份」為單位，當月每一筆申請都「已結束」才能封存整個月。「已結束」是指已登記滿 4 個月，或是主管退回、已取消的申請。<br />封存時會先下載當月照片的 zip，再刪除雲端照片；申請紀錄會保留。</p>
      <p v-if="archiving" class="msg">{{ archiving }}</p>
      <table class="month-table">
        <thead><tr><th>月份</th><th class="num">申請</th><th class="num">尚未結束</th><th class="num">尚未封存</th><th></th></tr></thead>
        <tbody>
          <tr v-for="m in months" :key="m.month">
            <td>{{ fmtMonth(m.month) }}</td>
            <td class="num">{{ m.total }}</td>
            <td class="num">{{ m.open }}</td>
            <td class="num">{{ m.pending }}</td>
            <td>
              <button v-if="m.ready" class="btn small primary" :disabled="busy" @click="archive(m)">封存</button>
              <span v-else-if="!m.pending" class="muted small">已封存</span>
              <span v-else class="muted small">還不能封存</span>
            </td>
          </tr>
        </tbody>
      </table>
      <p v-if="!months.length" class="muted center empty">還沒有申請。</p>
    </template>

    <template v-else>
      <div class="filter-bar">
        <label class="inline">月份
          <select v-model="filter.month">
            <option value="">全部月份</option>
            <option v-for="m in monthOptions" :key="m" :value="m">{{ m.replace('-', '/') }}</option>
          </select>
        </label>
        <label class="inline">申請人
          <select v-model="filter.name">
            <option value="">全部人</option>
            <option v-for="n in nameOptions" :key="n" :value="n">{{ n }}</option>
          </select>
        </label>
        <button v-if="filterOn" class="btn small ghost" @click="clearFilter">清除篩選</button>
        <span class="spacer" />
        <span class="muted small">{{ list.length }} 筆，合計 ${{ fmtMoney(listTotal) }}</span>
      </div>
      <div v-if="selectable && list.length" class="batch-bar">
        <label class="check"><input type="checkbox" :checked="selected.size === list.length" @change="toggleAll" />全選</label>
        <span class="muted">已選 {{ selected.size }} 筆</span>
        <span class="spacer" />
        <label class="inline">核發日期<input v-model="disbursedDate" type="date" /></label>
        <button class="btn small primary" :disabled="!selected.size" @click="openPreview">{{ tab === 'printed' ? '重印預覽' : '列印預覽' }}</button>
        <button v-if="tab === 'printed'" class="btn small" :disabled="!selected.size || busy" @click="markBooked">標已登記</button>
      </div>
      <p v-if="!list.length" class="muted center empty">{{ filterOn ? '沒有符合篩選條件的申請。' : tab === 'all' ? '還沒有申請。' : `沒有「${TABS.find((t) => t.key === tab).label}」的申請。` }}</p>
      <div class="list">
        <div v-for="r in list" :key="r.id" class="selectable-row">
          <input v-if="selectable" type="checkbox" class="row-check" :checked="selected.has(r.id)" @change="toggle(r.id)" />
          <RequestCard :request="r" show-applicant>
            <template #actions>
              <template v-if="canTransition(r.status, 'returned', 'admin')">
                <template v-if="returning === r.id">
                  <input v-model="reason" class="reason-input" placeholder="取消原因" />
                  <button class="btn small danger" :disabled="busy" @click="returnRequest(r)">確定取消</button>
                  <button class="btn small ghost" @click="returning = null">不取消</button>
                </template>
                <button v-else class="btn small ghost danger" @click="returning = r.id; reason = ''">取消申請</button>
              </template>
            </template>
            <template v-if="['approved', 'printed'].includes(r.status)" #extra>
              <BookingForm :request="r" :categories="categories" @saved="reloadOne(r.id)" />
            </template>
          </RequestCard>
        </div>
      </div>
    </template>

    <!-- 列印預覽：螢幕上是全頁預覽，列印時只印申請單 -->
    <Teleport to="body">
      <div v-if="preview" class="print-preview">
        <div class="print-toolbar no-print">
          <span>列印預覽：{{ preview.length }} 筆，A4 直式 {{ previewPages.length }} 頁（一頁上下兩筆，從中間虛線裁開），核發日期 {{ disbursedDate.replaceAll('-', '/') }}，合計 ${{ fmtMoney(preview.reduce((s, r) => s + r.amount, 0)) }}</span>
          <span class="spacer" />
          <button class="btn small" @click="preview = null">關閉</button>
          <button class="btn small primary" :disabled="busy" @click="printNow">列印</button>
          <div class="print-tip">{{ PRINT_TIP }}</div>
        </div>
        <div class="print-pages">
          <div v-for="(page, i) in previewPages" :key="i" class="print-page">
            <div v-for="r in page" :key="r.id" class="print-half">
              <PrintSheet :request="r" :keeper="keeper" />
            </div>
          </div>
        </div>
      </div>
    </Teleport>
  </div>
</template>
