-- Verificación posterior al bootstrap de SISTEMA MEJIA.
-- Ejecutar en SQL Editor del proyecto de PRUEBAS vrgfwefnkrdwrtdymfin.
-- Consulta de solo lectura.

-- 1) Las nueve tablas esperadas
select table_name
from information_schema.tables
where table_schema='public'
  and table_name in (
    'profiles','products','customers','sales','sale_items','payments',
    'cash_sessions','cash_movements','cash_registers'
  )
order by table_name;

-- 2) Todas las tablas con RLS habilitado
select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public'
  and c.relname in (
    'profiles','products','customers','sales','sale_items','payments',
    'cash_sessions','cash_movements','cash_registers'
  )
order by c.relname;

-- 3) Conteo y nombres de políticas
select schemaname, tablename, policyname, roles, cmd
from pg_policies
where schemaname in ('public','storage')
  and (
    tablename in (
      'profiles','products','customers','sales','sale_items','payments',
      'cash_sessions','cash_movements','cash_registers'
    )
    or (schemaname='storage' and tablename='objects' and policyname like 'product images%')
  )
order by schemaname, tablename, policyname;

-- 4) Funciones y permisos efectivos: anon debe ser false y authenticated true
select
  p.oid::regprocedure as funcion,
  p.prosecdef as security_definer,
  has_function_privilege('anon',p.oid,'EXECUTE') as anon_ejecuta,
  has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_ejecuta
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in (
    'close_cash_session','finalize_sale','finalize_sale_v2',
    'get_cash_session_summary','is_admin','open_cash_session','register_payment'
  )
order by p.proname;

-- 5) Bucket de imágenes
select id,name,public
from storage.buckets
where id='product-images';

-- 6) Trigger de perfil automático y protección de rol
select
  tgname,
  tgrelid::regclass as table_name,
  pg_get_triggerdef(oid) as definition
from pg_trigger
where not tgisinternal
  and tgname in ('create_profile_after_signup','protect_profile_role')
order by tgname;

-- Resultado esperado:
-- * 9 tablas, todas con RLS habilitado.
-- * 7 funciones de negocio, anon_ejecuta=false, authenticated_ejecuta=true.
-- * Bucket product-images, public=true.
-- * Dos triggers: perfil automático (rol vendedor) y protección de rol.
