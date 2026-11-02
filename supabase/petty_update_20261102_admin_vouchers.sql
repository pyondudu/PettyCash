-- 2026-11-02 更新：管理者可以替申請人補憑證；申請人也看得到管理者替他補的照片。
-- 在 SQL Editor 執行即可（可重複執行）；只替換 petty_add_vouchers 和 petty 的照片讀取規則，不必跑 check_parttrail.sql。

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
