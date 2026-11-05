// 推播通知：瀏覽器訂閱 ↔ petty_push_subs（RPC）。私鑰在 Supabase Edge Function 的 Secrets，這裡只有公鑰。
import { supabase } from './supabase'

export const VAPID_PUBLIC_KEY = 'BIwz96ECwQx0bwLuYuqKYTpbgk8G7Uji6jncPOByCkz5p56SeRYhjEubjXWDgoRExCbg39MrXDtkB1b69yP3YY4'

export function isIOS() {
  return /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)
}

export function isStandalone() {
  return window.matchMedia?.('(display-mode: standalone)').matches || navigator.standalone === true
}

// 'ok'｜'dev'（本機開發版沒有 Service Worker）｜'ios-install'（iPhone 要先加到主畫面）｜'unsupported'
export function pushSupport() {
  if (!import.meta.env.PROD) return 'dev'
  const has = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
  if (isIOS() && !isStandalone()) return 'ios-install'
  return has ? 'ok' : 'unsupported'
}

function keyBytes(b64url) {
  const s = atob(b64url.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (b64url.length % 4)) % 4))
  return Uint8Array.from(s, (c) => c.charCodeAt(0))
}

async function registration() {
  return (await navigator.serviceWorker.getRegistration()) || navigator.serviceWorker.register('./sw.js')
}

async function saveSub(sub) {
  const j = sub.toJSON()
  const { error } = await supabase.rpc('petty_push_subscribe', {
    p_endpoint: j.endpoint, p_p256dh: j.keys?.p256dh, p_auth: j.keys?.auth, p_user_agent: navigator.userAgent,
  })
  if (error) throw error
}

// 這個裝置目前有沒有開通知；有的話順便確認資料庫裡掛在目前登入的人
export async function pushEnabled() {
  if (pushSupport() !== 'ok' || Notification.permission !== 'granted') return false
  const sub = await (await registration()).pushManager.getSubscription()
  if (!sub) return false
  await saveSub(sub).catch(() => {})
  return true
}

export async function enablePush() {
  const perm = await Notification.requestPermission()
  if (perm !== 'granted') {
    throw new Error(perm === 'denied'
      ? '通知權限被封鎖了，請到瀏覽器或手機設定裡允許本網站的通知'
      : '沒有允許通知')
  }
  const reg = await registration()
  await navigator.serviceWorker.ready
  const sub = (await reg.pushManager.getSubscription())
    || (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(VAPID_PUBLIC_KEY) }))
  await saveSub(sub)
}

export async function disablePush() {
  if (pushSupport() !== 'ok') return
  const sub = await (await registration()).pushManager.getSubscription()
  if (!sub) return
  await supabase.rpc('petty_push_unsubscribe', { p_endpoint: sub.endpoint })
  await sub.unsubscribe()
}

export async function sendTestPush() {
  const { error } = await supabase.rpc('petty_push_test')
  if (error) throw error
}
