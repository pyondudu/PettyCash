// 零用金申請的共用規則（純 JS，不依賴 Vite，可直接用 node --test 測試）
// 狀態與轉換規則要和 supabase/petty_schema.sql 的 trigger 一致

export const STATUS = {
  pending: { label: '待主管核准' },
  approved: { label: '已核准' },
  rejected: { label: '主管退回' },
  printed: { label: '已核發' },   // 已列印、零用金已核發
  booked: { label: '已登記' },
  returned: { label: '已取消' },   // 管理者在流程中途取消
}
export const STATUS_KEYS = Object.keys(STATUS)

// 主管退回、已取消的申請不列入重複比對
export const CLOSED_STATUSES = ['rejected', 'returned']

export const ROLES = {
  applicant: '申請人',
  approver: '主管',
  admin: '管理者',
}

// 角色 → 允許的 [原狀態, 新狀態]；printed → printed 是重印（可改核發日期）
const TRANSITIONS = {
  approver: [['pending', 'approved'], ['pending', 'rejected']],
  admin: [
    ['approved', 'printed'],
    ['printed', 'printed'],
    ['printed', 'booked'],
    ['pending', 'returned'],
    ['approved', 'returned'],
    ['printed', 'returned'],
  ],
}

export function canTransition(from, to, role) {
  return (TRANSITIONS[role] ?? []).some(([f, t]) => f === from && t === to)
}

// 憑證選填：申請人可在登記前補上（主管退回、已取消、已封存的不行）
export const VOUCHER_OPEN_STATUSES = ['pending', 'approved', 'printed']
export function canAddVouchers(r) {
  return VOUCHER_OPEN_STATUSES.includes(r.status) && !r.archived_at
}

// 只有主管能核准（包含主管自己的申請）
export function canApprove(request, role) {
  return request.status === 'pending' && role === 'approver'
}

// ─────────────────────────────────────────────
// 憑證照片與封存
// ─────────────────────────────────────────────
// 上傳前在手機縮圖：長邊 1200px、JPEG 品質 0.75（約 100–200KB）
export const PHOTO_MAX_EDGE = 1200
export const PHOTO_QUALITY = 0.75

// 封存以月為單位（依申請編號的年月）：該月每筆都「已登記滿 4 個月」或「主管退回／已取消」才可以
// 下載該月照片 zip → RPC petty_archive_month → 刪雲端照片
export const ARCHIVE_MONTHS = 4

// 加月份，月底對齊（10/31 + 4 個月 = 2/28），和 Postgres 的 interval '4 months' 一致
export function addMonths(ts, months) {
  const d = new Date(ts)
  const y = d.getUTCFullYear()
  const m = d.getUTCMonth() + months
  const lastDay = new Date(Date.UTC(y, m + 1, 0)).getUTCDate()
  const r = new Date(d)
  r.setUTCFullYear(y, m, Math.min(d.getUTCDate(), lastDay))
  return r
}

// 這筆申請已結束、照片可以封存
export function requestFinished(r, now = new Date()) {
  if (CLOSED_STATUSES.includes(r.status)) return true
  return r.status === 'booked' && !!r.booked_at && addMonths(r.booked_at, ARCHIVE_MONTHS) <= new Date(now)
}

// 申請編號 P2026110001 → '202611'
export function requestMonth(requestNo) {
  const m = /^P(\d{6})\d{4}$/.exec(requestNo ?? '')
  return m ? m[1] : null
}

// '202611' → '2026-11'
export function fmtMonth(ym) {
  return `${ym.slice(0, 4)}-${ym.slice(4, 6)}`
}

export function archiveZipName(ym) {
  return `聲智零用金憑證_${fmtMonth(ym)}.zip`
}

// zip 裡的路徑：P2026110001/憑證1.jpg
export function archivePhotoPath(requestNo, index) {
  return `${requestNo}/憑證${index + 1}.jpg`
}

// 依月份整理封存狀態，新到舊：{ month, total, open（還沒結束）, pending（未封存）, ready }
export function archiveMonths(requests, now = new Date()) {
  const map = new Map()
  for (const r of requests) {
    const month = requestMonth(r.request_no)
    if (!month) continue
    const s = map.get(month) ?? { month, total: 0, open: 0, pending: 0 }
    s.total++
    if (!requestFinished(r, now)) s.open++
    if (!r.archived_at) s.pending++
    map.set(month, s)
  }
  return [...map.values()]
    .map((s) => ({ ...s, ready: s.open === 0 && s.pending > 0 }))
    .sort((a, b) => b.month.localeCompare(a.month))
}

// ─────────────────────────────────────────────
// 金額
// ─────────────────────────────────────────────
export const MAX_AMOUNT = 10000

// 去掉逗號、$ 和空白後轉成數字；不是數字回傳 null
export function normalizeAmount(s) {
  if (s === null || s === undefined) return null
  const v = String(s).replace(/[,$\s，＄]/g, '')
  if (v === '' || !/^\d+(\.\d+)?$/.test(v)) return null
  return Number(v)
}

// 申請金額：整數、> 0 且 ≤ 10,000；回傳錯誤訊息，沒問題回傳 null
export function validateAmount(s) {
  const n = normalizeAmount(s)
  if (n === null) return '請輸入申請金額'
  if (!Number.isInteger(n)) return '申請金額請填整數'
  if (n <= 0) return '申請金額要大於 0'
  if (n > MAX_AMOUNT) return `申請金額不得高於 $${fmtMoney(MAX_AMOUNT)}，請改填請款單`
  return null
}

export function fmtMoney(n) {
  if (n === null || n === undefined || n === '') return ''
  return Number(n).toLocaleString('en-US')
}

