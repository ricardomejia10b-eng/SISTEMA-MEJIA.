-- SISTEMA MEJIA — endurecimiento de seguridad para el entorno de PRUEBAS
-- Ejecutar únicamente después de crear las tablas y funciones del esquema de pruebas.
-- No ejecutar en producción. No modifica datos ni elimina funciones.
-- Corrige EXECUTE de funciones SECURITY DEFINER y evita autoasignación de rol admin.

begin;

-- Verificar que las funciones esperadas existen antes de cambiar permisos.
do $check$
begin
  if to_regprocedure('public.close_cash_session(uuid,numeric,numeric,text)') is null
     or to_regprocedure('public.finalize_sale(uuid,text,text,jsonb,jsonb)') is null
     or to_regprocedure('public.finalize_sale_v2(uuid,text,text,text,text,jsonb,jsonb)') is null
     or to_regprocedure('public.get_cash_session_summary(uuid)') is null
     or to_regprocedure('public.is_admin()') is null
     or to_regprocedure('public.open_cash_session(numeric)') is null
     or to_regprocedure('public.register_payment(uuid,numeric,text,text)') is null then
    raise exception 'Faltan funciones del esquema esperado. No se aplicaron cambios de permisos.';
  end if;
end
$check$;

revoke all on function public.close_cash_session(uuid,numeric,numeric,text) from public, anon;
revoke all on function public.finalize_sale(uuid,text,text,jsonb,jsonb) from public, anon;
revoke all on function public.finalize_sale_v2(uuid,text,text,text,text,jsonb,jsonb) from public, anon;
revoke all on function public.get_cash_session_summary(uuid) from public, anon;
revoke all on function public.is_admin() from public, anon;
revoke all on function public.open_cash_session(numeric) from public, anon;
revoke all on function public.register_payment(uuid,numeric,text,text) from public, anon;

grant execute on function public.close_cash_session(uuid,numeric,numeric,text) to authenticated;
grant execute on function public.finalize_sale(uuid,text,text,jsonb,jsonb) to authenticated;
grant execute on function public.finalize_sale_v2(uuid,text,text,text,text,jsonb,jsonb) to authenticated;
grant execute on function public.get_cash_session_summary(uuid) to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.open_cash_session(numeric) to authenticated;
grant execute on function public.register_payment(uuid,numeric,text,text) to authenticated;

-- Impedir que un vendedor se eleve a administrador editando su propio perfil.
-- Un administrador existente conserva la capacidad de asignar/cambiar roles.
create or replace function public.prevent_profile_role_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if new.role is distinct from old.role and not public.is_admin() then
    raise exception 'No tienes permiso para modificar el rol del perfil';
  end if;
  return new;
end
$function$;

drop trigger if exists protect_profile_role on public.profiles;
create trigger protect_profile_role
before update of role on public.profiles
for each row
execute function public.prevent_profile_role_escalation();

revoke all on function public.prevent_profile_role_escalation() from public, anon, authenticated;

commit;

-- Verificación posterior:
-- SELECT p.oid::regprocedure AS funcion,
--        has_function_privilege('anon',p.oid,'EXECUTE') AS anon_ejecuta,
--        has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated_ejecuta
-- FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
-- WHERE n.nspname='public' AND p.proname IN
-- ('close_cash_session','finalize_sale','finalize_sale_v2',
--  'get_cash_session_summary','is_admin','open_cash_session','register_payment')
-- ORDER BY p.proname;
