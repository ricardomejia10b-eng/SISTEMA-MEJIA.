-- SISTEMA MEJÍA — unidades de medida y presentaciones (fase 1: estructura)
-- SOLO entorno de PRUEBAS. Esta migración es aditiva y NO modifica stock ni ventas existentes.
-- No ejecutar en producción. Revisar y probar antes de aplicarla.

begin;

-- La unidad base se define explícitamente por producto. Los productos existentes
-- permanecen sin configurar hasta que un administrador elija su unidad real.
alter table public.products
  add column if not exists base_unit text,
  add column if not exists unit_configured boolean not null default false;

alter table public.sale_items
  add column if not exists unit_id uuid,
  add column if not exists unit_name_snapshot text,
  add column if not exists quantity_in_unit numeric(18,6),
  add column if not exists quantity_in_base numeric(18,6),
  add column if not exists conversion_factor_snapshot numeric(18,6);

alter table public.inventory_movements
  add column if not exists unit_name text,
  add column if not exists quantity_in_unit numeric(18,6),
  add column if not exists quantity_change_base numeric(18,6),
  add column if not exists conversion_factor numeric(18,6),
  add column if not exists stock_after_base numeric(18,6);

create table if not exists public.product_units (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete cascade,
  unit_name text not null,
  factor_to_base numeric(18,6) not null,
  is_base boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  constraint product_units_name_nonempty check (length(btrim(unit_name)) > 0),
  constraint product_units_factor_positive check (factor_to_base > 0),
  constraint product_units_base_factor check (not is_base or factor_to_base = 1),
  constraint product_units_product_name_unique unique(product_id, unit_name)
);

create unique index if not exists product_units_one_base_per_product
  on public.product_units(product_id) where is_base;

create index if not exists product_units_product_active_idx
  on public.product_units(product_id, is_active);

alter table public.sale_items
  drop constraint if exists sale_items_unit_id_fkey;
alter table public.sale_items
  add constraint sale_items_unit_id_fkey
  foreign key (unit_id) references public.product_units(id) on delete set null;

alter table public.product_units enable row level security;

drop policy if exists "product units read authenticated" on public.product_units;
create policy "product units read authenticated"
  on public.product_units for select to authenticated
  using (true);

drop policy if exists "product units admin manage" on public.product_units;
create policy "product units admin manage"
  on public.product_units for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

grant select on public.product_units to authenticated;
revoke insert, update, delete on public.product_units from anon, authenticated;

-- Configuración atómica de las presentaciones de un producto.
-- p_units: [{ "unit_name":"unidad", "factor_to_base":1, "is_base":true },
--           { "unit_name":"paquete", "factor_to_base":12, "is_base":false }]
-- No cambia el stock. El factor indica cuántas unidades base contiene una presentación.
create or replace function public.admin_configure_product_units(
  p_product_id uuid,
  p_base_unit text,
  p_units jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_count integer;
  v_base_count integer;
  v_item jsonb;
  v_name text;
  v_factor numeric(18,6);
  v_is_base boolean;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Solo el administrador puede configurar unidades de medida';
  end if;
  if nullif(btrim(p_base_unit), '') is null then
    raise exception 'Debes indicar la unidad base del producto';
  end if;
  if p_units is null or jsonb_typeof(p_units) <> 'array'
     or jsonb_array_length(p_units) = 0 then
    raise exception 'Debes registrar al menos una presentación';
  end if;

  select count(*) into v_count from jsonb_array_elements(p_units);
  select count(*) into v_base_count
  from jsonb_array_elements(p_units) x
  where coalesce((x->>'is_base')::boolean, false);

  if v_base_count <> 1 then
    raise exception 'Debe existir exactamente una presentación base';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(p_units) x
    where coalesce((x->>'is_base')::boolean, false)
      and lower(btrim(x->>'unit_name')) = lower(btrim(p_base_unit))
      and (x->>'factor_to_base')::numeric = 1
  ) then
    raise exception 'La presentación base debe coincidir con la unidad base y tener equivalencia 1';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_units) x
    where nullif(btrim(x->>'unit_name'), '') is null
       or coalesce((x->>'factor_to_base')::numeric, 0) <= 0
  ) then
    raise exception 'Cada presentación requiere nombre y equivalencia positiva';
  end if;

  if (select count(distinct lower(btrim(x->>'unit_name')))
      from jsonb_array_elements(p_units) x) <> v_count then
    raise exception 'No puede repetirse el nombre de una presentación';
  end if;

  perform 1 from public.products where id = p_product_id for update;
  if not found then raise exception 'Producto no encontrado'; end if;

  -- No se permite cambiar la unidad base una vez que existen movimientos
  -- o ventas con conversiones registradas; se requiere una migración explícita.
  if exists (
    select 1 from public.products p
    where p.id = p_product_id and p.unit_configured
      and lower(p.base_unit) <> lower(btrim(p_base_unit))
  ) and (
    exists (select 1 from public.inventory_movements m where m.product_id=p_product_id
            and m.quantity_change_base is not null)
    or exists (select 1 from public.sale_items si join public.sales s on s.id=si.sale_id
               where si.product_id=p_product_id and si.quantity_in_base is not null)
  ) then
    raise exception 'No se puede cambiar la unidad base después de movimientos convertidos';
  end if;

  delete from public.product_units where product_id = p_product_id;

  for v_item in select value from jsonb_array_elements(p_units) loop
    v_name := btrim(v_item->>'unit_name');
    v_factor := (v_item->>'factor_to_base')::numeric;
    v_is_base := coalesce((v_item->>'is_base')::boolean, false);
    insert into public.product_units(product_id, unit_name, factor_to_base, is_base)
    values(p_product_id, v_name, v_factor, v_is_base);
  end loop;

  update public.products
  set base_unit = btrim(p_base_unit), unit_configured = true
  where id = p_product_id;
end
$function$;

revoke all on function public.admin_configure_product_units(uuid,text,jsonb) from public, anon;
grant execute on function public.admin_configure_product_units(uuid,text,jsonb) to authenticated;

commit;

-- Verificación de solo lectura tras aplicar en PRUEBAS:
-- select column_name, data_type from information_schema.columns
-- where table_schema='public' and table_name in ('products','sale_items','inventory_movements')
--   and column_name in ('base_unit','unit_configured','unit_id','unit_name_snapshot',
--     'quantity_in_unit','quantity_in_base','conversion_factor_snapshot',
--     'quantity_change_base','stock_after_base');
-- select * from public.product_units order by product_id, is_base desc, unit_name;
-- IMPORTANTE: esta fase no modifica el valor de products.stock ni genera movimientos.