// ─────────────────────────────────────────────
// 日期與時間
// ─────────────────────────────────────────────
const pad = (n) => String(n).padStart(2, '0')

// 接受 2026-09-30、2026/9/30、115/09/30（民國）、2026.9.30、20260930 → YYYY-MM-DD；無效回傳 null
export function normalizeDate(s) {
  if (!s) return null
  const v = String(s).trim()
  let y, m, d
  let match = v.match(/^(\d{2,4})[-/.](\d{1,2})[-/.](\d{1,2})$/)
  if (match) [, y, m, d] = match.map(Number)
  else if ((match = v.match(/^(\d{4})(\d{2})(\d{2})$/))) [, y, m, d] = match.map(Number)
  else return null
  if (y < 1000) y += 1911
  const dt = new Date(Date.UTC(y, m - 1, d))
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null
  return `${y}-${pad(m)}-${pad(d)}`
}

// YYYY-MM-DD → yyyy/MM/dd
export function fmtDate(s) {
  if (!s) return ''
  const [y, m, d] = String(s).slice(0, 10).split('-')
  return `${y}/${m}/${d}`
}

// 今天（台北時間）YYYY-MM-DD
export function todayTaipei(now = new Date()) {
  return taipeiParts(now).slice(0, 3).join('-')
}

function taipeiParts(ts) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'Asia/Taipei',
    hourCycle: 'h23',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  }).formatToParts(new Date(ts))
  const get = (t) => parts.find((p) => p.type === t).value
  return [get('year'), get('month'), get('day'), get('hour'), get('minute'), get('second')]
}

// 時間戳 → yyyy/MM/dd HH:mm:ss（Asia/Taipei）
export function fmtTaipei(ts) {
  if (!ts) return ''
  const [y, mo, d, h, mi, s] = taipeiParts(ts)
  return `${y}/${mo}/${d} ${h}:${mi}:${s}`
}

export function approvedText(name, ts) {
  return name && ts ? `${name} 已於 ${fmtTaipei(ts)} 核准` : ''
}

export function submittedText(name, ts) {
  return name && ts ? `${name} 已於 ${fmtTaipei(ts)} 送出` : ''
}

// ─────────────────────────────────────────────
// 憑證重複比對：日期＋憑證金額
// ─────────────────────────────────────────────
export function voucherKey(date, amount) {
  const d = normalizeDate(date)
  const a = normalizeAmount(amount)
  return d && a !== null ? `${d}|${a}` : null
}

// 同一筆申請內重複的憑證 key
export function findLocalDuplicates(vouchers) {
  const seen = new Set()
  const dup = new Set()
  for (const v of vouchers) {
    const k = voucherKey(v.date, v.amount)
    if (!k) continue
    if (seen.has(k)) dup.add(k)
    seen.add(k)
  }
  return [...dup]
}

// 給 RPC petty_duplicate_vouchers 的參數
export function voucherPairs(vouchers) {
  return vouchers
    .map((v) => ({ date: normalizeDate(v.date), amount: normalizeAmount(v.amount) }))
    .filter((p) => p.date && p.amount !== null)
}

// ─────────────────────────────────────────────
// 列印：申請單欄位對應（申請單格式.png）
// ─────────────────────────────────────────────
export function printFields(r, keeperName) {
  return {
    fillDate: fmtDate(r.fill_date),
    applicant: r.applicant_name ?? '',
    unit: r.applicant_unit ?? '',
    reason: r.reason ?? '',
    amount: r.amount ? `$${fmtMoney(r.amount)}` : '',
    keeper: keeperName ?? '',
    disbursedDate: fmtDate(r.disbursed_date),
    note: r.note ?? '',
    approver: approvedText(r.approver_name, r.approved_at),
    payee: '',   // 「領收人」欄留白給本人簽名
    submitter: submittedText(r.applicant_name, r.submitted_at),
  }
}

// ─────────────────────────────────────────────
// 登記（寫入 Google 試算表前，管理者填類別、領收人、收據號碼）
// ─────────────────────────────────────────────
export const NO_RECEIPT_NO = '無號碼'

// 設定裡的類別：一行一個，去掉空白行與重複
export function parseCategories(text) {
  return [...new Set((text ?? '').split(/\r?\n/).map((s) => s.trim()).filter(Boolean))]
}

// 試算表「收據編號」欄的一行：EW-02015333(2026.10.22) NT696
export function receiptLine(v) {
  const d = (v.voucher_date ?? '').replaceAll('-', '.')
  return `${(v.receipt_no ?? '').trim()}(${d}) NT${fmtMoney(v.amount)}`
}

// 還缺哪些登記資料（空陣列＝可以登記）；booking = { category, payee_name, receipts: { 憑證id: 號碼 } }
export function bookingMissing(r, booking = r) {
  const miss = []
  if (!(booking.category ?? '').trim()) miss.push('類別')
  if (!(booking.payee_name ?? '').trim()) miss.push('領收人')
  const receipts = booking.receipts
  const noNo = (r.petty_vouchers ?? []).filter((v) => !((receipts ? receipts[v.id] : v.receipt_no) ?? '').trim())
  if (noNo.length) miss.push(`收據號碼（${noNo.length} 張）`)
  return miss
}

// ─────────────────────────────────────────────
// 登入：輸入沒有 @ 時補假網域（同 PartTrail）
// ─────────────────────────────────────────────
export const LOGIN_DOMAIN = 'parttrail.local'
export function toLoginEmail(input) {
  const v = input.trim().toLowerCase()
  return v.includes('@') ? v : `${v}@${LOGIN_DOMAIN}`
}
