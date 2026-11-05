// Edge Function：petty-push（零用金推播）
// 由資料庫 petty_push_call() 用 pg_net 呼叫，帶 x-petty-secret；部署時 Verify JWT 要關閉。
// Secrets：VAPID_PUBLIC_KEY、VAPID_PRIVATE_KEY、PETTY_PUSH_SECRET（SUPABASE_URL、SUPABASE_SERVICE_ROLE_KEY 系統自動提供）
// 通知內容只寫「有新通知」，不寫姓名、金額（會顯示在鎖定畫面）。
import webpush from 'npm:web-push@3.6.7'
import { createClient } from 'npm:@supabase/supabase-js@2.45.4'

const SECRET = Deno.env.get('PETTY_PUSH_SECRET') ?? ''
webpush.setVapidDetails(
  'https://pyondudu.github.io/PettyCash/',
  Deno.env.get('VAPID_PUBLIC_KEY') ?? '',
  Deno.env.get('VAPID_PRIVATE_KEY') ?? '',
)
const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
})

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

async function pendingCount(): Promise<number> {
  const { count, error } = await db.from('petty_requests').select('id', { count: 'exact', head: true }).eq('status', 'pending')
  if (error) throw error
  return count ?? 0
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method' }, 405)
  if (SECRET.length < 16 || req.headers.get('x-petty-secret') !== SECRET) return json({ error: 'forbidden' }, 403)

  const p = await req.json().catch(() => ({}))
  let userIds: string[] = []
  let msg: { title: string; body: string; url: string; tag: string }

  if (p.type === 'weekly') {
    const n = await pendingCount()
    if (n === 0) return json({ skipped: '沒有待核准' })
    const { data, error } = await db.from('petty_members').select('user_id').eq('role', 'approver').eq('active', true)
    if (error) throw error
    userIds = (data ?? []).map((m) => m.user_id)
    msg = { title: '零用金申請', body: `有 ${n} 筆申請待核准`, url: '#/approve', tag: 'petty-weekly' }
  } else if (p.type === 'approved') {
    const { data, error } = await db.from('petty_settings').select('value').eq('key', 'push_approved_to').maybeSingle()
    if (error) throw error
    userIds = String(data?.value ?? '').split(/[\s,]+/).filter(Boolean)
    msg = { title: '零用金申請', body: '有新的已核准申請', url: '#/admin', tag: 'petty-approved' }
  } else if (p.type === 'test' && typeof p.user_id === 'string') {
    userIds = [p.user_id]
    const n = await pendingCount()
    msg = { title: '零用金申請（測試）', body: `通知設定成功。目前有 ${n} 筆申請待核准`, url: '#/', tag: 'petty-test' }
  } else {
    return json({ error: 'type' }, 400)
  }
  if (!userIds.length) return json({ sent: 0 })

  const { data: subs, error } = await db.from('petty_push_subs').select('id, endpoint, p256dh, auth').in('user_id', userIds)
  if (error) throw error

  let sent = 0
  const gone: number[] = []
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify(msg),
        { TTL: 60 * 60 * 24 },
      )
      sent++
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode
      if (code === 404 || code === 410) gone.push(s.id)   // 手機已取消訂閱
      else console.error('推播失敗', code, (e as Error).message)
    }
  }))
  if (gone.length) await db.from('petty_push_subs').delete().in('id', gone)
  return json({ sent, removed: gone.length })
})
