-- 2026-11-04 更新：管理頁簡化。列印不再改狀態，已核准可以直接登記；
-- 登記時把登記當天（台北）存進 disbursed_date，試算表「日期」欄用這個日期。
-- 在 SQL Editor 執行這份即可（可重複執行）；只替換兩個函式，不動資料表與資料；內容和 petty_schema.sql 一致。

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

  -- 登記：已核准（或舊資料的已核發）→ 已登記；試算表「日期」用登記當天（台北），存在 disbursed_date
  elsif v_role = 'admin' and old.status in ('approved', 'printed') and new.status = 'booked' then
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
    r.disbursed_date := (now() at time zone 'Asia/Taipei')::date;

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
  if r.id is null or r.status not in ('approved', 'printed') or r.archived_at is not null then
    raise exception '只有「已核准」且還沒登記的申請可以填登記資料';
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
