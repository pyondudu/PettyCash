-- 2026-11-02 更新：申請可以先存成草稿（只有本人看得到、可修改或刪除），確定後再送出；送出時才給申請編號。
-- 在 SQL Editor 執行即可（可重複執行）；只改 petty_ 開頭的表、函式與規則，不必跑 check_parttrail.sql。

-- 狀態與必填檢查（草稿 draft 可以還沒填事由、金額；送出後才給申請編號）
alter table public.petty_requests drop constraint if exists petty_requests_status_check;
alter table public.petty_requests add constraint petty_requests_status_check
  check (status in ('draft', 'pending', 'approved', 'rejected', 'printed', 'booked', 'returned'));
alter table public.petty_requests drop constraint if exists petty_requests_reason_check;
alter table public.petty_requests add constraint petty_requests_reason_check
  check (status = 'draft' or length(trim(reason)) > 0);
alter table public.petty_requests alter column amount drop not null;
alter table public.petty_requests alter column reason set default '';
alter table public.petty_requests drop constraint if exists petty_requests_amount_check;
alter table public.petty_requests add constraint petty_requests_amount_check
  check ((status = 'draft' and amount is null) or (amount > 0 and amount <= 10000));

create or replace function public.petty_next_request_no()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_ym  text := to_char(now() at time zone 'Asia/Taipei', 'YYYYMM');
  v_n   integer;
begin
  insert into public.petty_counters (month, last) values (v_ym, 1)
  on conflict (month) do update set last = petty_counters.last + 1
  returning last into v_n;
  return 'P' || v_ym || lpad(v_n::text, 4, '0');
end $$;

create or replace function public.petty_requests_before_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  m     public.petty_members;
begin
  select * into m from public.petty_members where user_id = auth.uid() and active;
  if m.user_id is null then
    raise exception '你不是零用金系統的成員';
  end if;
  new.applicant_id   := m.user_id;
  new.applicant_name := m.name;
  new.applicant_unit := m.unit;
  new.submitted_at   := now();
  if new.status = 'draft' then
    new.request_no := null;
  else
    new.status     := 'pending';
    new.request_no := public.petty_next_request_no();
  end if;
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

create or replace function public.petty_save_draft(p jsonb)
returns public.petty_requests language plpgsql security definer set search_path = public as $$
declare
  uid  uuid := auth.uid();
  rid  uuid := (p->>'id')::uuid;
  amt  numeric := nullif(p->>'amount', '')::numeric;
  r    public.petty_requests;
begin
  if public.petty_role() is null then
    raise exception '你不是零用金系統的成員';
  end if;
  if amt is not null and (amt <= 0 or amt <> trunc(amt)) then
    raise exception '申請金額要是大於 0 的整數';
  end if;
  if amt > 10000 then
    raise exception '申請金額不得高於 $10,000，請改填請款單';
  end if;

  select * into r from public.petty_requests where id = rid for update;
  if r.id is null then
    insert into public.petty_requests (id, fill_date, reason, amount, note, status)
    values (rid, coalesce((p->>'fill_date')::date, (now() at time zone 'Asia/Taipei')::date),
            coalesce(trim(p->>'reason'), ''), amt::integer, nullif(trim(p->>'note'), ''), 'draft');
  else
    if r.applicant_id <> uid or r.status <> 'draft' then
      raise exception '只能修改自己還沒送出的申請';
    end if;
    perform set_config('petty.internal', 'on', true);
    update public.petty_requests
       set fill_date = coalesce((p->>'fill_date')::date, fill_date),
           reason    = coalesce(trim(p->>'reason'), ''),
           amount    = amt::integer,
           note      = nullif(trim(p->>'note'), '')
     where id = rid;
    perform set_config('petty.internal', 'off', true);
    delete from public.petty_vouchers
     where request_id = rid
       and id in (select value::bigint from jsonb_array_elements_text(coalesce(p->'remove_voucher_ids', '[]'::jsonb)));
  end if;

  perform public.petty_insert_vouchers(rid, p->'vouchers');
  select * into r from public.petty_requests where id = rid;
  return r;
end $$;

create or replace function public.petty_submit_draft(p_id uuid)
returns public.petty_requests language plpgsql security definer set search_path = public as $$
declare
  r  public.petty_requests;
begin
  select * into r from public.petty_requests where id = p_id for update;
  if r.id is null or r.applicant_id <> auth.uid() or r.status <> 'draft' or public.petty_role() is null then
    raise exception '只能送出自己還沒送出的申請';
  end if;
  if length(trim(r.reason)) = 0 then
    raise exception '請填寫申請事由';
  end if;
  if r.amount is null then
    raise exception '請填寫申請金額';
  end if;
  perform set_config('petty.internal', 'on', true);
  update public.petty_requests
     set status = 'pending', request_no = public.petty_next_request_no(), submitted_at = now()
   where id = p_id
  returning * into r;
  perform set_config('petty.internal', 'off', true);
  return r;
end $$;

create or replace function public.petty_delete_draft(p_id uuid)
returns text[] language plpgsql security definer set search_path = public as $$
declare
  r      public.petty_requests;
  paths  text[];
begin
  select * into r from public.petty_requests where id = p_id for update;
  if r.id is null or r.applicant_id <> auth.uid() or r.status <> 'draft' then
    raise exception '只能刪除自己還沒送出的申請';
  end if;
  select coalesce(array_agg(photo_path), '{}') into paths from public.petty_vouchers where request_id = p_id;
  delete from public.petty_requests where id = p_id;   -- 憑證跟著刪（on delete cascade）
  return paths;
end $$;

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
    where r.status not in ('rejected', 'returned', 'draft');
end $$;

drop policy if exists "petty requests read" on public.petty_requests;
create policy "petty requests read" on public.petty_requests
  for select using (
    (applicant_id = auth.uid() and public.petty_role() is not null)
    or (public.petty_role() in ('approver', 'admin') and status <> 'draft')  -- 草稿只有本人看得到
  );

revoke execute on function public.petty_next_request_no() from public, anon, authenticated;
revoke execute on function public.petty_save_draft(jsonb) from public, anon;
revoke execute on function public.petty_submit_draft(uuid) from public, anon;
revoke execute on function public.petty_delete_draft(uuid) from public, anon;
grant execute on function public.petty_save_draft(jsonb) to authenticated;
grant execute on function public.petty_submit_draft(uuid) to authenticated;
grant execute on function public.petty_delete_draft(uuid) to authenticated;
