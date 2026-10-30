import { supabase } from './supabase'
import { store } from './store'
import { normalizeAmount, normalizeDate, fmtDate, fmtMoney, voucherKey, findLocalDuplicates, voucherPairs } from './petty'
import { BUCKET, compressImage, uuid } from './photos'

// 編輯中的憑證：{ key, file, preview, date, amount }
export function newVoucher(file) {
  return { key: uuid(), file, preview: URL.createObjectURL(file), date: '', amount: '' }
}

export function releaseVouchers(list) {
  list.forEach((v) => URL.revokeObjectURL(v.preview))
}

export function voucherError(v) {
  if (!v.file) return '請附照片'
  if (!normalizeDate(v.date)) return '日期格式不正確'
  const a = normalizeAmount(v.amount)
  if (a === null || a <= 0) return '請填憑證金額'
  return null
}

// 重複提示：同一批裡重複，或和其他未退回的申請相同（日期＋憑證金額）；沒有重複回傳 null
export async function duplicateWarning(list) {
  if (!list.length) return null
  const local = findLocalDuplicates(list)
  const { data, error } = await supabase.rpc('petty_duplicate_vouchers', { pairs: voucherPairs(list) })
  if (error) throw error
  const remote = (data ?? []).map((d) => voucherKey(d.dup_date, d.dup_amount))
  const show = (k) => `${fmtDate(k.split('|')[0])} $${fmtMoney(k.split('|')[1])}`
  const lines = [
    ...local.map((k) => `・${show(k)}：這次有兩張相同`),
    ...remote.map((k) => `・${show(k)}：已經出現在其他申請`),
  ]
  return lines.length ? `下列憑證的日期和金額重複：\n${lines.join('\n')}\n\n確定仍要送出嗎？` : null
}

// 縮圖後上傳到 petty/<自己的 user id>/<申請 id>/<隨機名>.jpg；回傳要交給 RPC 的憑證和已上傳的路徑
export async function uploadVouchers(requestId, list, onProgress = () => {}) {
  const items = []
  const uploaded = []
  try {
    for (const [i, v] of list.entries()) {
      onProgress(`上傳照片 ${i + 1}／${list.length}…`)
      const blob = await compressImage(v.file)
      const path = `${store.uid}/${requestId}/${uuid()}.jpg`
      const { error } = await supabase.storage.from(BUCKET).upload(path, blob, { contentType: 'image/jpeg' })
      if (error) throw error
      uploaded.push(path)
      items.push({ date: normalizeDate(v.date), amount: normalizeAmount(v.amount), photo_path: path })
    }
  } catch (e) {
    await removeUploaded(uploaded)
    throw e
  }
  return { items, uploaded }
}

// 送出失敗時刪掉剛上傳、還沒掛到憑證的照片
export async function removeUploaded(paths) {
  if (paths.length) await supabase.storage.from(BUCKET).remove(paths)
}
