-- 2026-11-02 更新：狀態名稱「已列印」改為「已核發」、「已入帳」改為「已登記」，錯誤訊息跟著改。
-- 已經執行過 petty_schema.sql 的資料庫，在 SQL Editor 執行這份即可（可重複執行）；
-- 只替換三個 petty_ 函式的內容，不動資料表與資料，也不影響 PartTrail（不必跑 check_parttrail.sql）。

create or replace function public.petty_requests_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  v_role text := public.petty_role();
  r    public.petty_requests;
begin
  if uid is null then
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
  if r.id is null or r.applicant_id <> auth.uid() then
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
