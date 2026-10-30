-- 唯讀檢查（不會修改任何東西）：
-- A. petty_schema.sql 是否完整建立；B. 列出 PartTrail（非 petty）的 policy，確認沒有被改到。
-- 結果欄位：區塊、項目、數量、內容

-- A. PettyCash 物件（預期：表 5、函式 9、trigger 2、policy public 7＋storage 4、bucket 1、零用金負責人有值）
select 'A' as 區塊, 'petty 表（應 5）' as 項目, count(*)::int as 數量,
       string_agg(table_name::text, '、' order by table_name::text) as 內容
from information_schema.tables
where table_schema = 'public' and table_name::text like 'petty\_%'
union all
select 'A', 'petty 函式（應 9）', count(*)::int,
       string_agg(p.proname::text, '、' order by p.proname::text)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname::text like 'petty\_%'
union all
select 'A', 'petty trigger（應 2）', count(*)::int,
       string_agg(c.relname::text || '.' || t.tgname::text, '、' order by t.tgname::text)
from pg_trigger t join pg_class c on c.oid = t.tgrelid
where not t.tgisinternal and t.tgname::text like 'petty\_%'
union all
select 'A', 'petty policy（public 應 7）', count(*)::int,
       string_agg(tablename::text || '：' || policyname::text, '、' order by tablename::text, policyname::text)
from pg_policies
where schemaname = 'public' and tablename::text like 'petty\_%'
union all
select 'A', 'petty policy（storage 應 4）', count(*)::int,
       string_agg(policyname::text, '、' order by policyname::text)
from pg_policies
where schemaname = 'storage' and policyname::text like 'petty %'
union all
select 'A', 'bucket petty（應 1，public=false）', count(*)::int,
       string_agg(id::text || ' public=' || public::text, '、')
from storage.buckets
where id = 'petty'
union all
select 'A', '零用金負責人', count(*)::int, string_agg(value, '、')
from public.petty_settings
where key = 'keeper_name'

-- B. 非 petty 的 policy：應該只有 PartTrail 原本的，而且條件裡都不會出現 petty
union all
select 'B', schemaname::text || '.' || tablename::text || '：' || policyname::text, 1,
       cmd::text || ' ／ ' || coalesce(qual, '') || coalesce(' ／ check: ' || with_check, '')
from pg_policies
where schemaname in ('public', 'storage') and tablename::text not like 'petty\_%' and policyname::text not like 'petty %'
union all
select 'B', '非 petty 的 policy 條件提到 petty（應 0）', count(*)::int, string_agg(policyname::text, '、')
from pg_policies
where schemaname in ('public', 'storage') and tablename::text not like 'petty\_%' and policyname::text not like 'petty %'
  and (coalesce(qual, '') ilike '%petty%' or coalesce(with_check, '') ilike '%petty%')
order by 1, 2;
