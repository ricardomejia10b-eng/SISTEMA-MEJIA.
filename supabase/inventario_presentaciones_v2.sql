-- SISTEMA MEJÍA — movimientos de inventario con presentaciones
-- Aplicar únicamente en el proyecto Supabase de PRUEBAS y después de:
--   1) actualizacion_integral_v2.sql
--   2) unidades_medida_presentaciones_v1.sql
-- No modifica stock ni registros históricos al instalarse.
begin;

alter table public.inventory_movements
  add column if not exists unit_name text,
  add column if not exists quantity_in_unit numeric(18,6),
  add column if not exists quantity_change_base numeric(18,6),
  add column if not exists conversion_factor numeric(18,6),
  add column if not exists stock_after_base numeric(18,6);

-- La columna products.stock sigue siendo INTEGER en esta fase.
-- Por ello, solo se aceptan conversiones cuyo resultado en unidad base
-- sea un número entero exacto. No se redondea ni se pierde cantidad.

create or replace function public.log_product_stock_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user uuid := auth.uid();
  v_reason text := nullif(current_setting('app.inventory_reason', true), '');
  v_sale uuid;
  v_unit_name text := nullif(current_setting('app.inventory_unit_name', true), '');
  v_qty_unit numeric(18,6) := nullif(current_setting('app.inventory_quantity_in_unit', true), '')::numeric;
  v_factor numeric(18,6) := nullif(current_setting('app.inventory_conversion_factor', true), '')::numeric;
  v_type text := nullif(current_setting('app.inventory_movement_type', true), '');
begin
  if tg_op = 'INSERT' then
    insert into public.inventory_movements(
      product_id, product_name, movement_type, quantity_before,
      quantity_change, quantity_after, reason, performed_by,
      unit_name, quantity_in_unit, quantity_change_base,
      conversion_factor, stock_after_base
    ) values (
      new.id, new.name, 'stock_initial', 0, new.stock, new.stock,
      coalesce(v_reason, 'Stock registrado al crear producto'), v_user,
      v_unit_name, v_qty_unit, new.stock, v_factor, new.stock
    );
    return new;
  end if;

  if new.stock is distinct from old.stock then
    v_sale := nullif(current_setting('app.inventory_sale_id', true), '')::uuid;
    if v_sale is null then
      select s.id into v_sale
      from public.sales s
      join public.sale_items si on si.sale_id = s.id
      where s.created_by = auth.uid()
        and s.created_at = transaction_timestamp()
        and si.product_id = new.id
      order by s.created_at desc
      limit 1;
    end if;

    insert into public.inventory_movements(
      product_id, product_name, movement_type, quantity_before,
      quantity_change, quantity_after, reason, sale_id, performed_by,
      unit_name, quantity_in_unit, quantity_change_base,
      conversion_factor, stock_after_base
    ) values (
      new.id, new.name,
      case
        when v_type in ('stock_in','adjustment') then v_type
        when v_sale is not null then 'sale'
        when new.stock > old.stock then 'stock_in'
        else 'adjustment'
      end,
      old.stock, new.stock - old.stock, new.stock,
      coalesce(v_reason,
        case when v_sale is not null then 'Salida por venta'
             when new.stock > old.stock then 'Ingreso de stock'
             else 'Ajuste manual de stock' end),
      v_sale, v_user, v_unit_name, v_qty_unit,
      new.stock - old.stock, v_factor, new.stock
    );
  end if;
  return new;
end
$function$;

-- Ingreso (positivo) o ajuste (positivo/negativo) expresado en una
-- presentación activa del producto. El trigger existente registra auditoría.
create or replace function public.admin_record_inventory_movement(
  p_product_id uuid,
  p_unit_id uuid,
  p_quantity numeric,
  p_movement_type text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_product public.products%rowtype;
  v_unit public.product_units%rowtype;
  v_delta numeric(18,6);
  v_before integer;
  v_after integer;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Solo el administrador puede registrar movimientos de inventario';
  end if;
  if p_movement_type is null or p_movement_type not in ('stock_in','adjustment') then
    raise exception 'Tipo de movimiento inválido';
  end if;
  if p_quantity is null or p_quantity = 0 then
    raise exception 'La cantidad debe ser distinta de cero';
  end if;
  if p_movement_type = 'stock_in' and p_quantity < 0 then
    raise exception 'Un ingreso de stock debe tener cantidad positiva';
  end if;
  if nullif(btrim(p_reason), '') is null then
    raise exception 'Indica el motivo del movimiento';
  end if;

  select * into v_product
  from public.products
  where id = p_product_id
  for update;
  if not found then raise exception 'Producto no encontrado'; end if;
  if not coalesce(v_product.unit_configured, false) then
    raise exception 'Primero configura la unidad base y sus presentaciones';
  end if;

  select * into v_unit
  from public.product_units
  where id = p_unit_id
    and product_id = p_product_id
    and is_active = true
  for share;
  if not found then raise exception 'La presentación no está activa para este producto'; end if;

  v_delta := p_quantity * v_unit.factor_to_base;
  if v_delta <> trunc(v_delta) then
    raise exception 'La conversión produce una fracción de unidad base; ajusta la cantidad o la equivalencia';
  end if;
  if v_delta < -v_product.stock then
    raise exception 'El ajuste dejaría el inventario por debajo de cero';
  end if;

  v_before := v_product.stock;
  v_after := v_before + v_delta::integer;
  perform set_config('app.inventory_reason', btrim(p_reason), true);
  perform set_config('app.inventory_unit_name', v_unit.unit_name, true);
  perform set_config('app.inventory_quantity_in_unit', p_quantity::text, true);
  perform set_config('app.inventory_conversion_factor', v_unit.factor_to_base::text, true);
  perform set_config('app.inventory_movement_type', p_movement_type, true);

  update public.products set stock = v_after where id = p_product_id;

  return jsonb_build_object(
    'success', true,
    'product_id', p_product_id,
    'unit_name', v_unit.unit_name,
    'quantity_in_unit', p_quantity,
    'conversion_factor', v_unit.factor_to_base,
    'quantity_change_base', v_delta,
    'stock_before', v_before,
    'stock_after', v_after
  );
end
$function$;

revoke all on function public.admin_record_inventory_movement(uuid,uuid,numeric,text,text) from public, anon;
grant execute on function public.admin_record_inventory_movement(uuid,uuid,numeric,text,text) to authenticated;

commit;

-- Comprobación de solo lectura:
-- select column_name, data_type from information_schema.columns
-- where table_schema='public' and table_name='inventory_movements'
--   and column_name in ('unit_name','quantity_in_unit','quantity_change_base','conversion_factor','stock_after_base');
