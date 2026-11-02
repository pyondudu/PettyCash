-- 2026-11-02 更新：登記資料（類別、領收人、收據號碼）與 Google 試算表同步。
-- 已經執行過 petty_schema.sql 的資料庫，在 SQL Editor 執行這份即可（可重複執行）；
-- 只新增／修改 petty_ 開頭的表、欄位與函式，不影響 PartTrail（不必跑 check_parttrail.sql）。
-- 內容和 petty_schema.sql 一致。執行完請再執行最下面「設定同步密碼」那段（換成您自己的亂碼）。

alter table public.petty_requests add column if not exists category        text;        -- 類別（同試算表下拉選單）
alter table public.petty_requests add column if not exists payee_name      text;        -- 領收人（預設申請人）
alter table public.petty_requests add column if not exists sheet_synced_at timestamptz; -- 已寫入 Google 試算表
alter table public.petty_vouchers add column if not exists receipt_no text;  -- 收據／發票號碼（管理者填，沒有填「無號碼」）

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
alter table public.petty_secrets enable row level security;  -- 沒有 policy：網頁讀寫不到

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
  if r.id is null or r.status <> 'printed' or r.archived_at is not null then
    raise exception '只有「已核發」的申請可以填登記資料';
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

create or replace function public.petty_check_sheet_secret(p_secret text)
returns void language plpgsql stable security definer set search_path = public as $$
declare
  v_secret text := (select value from public.petty_secrets where key = 'sheet_secret');
begin
  if v_secret is null or length(v_secret) < 16 or p_secret is distinct from v_secret then
    raise exception '試算表同步密碼不正確';
  end if;
end $$;

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

revoke execute on function public.petty_save_booking(uuid, text, text, jsonb) from public, anon;
grant execute on function public.petty_save_booking(uuid, text, text, jsonb) to authenticated;
revoke execute on function public.petty_check_sheet_secret(text) from public, anon, authenticated;
revoke execute on function public.petty_sheet_pending(text) from public, authenticated;
revoke execute on function public.petty_sheet_done(text, uuid[]) from public, authenticated;
grant execute on function public.petty_sheet_pending(text) to anon;
grant execute on function public.petty_sheet_done(text, uuid[]) to anon;

-- ─────────────────────────────────────────────
-- 設定同步密碼：把 <換成至少 16 字的亂碼> 換掉後執行，同一組密碼之後要填到 Apps Script
-- ─────────────────────────────────────────────
-- insert into public.petty_secrets (key, value) values ('sheet_secret', '<換成至少 16 字的亂碼>')
-- on conflict (key) do update set value = excluded.value;
