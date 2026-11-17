-- SISTEMA MEJÍA — corrección de identificación de responsables
-- SOLO proyecto Supabase de PRUEBAS: vrgfwefnkrdwrtdymfin
-- Complementa actualizacion_integral_v2.sql. No modificar ventas históricas.
begin;

-- Asignar código a perfiles vendedores o administradores que aún no lo tengan.
-- El identificador se deriva del UUID del perfil y es estable e irrepetible
-- para perfiles distintos. Se conservan códigos ya asignados y los roles.
update public.profiles
set seller_code = case
  when role = 'vendedor' then 'VEN-' || upper(substr(replace(id::text, '-', ''), 1, 12))
  when role = 'admin' then 'ADM-' || upper(substr(replace(id::text, '-', ''), 1, 12))
  else seller_code
end
where role in ('vendedor', 'admin')
  and (seller_code is null or btrim(seller_code) = '');

-- IMPORTANTE: actualizacion_integral_v2.sql crea el trigger
-- assign_seller_code_on_profile, que ejecuta public.assign_seller_code().
-- Se reemplaza ESA MISMA función para que tanto vendedores como admins
-- reciban código al crear el perfil o cambiar su rol, sin cambiar códigos previos.
create or replace function public.assign_seller_code()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role in ('vendedor', 'admin')
     and (new.seller_code is null or btrim(new.seller_code) = '') then
    new.seller_code :=
      case when new.role = 'admin' then 'ADM-' else 'VEN-' end
      || upper(substr(replace(new.id::text, '-', ''), 1, 12));
  end if;
  return new;
end;
$$;

-- La función se ejecuta únicamente mediante el trigger ya existente.
revoke all on function public.assign_seller_code() from public, anon, authenticated;

-- El trigger snapshot_sale_seller de v2 copia nombre y código del perfil
-- cuyo UUID sea coalesce(seller_id, created_by). Por ello también cubre
-- ventas registradas por una cuenta admin. No se reescriben ventas históricas.

commit;

-- Verificación de solo lectura:
-- select role, count(*) as perfiles,
--        count(*) filter (where seller_code is not null and btrim(seller_code) <> '') as con_codigo,
--        count(distinct seller_code) as codigos_unicos
-- from public.profiles
-- where role in ('vendedor','admin')
-- group by role
-- order by role;
--
-- select tgname, pg_get_triggerdef(oid)
-- from pg_trigger
-- where tgrelid = 'public.profiles'::regclass and not tgisinternal
-- order by tgname;
