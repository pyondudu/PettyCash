-- 檢查 PartTrail 的物件有沒有被動到：執行 petty_schema.sql 前後各跑一次，兩次結果應完全相同。
-- 只統計「不是 petty_ 開頭」的表、欄位、函式、trigger、policy 和 Storage bucket。
-- catalog 欄位（name、"char"、sql_identifier）一律先轉 ::text 再串接。
select 'tables' as kind, count(*) as n,
       md5(string_agg(table_name::text, ',' order by table_name::text)) as fingerprint
from information_schema.tables
where table_schema = 'public' and table_name::text not like 'petty\_%'
union all
select 'columns', count(*),
       md5(string_agg(table_name::text || '.' || column_name::text || ':' || data_type::text || ':' ||
           coalesce(column_default::text, ''), ',' order by table_name::text, column_name::text))
from information_schema.columns
where table_schema = 'public' and table_name::text not like 'petty\_%'
union all
select 'functions', count(*),
       md5(string_agg(p.proname::text || ':' || md5(p.prosrc) || ':' || p.prosecdef::text, ','
           order by p.proname::text, p.oid))
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname::text not like 'petty\_%'
union all
select 'triggers', count(*),
       md5(string_agg(c.relname::text || '.' || t.tgname::text || ':' || t.tgenabled::text, ','
           order by c.relname::text, t.tgname::text))
from pg_trigger t join pg_class c on c.oid = t.tgrelid
where not t.tgisinternal and t.tgname::text not like 'petty\_%'
union all
select 'policies', count(*),
       md5(string_agg(schemaname::text || '.' || tablename::text || '.' || policyname::text || ':' || cmd::text || ':' ||
           coalesce(qual, '') || ':' || coalesce(with_check, ''), ','
           order by schemaname::text, tablename::text, policyname::text))
from pg_policies
where schemaname in ('public', 'storage') and tablename::text not like 'petty\_%' and policyname::text not like 'petty %'
union all
select 'buckets', count(*),
       md5(string_agg(id::text || ':' || public::text, ',' order by id::text))
from storage.buckets
where id <> 'petty';
