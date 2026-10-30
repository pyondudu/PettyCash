import { reactive } from 'vue'

// 版本檢查：建置時把 __BUILD_ID__ 寫進程式，同時產生 version.json；兩者不同代表伺服器上有新版
export const BUILD_ID = __BUILD_ID__

// status：idle / checking / latest / available / error
export const update = reactive({ status: 'idle' })

export function formatBuild(id = BUILD_ID) {
  const d = new Date(id)
  if (isNaN(d)) return ''
  const p = (n) => String(n).padStart(2, '0')
  return `${d.getMonth() + 1}/${d.getDate()} ${p(d.getHours())}:${p(d.getMinutes())}`
}

export async function checkUpdate({ quiet = false } = {}) {
  if (!import.meta.env.PROD) return (update.status = 'latest')
  if (update.status === 'checking') return
  if (!quiet) update.status = 'checking'
  try {
    const res = await fetch(`./version.json?t=${Date.now()}`, { cache: 'no-store' })
    if (!res.ok) throw new Error(res.status)
    const { build } = await res.json()
    if (build !== BUILD_ID) update.status = 'available'
    else if (!quiet) update.status = 'latest'
  } catch {
    if (!quiet) update.status = 'error'
  }
}

// 先繞過快取重抓首頁，讓瀏覽器 HTTP 快取換成新版，再重新載入
export async function applyUpdate() {
  try {
    await fetch('./', { cache: 'reload' })
    const reg = await navigator.serviceWorker?.getRegistration()
    await reg?.update()
  } catch {}
  location.reload()
}

// App 從背景回到前景時自動檢查；只提示，不強制重載，避免打斷正在填的表單
export function watchUpdates() {
  if (!import.meta.env.PROD) return
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') checkUpdate({ quiet: true })
  })
  checkUpdate({ quiet: true })
}
