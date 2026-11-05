-- 2026-11-05 推播通知
--   * 每週五 09:00（台北）通知主管「有 N 筆申請待核准」
--   * 主管核准一筆，即時通知「核准通知對象」（petty_settings.push_approved_to，預設鍾筱平）
-- 在 SQL Editor 執行這份即可（可重複執行）。只新增 petty_ 開頭的物件與一筆 pg_cron 工作，不動 PartTrail。
-- 執行前要先：
--   1. Edge Functions 建好 petty-push（Verify JWT 關閉），Secrets 設好 VAPID_PUBLIC_KEY、VAPID_PRIVATE_KEY、PETTY_PUSH_SECRET
--   2. 在 SQL Editor 設定呼叫密碼（和 PETTY_PUSH_SECRET 相同，值不寫進 repo）：
--      insert into public.petty_secrets values ('push_secret', '<密碼>') on conflict (key) do update set value = excluded.value;

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ─────────────────────────────────────────────
-- 訂閱：每人每支手機（瀏覽器）一列。網頁只能讀自己的；新增、刪除走 RPC
-- ─────────────────────────────────────────────
create table if not exists public.petty_push_subs (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);
create index if not exists petty_push_subs_user_idx on public.petty_push_subs (user_id);

alter table public.petty_push_subs enable row level security;
drop policy if exists "petty push subs read own" on public.petty_push_subs;
create policy "petty push subs read own" on public.petty_push_subs
  for select using (user_id = auth.uid() and public.petty_role() is not null);

-- 開啟通知：同一支手機換人登入時，訂閱改掛到目前的人
create or replace function public.petty_push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.petty_role(), '') not in ('approver', 'admin') then
    raise exception '只有主管和管理者可以開啟通知';
  end if;
  if coalesce(p_endpoint, '') !~ '^https://' or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception '通知訂閱資料不完整';
  end if;
  insert into public.petty_push_subs (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, created_at = now();
end $$;

-- 關閉通知（或登出）：只刪自己的
create or replace function public.petty_push_unsubscribe(p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.petty_push_subs where endpoint = p_endpoint and user_id = auth.uid();
end $$;

-- 呼叫 Edge Function（內部用）。pg_net 是非同步的，失敗也不會影響核准
create or replace function public.petty_push_call(p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_secret text := (select value from public.petty_secrets where key = 'push_secret');
begin
  if v_secret is null then
    return;   -- 還沒設定推播
  end if;
  perform net.http_post(
    url     := 'https://pcujnsjukppnobdvwijl.supabase.co/functions/v1/petty-push',
    body    := p,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-petty-secret', v_secret),
    timeout_milliseconds := 10000
  );
exception when others then
  raise warning 'petty_push_call 失敗：%', sqlerrm;
end $$;

-- 測試通知：只發給自己（內容含目前待核准筆數，順便測週報的查詢）
create or replace function public.petty_push_test()
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.petty_role(), '') not in ('approver', 'admin') then
    raise exception '只有主管和管理者可以傳送測試通知';
  end if;
  if not exists (select 1 from public.petty_push_subs where user_id = auth.uid()) then
    raise exception '這個帳號還沒有開啟通知的手機';
  end if;
  if not exists (select 1 from public.petty_secrets where key = 'push_secret') then
    raise exception '推播還沒設定完成（缺 push_secret）';
  end if;
  perform public.petty_push_call(jsonb_build_object('type', 'test', 'user_id', auth.uid()));
end $$;

-- 核准時即時通知
create or replace function public.petty_requests_push_approved()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'pending' and new.status = 'approved' then
    perform public.petty_push_call(jsonb_build_object('type', 'approved', 'request_id', new.id));
  end if;
  return null;
end $$;

drop trigger if exists petty_requests_push_approved on public.petty_requests;
create trigger petty_requests_push_approved
  after update of status on public.petty_requests
  for each row execute function public.petty_requests_push_approved();

-- 核准通知對象（user_id，一行一個），預設鍾筱平
insert into public.petty_settings (key, value)
select 'push_approved_to', coalesce((select user_id::text from public.petty_members where email = 'pyon.chung@ai-a.com.tw'), '')
on conflict (key) do nothing;

revoke execute on function public.petty_push_subscribe(text, text, text, text) from public, anon;
revoke execute on function public.petty_push_unsubscribe(text) from public, anon;
revoke execute on function public.petty_push_test() from public, anon;
revoke execute on function public.petty_push_call(jsonb) from public, anon, authenticated;
revoke execute on function public.petty_requests_push_approved() from public, anon, authenticated;
grant execute on function public.petty_push_subscribe(text, text, text, text) to authenticated;
grant execute on function public.petty_push_unsubscribe(text) to authenticated;
grant execute on function public.petty_push_test() to authenticated;

-- 每週五 09:00（台北）＝ UTC 週五 01:00；同名工作重複執行會更新，不會多一筆
select cron.schedule('petty-weekly-push', '0 1 * * 5', $$select public.petty_push_call('{"type":"weekly"}'::jsonb)$$);

-- 確認：應該看到一筆 petty-weekly-push
select jobname, schedule, command, active from cron.job where jobname = 'petty-weekly-push';
