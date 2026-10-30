-- 2026-10-30 更新：憑證改成選填，申請人可在入帳前補憑證。
-- 已經執行過 petty_schema.sql 的資料庫，在 SQL Editor 執行這份即可（可重複執行）；
-- 內容和 petty_schema.sql 裡的同名函式一致。

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

-- RPC：申請人替自己的申請補憑證；已入帳、已退回或已封存的不能再補。回傳新增張數
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
    raise exception '這筆申請已經%，不能再補憑證', case r.status when 'booked' then '入帳' else '退回' end;
  end if;
  n := public.petty_insert_vouchers(p_request_id, p_vouchers);
  if n = 0 then
    raise exception '請至少加一張憑證';
  end if;
  return n;
end $$;

revoke execute on function public.petty_insert_vouchers(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.petty_add_vouchers(uuid, jsonb) from public, anon;
grant execute on function public.petty_add_vouchers(uuid, jsonb) to authenticated;
revoke execute on function public.petty_submit(jsonb) from public, anon;
grant execute on function public.petty_submit(jsonb) to authenticated;
