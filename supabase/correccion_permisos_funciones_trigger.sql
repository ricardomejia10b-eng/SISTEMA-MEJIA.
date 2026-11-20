-- SISTEMA MEJIA — restringir funciones internas de triggers
-- Entorno de PRUEBAS y futura migracion controlada.
-- Estas funciones se ejecutan por sus triggers; no deben exponerse como RPC.
-- No modifica datos ni elimina/recrea triggers.

begin;

revoke all on function public.snapshot_sale_seller() from public, anon, authenticated;
revoke all on function public.set_credit_status() from public, anon, authenticated;

commit;

-- Verificacion:
-- select p.proname,
--   has_function_privilege('anon', p.oid, 'EXECUTE') as anon_exec,
--   has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_exec
-- from pg_proc p
-- join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public'
--   and p.proname in ('snapshot_sale_seller', 'set_credit_status');
--
-- Los triggers existentes deben permanecer instalados y seguir ejecutandose.
