-- SISTEMA MEJÍA — corrección de identificación de responsables
-- SOLO proyecto Supabase de PRUEBAS: vrgfwefnkrdwrtdymfin
-- Complementa actualizacion_integral_v2.sql. No modificar ventas históricas.
begin;

-- Asignar código a perfiles administradores que también pueden registrar ventas.
-- Se conservan intactos los códigos existentes y los roles actuales.
update public.profiles
set seller_code = case
  when role = 'vendedor' then 'VEN-' || upper(substr(replace(id::text, '-', ''), 1, 12))
  when role = 'admin' then 'ADM-' || upper(substr(replace(id::text, '-', ''), 1, 12))
  else seller_code
end
where role in ('vendedor', 'admin')
  and (seller_code is null or btrim(seller_code) = '');

-- Para cuentas nuevas o cambios de rol, asignar automáticamente un código único.
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
      || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));
  end if;
  return new;
end;
$$;

-- La función solo se ejecuta mediante el trigger ya existente.
revoke all on function public.assign_seller_code() from public, anon, authenticated;

-- El trigger snapshot_sale_seller de v2 ya toma el código del perfil
-- indicado por seller_id o created_by. No se reescriben ventas históricas.

commit;

-- Verificación de solo lectura:
-- select role, count(*) as perfiles,
--        count(*) filter (where seller_code is not null and btrim(seller_code) <> '') as con_codigo,
--        count(distinct seller_code) as codigos_unicos
-- from public.profiles
-- where role in ('vendedor','admin')
-- group by role
-- order by role;
