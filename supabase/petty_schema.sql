-- PettyCash（聲智零用金申請）資料庫結構
-- 在 Supabase Dashboard → SQL Editor 貼上整份執行即可（可重複執行）。
-- 與 PartTrail 共用專案：這份只建立 petty_ 開頭的表、函式、trigger、policy 和 Storage bucket「petty」，
-- 不修改 PartTrail 的任何物件。執行前後請各跑一次 check_parttrail.sql 比對。
--
-- 狀態（status）：
--   pending 待主管核准 → (主管) approved 已核准 / rejected 主管退回
--   approved → (管理者列印) printed 已核發 → (管理者) booked 已登記
--   pending / approved / printed → (管理者) returned 已取消（流程中途取消）
-- 封存：依申請編號的年月整月封存。該月每筆都「已登記滿 4 個月」或「主管退回／已取消」後，
--   管理者下載該月照片 zip、呼叫 petty_archive_month，再刪掉雲端照片（申請紀錄保留）。
-- 規則要和 web/src/lib/petty.js 一致。

-- ─────────────────────────────────────────────
-- 成員：有這一列且 active 的人才能用本系統
-- ─────────────────────────────────────────────
create table if not exists public.petty_members (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  email       text,
  name        text not null,
  unit        text not null default '',
  role        text not null default 'applicant' check (role in ('applicant', 'approver', 'admin')),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- 目前登入者的零用金角色（停用或不是成員回傳 null）；不使用 PartTrail 的 my_role()
create or replace function public.petty_role()
returns text language sql stable security definer set search_path = public as $$
  select role from public.petty_members where user_id = auth.uid() and active
$$;

-- ─────────────────────────────────────────────
-- 申請
-- ─────────────────────────────────────────────
create table if not exists public.petty_requests (
  id              uuid primary key default gen_random_uuid(),
  request_no      text unique,      -- P + 送出年月（台北）+ 當月流水號 4 碼，例：P2026110001
  applicant_id    uuid not null references auth.users(id),
  applicant_name  text not null,
  applicant_unit  text not null default '',
  fill_date       date not null,
  reason          text not null check (length(trim(reason)) > 0),
  amount          integer not null check (amount > 0 and amount <= 10000),
  note            text,
  status          text not null default 'pending'
                  check (status in ('pending', 'approved', 'rejected', 'printed', 'booked', 'returned')),
  submitted_at    timestamptz not null default now(),
  approver_id     uuid references auth.users(id),
  approver_name   text,
  approved_at     timestamptz,
  reject_reason   text,             -- 主管退回或管理者退回的原因
  rejected_at     timestamptz,
  disbursed_date  date,             -- 零用金核發日期（列印前選擇）
  printed_at      timestamptz,
  booked_at       timestamptz
);
-- 後加欄位（舊資料庫重跑本檔時補上）
alter table public.petty_requests add column if not exists archived_at timestamptz;  -- 照片已封存（雲端照片已刪）
-- 登記資料（管理者在「已核發」填，petty_save_booking 寫入）與試算表同步
alter table public.petty_requests add column if not exists category        text;        -- 類別（同試算表下拉選單）
alter table public.petty_requests add column if not exists payee_name      text;        -- 領收人（預設申請人）
alter table public.petty_requests add column if not exists sheet_synced_at timestamptz; -- 已寫入 Google 試算表
create index if not exists petty_requests_status_idx on public.petty_requests (status, submitted_at);
create index if not exists petty_requests_applicant_idx on public.petty_requests (applicant_id, submitted_at);

-- 申請編號的每月流水號（只由 trigger 使用，不開放讀寫）
create table if not exists public.petty_counters (
  month  text primary key,   -- YYYYMM
  last   integer not null
);

-- 憑證：每張都要有照片、日期、金額
create table if not exists public.petty_vouchers (
  id            bigint generated always as identity primary key,
  request_id    uuid not null references public.petty_requests(id) on delete cascade,
  voucher_date  date not null,
  amount        numeric not null check (amount > 0),
  photo_path    text not null,
  created_at    timestamptz not null default now()
);
alter table public.petty_vouchers add column if not exists receipt_no text;  -- 收據／發票號碼（管理者填，沒有填「無號碼」）
create index if not exists petty_vouchers_request_idx on public.petty_vouchers (request_id);
create index if not exists petty_vouchers_key_idx on public.petty_vouchers (voucher_date, amount);

-- 設定：keeper_name = 零用金負責人姓名
create table if not exists public.petty_settings (
  key    text primary key,
  value  text
);
insert into public.petty_settings (key, value) values ('keeper_name', '')  -- 在網頁「設定」頁填寫
on conflict (key) do nothing;
-- categories = 類別選項（一行一個，要和 Google 試算表的下拉選單一字不差），在網頁「設定」頁修改
insert into public.petty_settings (key, value) values ('categories', E'租金支出-商辦管理費\n文具用品\n旅費\n運費\n郵電費\n廣告費\n水電瓦斯費\n交際費\n雜項購置\n進出口費用\n交通費\n燃料費\n包裝費\n消耗費\n其他\n材料費-成本\n測試設備-設備')
on conflict (key) do nothing;

-- 密鑰：sheet_secret = Google 試算表 Apps Script 呼叫用的密碼。開 RLS、沒有 policy，網頁讀不到。
-- 在 SQL Editor 設定：insert into public.petty_secrets values ('sheet_secret', '<至少 16 字的亂碼>')
--                     on conflict (key) do update set value = excluded.value;
create table if not exists public.petty_secrets (
  key    text primary key,
  value  text not null
);

-- ─────────────────────────────────────────────
-- Trigger：新增申請時，申請人、姓名、單位、送出時間、狀態一律由資料庫決定
-- ─────────────────────────────────────────────
create or replace function public.petty_requests_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m     public.petty_members;
  v_ym  text := to_char(now() at time zone 'Asia/Taipei', 'YYYYMM');
  v_n   integer;
begin
  select * into m from public.petty_members where user_id = auth.uid() and active;
  if m.user_id is null then
    raise exception '你不是零用金系統的成員';
  end if;
  new.applicant_id   := m.user_id;
  new.applicant_name := m.name;
  new.applicant_unit := m.unit;
  new.submitted_at   := now();
  new.status         := 'pending';
  -- 同月份同時送出也不會重號（on conflict 會鎖住該月份那一列）
  insert into public.petty_counters (month, last) values (v_ym, 1)
  on conflict (month) do update set last = petty_counters.last + 1
  returning last into v_n;
  new.request_no     := 'P' || v_ym || lpad(v_n::text, 4, '0');
  new.approver_id    := null;
  new.approver_name  := null;
  new.approved_at    := null;
  new.reject_reason  := null;
  new.rejected_at    := null;
  new.disbursed_date := null;
  new.printed_at     := null;
  new.booked_at      := null;
  new.archived_at    := null;
  new.category       := null;
  new.payee_name     := null;
  new.sheet_synced_at := null;
  return new;
end $$;

drop trigger if exists petty_requests_before_insert on public.petty_requests;
create trigger petty_requests_before_insert
  before insert on public.petty_requests
  for each row execute function public.petty_requests_before_insert();

-- Trigger：修改申請時只允許依角色的狀態轉換，其他欄位一律保留原值
-- （在 SQL Editor 以後台身分修改時 auth.uid() 為 null，不受限制，方便人工修正；
--   petty_save_booking 設定 petty.internal 後也放行，由該函式自己檢查）
create or replace function public.petty_requests_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  v_role text := public.petty_role();
  r    public.petty_requests;
begin
  if uid is null or current_setting('petty.internal', true) = 'on' then
    return new;
  end if;
  if v_role is null then
    raise exception '你不是零用金系統的成員';
  end if;

  r := old;
  r.status := new.status;

  -- 主管可以核准自己的申請
  if v_role = 'approver' and old.status = 'pending' and new.status in ('approved', 'rejected') then
    r.approver_id   := uid;
    r.approver_name := (select name from public.petty_members where user_id = uid);
    if new.status = 'approved' then
      r.approved_at := now();
    else
      r.reject_reason := nullif(trim(new.reject_reason), '');
      if r.reject_reason is null then
        raise exception '請填寫退回原因';
      end if;
      r.rejected_at := now();
    end if;

  elsif v_role = 'admin' and old.status in ('approved', 'printed') and new.status = 'printed' then
    if new.disbursed_date is null then
      raise exception '請選擇零用金核發日期';
    end if;
    r.disbursed_date := new.disbursed_date;
    r.printed_at     := now();

  elsif v_role = 'admin' and old.status = 'printed' and new.status = 'booked' then
    if coalesce(trim(old.category), '') = '' then
      raise exception '申請 % 還沒選類別', old.request_no;
    end if;
    if coalesce(trim(old.payee_name), '') = '' then
      raise exception '申請 % 還沒填領收人', old.request_no;
    end if;
    if exists (select 1 from public.petty_vouchers v
               where v.request_id = old.id and coalesce(trim(v.receipt_no), '') = '') then
      raise exception '申請 % 還有憑證沒填收據號碼（沒有號碼請填「無號碼」）', old.request_no;
    end if;
    r.booked_at := now();

  -- 封存（網頁透過 petty_archive_month 整月一起做）：已登記滿 4 個月，或主管退回／已取消
  elsif v_role = 'admin' and old.status = new.status and old.status in ('booked', 'rejected', 'returned')
        and old.archived_at is null and new.archived_at is not null then
    if old.status = 'booked' and old.booked_at > now() - interval '4 months' then
      raise exception '已登記滿 4 個月才能封存';
    end if;
    r.archived_at := now();

  elsif v_role = 'admin' and old.status in ('pending', 'approved', 'printed') and new.status = 'returned' then
    r.reject_reason := nullif(trim(new.reject_reason), '');
    if r.reject_reason is null then
      raise exception '請填寫取消原因';
    end if;
    r.rejected_at := now();

  else
    raise exception '不允許的狀態變更：% → %', old.status, new.status;
  end if;

  return r;
end $$;

drop trigger if exists petty_requests_before_update on public.petty_requests;
create trigger petty_requests_before_update
  before update on public.petty_requests
  for each row execute function public.petty_requests_before_update();

-- ─────────────────────────────────────────────
-- 內部用：檢查並寫入憑證（只給 petty_submit、petty_add_vouchers 呼叫，網頁不能直接用）
-- 照片要先上傳到 petty/<申請人 user id>/<申請 id>/ 底下
-- ─────────────────────────────────────────────
create or replace function public.petty_insert_vouchers(p_request_id uuid, p_vouchers jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  v    jsonb;
  n    integer := 0;
begin
  if p_vouchers is null or jsonb_typeof(p_vouchers) = 'null' then
    return 0;
  end if;
  if jsonb_typeof(p_vouchers) <> 'array' then
    raise exception '憑證資料格式不正確';
  end if;
  for v in select * from jsonb_array_elements(p_vouchers) loop
    if v->>'date' is null or v->>'amount' is null then
      raise exception '每張憑證都要有日期和金額';
    end if;
    if coalesce(v->>'photo_path', '') not like uid::text || '/' || p_request_id::text || '/%'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'petty' and o.name = v->>'photo_path') then
      raise exception '憑證照片不存在或路徑不正確';
    end if;
    insert into public.petty_vouchers (request_id, voucher_date, amount, photo_path)
    values (p_request_id, (v->>'date')::date, (v->>'amount')::numeric, v->>'photo_path');
    n := n + 1;
  end loop;
  return n;
end $$;

-- ─────────────────────────────────────────────
-- RPC：送出申請（申請＋憑證在同一個交易內建立）；憑證選填，之後可用 petty_add_vouchers 補
-- p = { id, fill_date, reason, amount, note, vouchers: [{ date, amount, photo_path }] }
-- ─────────────────────────────────────────────
create or replace function public.petty_submit(p jsonb)
returns public.petty_requests language plpgsql security definer set search_path = public as $$
declare
  uid    uuid := auth.uid();
  rid    uuid := (p->>'id')::uuid;
  amt    numeric := (p->>'amount')::numeric;
  r      public.petty_requests;
begin
  if public.petty_role() is null then
    raise exception '你不是零用金系統的成員';
  end if;
  if amt is null or amt <= 0 or amt <> trunc(amt) then
    raise exception '申請金額要是大於 0 的整數';
  end if;
  if amt > 10000 then
    raise exception '申請金額不得高於 $10,000，請改填請款單';
  end if;

  insert into public.petty_requests (id, fill_date, reason, amount, note)
  values (rid, (p->>'fill_date')::date, trim(p->>'reason'), amt::integer, nullif(trim(p->>'note'), ''))
  returning * into r;

  perform public.petty_insert_vouchers(rid, p->'vouchers');
  return r;
end $$;

-- RPC：補憑證（申請人補自己的，管理者可替任何人補）；已登記、主管退回、已取消或已封存的不能再補。回傳新增張數
create or replace function public.petty_add_vouchers(p_request_id uuid, p_vouchers jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  r  public.petty_requests;
  n  integer;
begin
  if public.petty_role() is null then
    raise exception '你不是零用金系統的成員';
  end if;
  select * into r from public.petty_requests where id = p_request_id for update;
  -- 申請人補自己的；管理者可替任何人補（例如核准後才交來的車票）
  if r.id is null or (r.applicant_id <> auth.uid() and public.petty_role() <> 'admin') then
    raise exception '只能替自己的申請補憑證';
  end if;
  if r.status not in ('pending', 'approved', 'printed') or r.archived_at is not null then
    raise exception '這筆申請已經%，不能再補憑證', case r.status when 'booked' then '登記' when 'returned' then '取消' else '被主管退回' end;
  end if;
  n := public.petty_insert_vouchers(p_request_id, p_vouchers);
  if n = 0 then
    raise exception '請至少加一張憑證';
  end if;
  return n;
end $$;

-- RPC：哪幾組「日期＋憑證金額」已出現在未退回、未取消的申請裡（不回傳申請內容）
-- pairs = [{ date: 'YYYY-MM-DD', amount: 123 }]
create or replace function public.petty_duplicate_vouchers(pairs jsonb)
returns table (dup_date date, dup_amount numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if public.petty_role() is null then
    return;
  end if;
  return query
    select distinct v.voucher_date, v.amount
    from public.petty_vouchers v
    join public.petty_requests r on r.id = v.request_id
    join jsonb_to_recordset(pairs) as q(date date, amount numeric)
      on q.date = v.voucher_date and q.amount = v.amount
    where r.status not in ('rejected', 'returned');
end $$;

-- RPC：管理者用帳號加入（或更新）成員；沒有 @ 時補 @parttrail.local
create or replace function public.petty_add_member(p_login text, p_name text, p_unit text, p_role text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(p_login));
  v_uid   uuid;
begin
  if public.petty_role() is distinct from 'admin' then
    raise exception '只有管理者可以加入成員';
  end if;
  if position('@' in v_email) = 0 then
    v_email := v_email || '@parttrail.local';
  end if;
  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is null then
    raise exception '找不到帳號 %，請先在 Supabase 後台 Authentication → Add user 建立', v_email;
  end if;
  insert into public.petty_members (user_id, email, name, unit, role, active)
  values (v_uid, v_email, trim(p_name), coalesce(trim(p_unit), ''), p_role, true)
  on conflict (user_id) do update
    set email = excluded.email, name = excluded.name, unit = excluded.unit, role = excluded.role, active = true;
  return v_uid;
end $$;

-- RPC：封存一整個月（依申請編號的年月，p_month = 'YYYYMM'），回傳封存筆數。
-- 該月每一筆都要「已登記滿 4 個月」或「主管退回／已取消」才可以；網頁先下載 zip，再呼叫這個，最後刪雲端照片。
create or replace function public.petty_archive_month(p_month text)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_open  integer;
  v_n     integer;
begin
  if public.petty_role() is distinct from 'admin' then
    raise exception '只有管理者可以封存';
  end if;
  if p_month !~ '^\d{6}$' then
    raise exception '月份格式要是 YYYYMM';
  end if;
  select count(*) into v_open
  from public.petty_requests
  where request_no like 'P' || p_month || '%'
    and not (status in ('rejected', 'returned')
             or (status = 'booked' and booked_at <= now() - interval '4 months'));
  if v_open > 0 then
    raise exception '這個月還有 % 筆申請沒有結束（要已登記滿 4 個月，或主管退回／已取消），不能封存', v_open;
  end if;
  update public.petty_requests set archived_at = now()
  where request_no like 'P' || p_month || '%' and archived_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    raise exception '這個月沒有可以封存的申請';
  end if;
  return v_n;
end $$;

-- ─────────────────────────────────────────────
-- RPC：管理者登記前填類別、領收人、各憑證收據號碼（「待列印」或「已核發」、未封存）
-- p_receipts = [{ id: 憑證 id, receipt_no: '...' }]
-- ─────────────────────────────────────────────
create or replace function public.petty_save_booking(p_request_id uuid, p_category text, p_payee text, p_receipts jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  r  public.petty_requests;
  v  jsonb;
begin
  if public.petty_role() is distinct from 'admin' then
    raise exception '只有管理者可以登記';
  end if;
  select * into r from public.petty_requests where id = p_request_id for update;
  if r.id is null or r.status not in ('approved', 'printed') or r.archived_at is not null then
    raise exception '只有「待列印」或「已核發」的申請可以填登記資料';
  end if;
  perform set_config('petty.internal', 'on', true);
  update public.petty_requests
     set category = nullif(trim(p_category), ''), payee_name = nullif(trim(p_payee), '')
   where id = p_request_id;
  perform set_config('petty.internal', 'off', true);
  for v in select * from jsonb_array_elements(coalesce(p_receipts, '[]'::jsonb)) loop
    update public.petty_vouchers
       set receipt_no = nullif(trim(v->>'receipt_no'), '')
     where id = (v->>'id')::bigint and request_id = p_request_id;
  end loop;
end $$;

-- 檢查 Apps Script 傳來的密碼（內部用）
create or replace function public.petty_check_sheet_secret(p_secret text)
returns void language plpgsql stable security definer set search_path = public as $$
declare
  v_secret text := (select value from public.petty_secrets where key = 'sheet_secret');
begin
  if v_secret is null or length(v_secret) < 16 or p_secret is distinct from v_secret then
    raise exception '試算表同步密碼不正確';
  end if;
end $$;

-- RPC（Apps Script 用 anon key 呼叫）：已登記、還沒寫入試算表的申請，欄位已照試算表組好
create or replace function public.petty_sheet_pending(p_secret text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.petty_check_sheet_secret(p_secret);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',          r.id,
      'request_no',  r.request_no,
      'year',        to_char(r.disbursed_date, 'YYYY'),
      'date',        to_char(r.disbursed_date, 'YYYY/MM/DD'),
      'category',    coalesce(r.category, ''),
      'receipts',    coalesce((
                       select string_agg(
                         coalesce(v.receipt_no, '') || '(' || to_char(v.voucher_date, 'YYYY.MM.DD') || ') NT' ||
                         case when v.amount = trunc(v.amount) then to_char(v.amount, 'FM999,999,990')
                              else to_char(v.amount, 'FM999,999,990.00') end,
                         E'\n' order by v.id)
                       from public.petty_vouchers v where v.request_id = r.id), ''),
      'description', r.reason,
      'amount',      r.amount,
      'applicant',   r.applicant_name,
      'payee',       coalesce(r.payee_name, r.applicant_name),
      'approver',    coalesce(r.approver_name, ''),
      'note',        coalesce(r.note, '')
    ) order by r.booked_at, r.request_no)
    from public.petty_requests r
    where r.status = 'booked' and r.sheet_synced_at is null and r.disbursed_date is not null
  ), '[]'::jsonb);
end $$;

-- RPC（Apps Script）：標記已寫入試算表，回傳筆數
create or replace function public.petty_sheet_done(p_secret text, p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  perform public.petty_check_sheet_secret(p_secret);
  perform set_config('petty.internal', 'on', true);
  update public.petty_requests set sheet_synced_at = now()
   where id = any(p_ids) and status = 'booked' and sheet_synced_at is null;
  get diagnostics n = row_count;
  perform set_config('petty.internal', 'off', true);
  return n;
end $$;

revoke execute on function public.petty_archive_month(text) from public, anon;
grant execute on function public.petty_archive_month(text) to authenticated;
revoke execute on function public.petty_insert_vouchers(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.petty_add_vouchers(uuid, jsonb) from public, anon;
grant execute on function public.petty_add_vouchers(uuid, jsonb) to authenticated;
revoke execute on function public.petty_submit(jsonb) from public, anon;
revoke execute on function public.petty_duplicate_vouchers(jsonb) from public, anon;
revoke execute on function public.petty_add_member(text, text, text, text) from public, anon;
grant execute on function public.petty_submit(jsonb) to authenticated;
grant execute on function public.petty_duplicate_vouchers(jsonb) to authenticated;
grant execute on function public.petty_add_member(text, text, text, text) to authenticated;
revoke execute on function public.petty_save_booking(uuid, text, text, jsonb) from public, anon;
grant execute on function public.petty_save_booking(uuid, text, text, jsonb) to authenticated;
revoke execute on function public.petty_check_sheet_secret(text) from public, anon, authenticated;
revoke execute on function public.petty_sheet_pending(text) from public, authenticated;
revoke execute on function public.petty_sheet_done(text, uuid[]) from public, authenticated;
grant execute on function public.petty_sheet_pending(text) to anon;
grant execute on function public.petty_sheet_done(text, uuid[]) to anon;

-- ─────────────────────────────────────────────
-- RLS（前端不可信任）
-- ─────────────────────────────────────────────
alter table public.petty_members  enable row level security;
alter table public.petty_requests enable row level security;
alter table public.petty_vouchers enable row level security;
alter table public.petty_settings enable row level security;
alter table public.petty_counters enable row level security;  -- 沒有 policy：網頁讀寫不到
alter table public.petty_secrets  enable row level security;  -- 沒有 policy：網頁讀寫不到

-- 成員：自己看得到自己那一列；管理者可讀寫全部
drop policy if exists "petty members read" on public.petty_members;
create policy "petty members read" on public.petty_members
  for select using (user_id = auth.uid() or public.petty_role() = 'admin');
drop policy if exists "petty members admin write" on public.petty_members;
create policy "petty members admin write" on public.petty_members
  for all using (public.petty_role() = 'admin') with check (public.petty_role() = 'admin');

-- 申請：申請人只讀自己的；主管、管理者讀全部；新增只能透過 petty_submit
drop policy if exists "petty requests read" on public.petty_requests;
create policy "petty requests read" on public.petty_requests
  for select using (
    (applicant_id = auth.uid() and public.petty_role() is not null)
    or public.petty_role() in ('approver', 'admin')
  );
-- 修改：只有主管、管理者；能改什麼由 petty_requests_before_update 決定
drop policy if exists "petty requests review" on public.petty_requests;
create policy "petty requests review" on public.petty_requests
  for update using (public.petty_role() in ('approver', 'admin'))
  with check (public.petty_role() in ('approver', 'admin'));

-- 憑證：看得到申請就看得到憑證；新增只能透過 petty_submit、petty_add_vouchers
drop policy if exists "petty vouchers read" on public.petty_vouchers;
create policy "petty vouchers read" on public.petty_vouchers
  for select using (exists (select 1 from public.petty_requests r where r.id = request_id));

-- 設定：成員可讀，管理者可寫
drop policy if exists "petty settings read" on public.petty_settings;
create policy "petty settings read" on public.petty_settings
  for select using (public.petty_role() is not null);
drop policy if exists "petty settings admin write" on public.petty_settings;
create policy "petty settings admin write" on public.petty_settings
  for all using (public.petty_role() = 'admin') with check (public.petty_role() = 'admin');

-- ─────────────────────────────────────────────
-- Storage：私有 bucket「petty」，路徑 <申請人 user id>/<申請 id>/n.jpg
-- ─────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('petty', 'petty', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "petty photo upload" on storage.objects;
create policy "petty photo upload" on storage.objects
  for insert to authenticated with check (
    bucket_id = 'petty'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.petty_role() is not null
  );

drop policy if exists "petty photo read" on storage.objects;
create policy "petty photo read" on storage.objects
  for select to authenticated using (
    bucket_id = 'petty'
    and (
      ((storage.foldername(name))[1] = auth.uid()::text and public.petty_role() is not null)
      or public.petty_role() in ('approver', 'admin')
      -- 管理者替申請人補的照片放在管理者的資料夾，申請人也要看得到
      or (public.petty_role() is not null and exists (
            select 1 from public.petty_vouchers v
            join public.petty_requests r on r.id = v.request_id
            where v.photo_path = storage.objects.name and r.applicant_id = auth.uid()))
    )
  );

-- 送出失敗時，申請人可刪掉自己還沒掛到憑證的照片
drop policy if exists "petty photo delete" on storage.objects;
create policy "petty photo delete" on storage.objects
  for delete to authenticated using (
    bucket_id = 'petty'
    and (storage.foldername(name))[1] = auth.uid()::text
    and public.petty_role() is not null
    and not exists (select 1 from public.petty_vouchers v where v.photo_path = storage.objects.name)
  );

-- 封存後，管理者可刪掉該申請的雲端照片
drop policy if exists "petty photo archive delete" on storage.objects;
create policy "petty photo archive delete" on storage.objects
  for delete to authenticated using (
    bucket_id = 'petty'
    and public.petty_role() = 'admin'
    and exists (
      select 1 from public.petty_vouchers v
      join public.petty_requests r on r.id = v.request_id
      where v.photo_path = storage.objects.name and r.archived_at is not null
    )
  );
