-- 2026-11-02 更新：登記資料（類別、領收人、收據號碼）在「待列印」時就可以填。
-- 在 SQL Editor 執行即可（可重複執行）；只替換 petty_save_booking，不必跑 check_parttrail.sql。

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
