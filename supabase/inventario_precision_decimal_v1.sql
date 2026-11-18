-- SISTEMA MEJÍA — precisión decimal para inventario, ventas y auditoría
-- Dependencias: actualizacion_integral_v2.sql, ventas_responsable_caja_v4.sql,
-- unidades_medida_presentaciones_v1.sql, inventario_presentaciones_v2.sql
-- y ventas_presentaciones_v5.sql.
-- SOLO proyecto Supabase de PRUEBAS. Convierte enteros existentes a numeric
-- sin alterar su valor; no calcula ni inventa equivalencias históricas.
begin;

alter table public.products
  alter column stock type numeric(18,6) using stock::numeric;

alter table public.sale_items
  alter column quantity type numeric(18,6) using quantity::numeric;

alter table public.inventory_movements
  alter column quantity_before type numeric(18,6) using quantity_before::numeric,
  alter column quantity_change type numeric(18,6) using quantity_change::numeric,
  alter column quantity_after type numeric(18,6) using quantity_after::numeric;

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
  v_before numeric(18,6);
  v_after numeric(18,6);
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

  if round(p_quantity * v_unit.factor_to_base,6) <> p_quantity * v_unit.factor_to_base then
    raise exception 'La conversión supera seis decimales de precisión en la unidad base';
  end if;
  v_delta := round(p_quantity * v_unit.factor_to_base,6);
  if v_delta < -v_product.stock then
    raise exception 'El ajuste dejaría el inventario por debajo de cero';
  end if;

  v_before := v_product.stock;
  v_after := v_before + v_delta;
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

create or replace function public.finalize_sale_v5(
  p_customer_id uuid,
  p_customer_name text,
  p_comments text,
  p_sale_type text,
  p_payment_type text,
  p_items jsonb,
  p_payments jsonb,
  p_cash_tendered numeric,
  p_cash_change numeric,
  p_due_date date,
  p_next_payment_date date,
  p_responsible_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_cash uuid;
  v_total numeric(12,2) := 0;
  v_paid numeric(12,2) := 0;
  v_sale uuid;
  v_sale_code text;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty numeric(18,6);
  v_base_raw numeric;
  v_qty_unit numeric(18,6);
  v_factor numeric(18,6);
  v_unit_row public.product_units%rowtype;
  v_unit_id uuid;
  v_unit_name text;
  v_unit numeric(12,2);
  v_line numeric(12,2);
  v_method text;
  v_amount numeric(12,2);
  v_payment uuid;
  v_customer_name text;
  v_cash_amount numeric(12,2) := 0;
  v_yape_amount numeric(12,2) := 0;
  v_cash_applied numeric(12,2) := 0;
  v_responsible_role text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if p_responsible_id is null then raise exception 'Selecciona al responsable de la venta'; end if;

  select role into v_responsible_role
  from public.profiles where id=p_responsible_id;
  if not found or v_responsible_role not in ('admin','vendedor') then
    raise exception 'El responsable seleccionado no es válido';
  end if;
  if not public.is_admin() and p_responsible_id<>auth.uid() then
    raise exception 'Solo el administrador puede asignar ventas a otro responsable';
  end if;

  if p_sale_type is null or p_sale_type not in ('mayorista','minorista') then
    raise exception 'Tipo de venta inválido';
  end if;
  if p_payment_type is null or p_payment_type not in ('contado','credito') then
    raise exception 'Tipo de pago inválido';
  end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'El carrito está vacío';
  end if;
  if p_payments is null or jsonb_typeof(p_payments)<>'array' then
    raise exception 'Detalle de pagos inválido';
  end if;
  if p_payment_type='credito' and p_due_date is not null
     and p_next_payment_date is not null and p_next_payment_date<p_due_date then
    raise exception 'La próxima fecha de pago no puede ser anterior al vencimiento';
  end if;
  if coalesce(p_cash_tendered,0)<0 or coalesce(p_cash_change,0)<0 then
    raise exception 'El efectivo entregado y el vuelto no pueden ser negativos';
  end if;

  select id into v_cash from public.cash_sessions
  where seller_id=p_responsible_id and status='open'
  order by opened_at desc limit 1 for update;
  if v_cash is null then
    raise exception 'El responsable seleccionado no tiene una caja abierta';
  end if;

  if p_customer_id is not null then
    select name into v_customer_name from public.customers where id=p_customer_id;
    if not found then raise exception 'El cliente seleccionado ya no existe'; end if;
  end if;
  v_customer_name=coalesce(nullif(trim(p_customer_name),''),v_customer_name);

  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_product from public.products
    where id=(v_item->>'product_id')::uuid for update;
    if not found then raise exception 'Uno de los productos ya no existe'; end if;
    v_qty_unit := coalesce((v_item->>'quantity_in_unit')::numeric, (v_item->>'quantity')::numeric);
    if v_qty_unit is null or v_qty_unit<=0 then raise exception 'Cantidad inválida'; end if;
    v_unit_id := nullif(v_item->>'unit_id','')::uuid;
    if coalesce(v_product.unit_configured,false) then
      if v_unit_id is null then raise exception 'Selecciona una presentación para %',v_product.name; end if;
      select * into v_unit_row from public.product_units
      where id=v_unit_id and product_id=v_product.id and is_active=true for share;
      if not found then raise exception 'La presentación seleccionada no está activa para %',v_product.name; end if;
      v_factor := v_unit_row.factor_to_base;
      v_unit_name := v_unit_row.unit_name;
    else
      if v_unit_id is not null then raise exception 'El producto % no tiene presentaciones configuradas',v_product.name; end if;
      v_factor := 1;
      v_unit_name := coalesce(v_product.base_unit,'unidad');
    end if;
    v_base_raw := v_qty_unit * v_factor;
    if round(v_base_raw,6) <> v_base_raw then
      raise exception 'La cantidad de % supera seis decimales de precisión en la unidad base',v_product.name;
    end if;
    v_qty := round(v_base_raw,6);
    if v_qty<=0 then raise exception 'La cantidad equivalente debe ser mayor que cero'; end if;
    if (select coalesce(sum(((coalesce(x->>'quantity_in_unit',x->>'quantity'))::numeric *
          (case when nullif(x->>'unit_id','') is null then 1 else
            (select pu.factor_to_base from public.product_units pu
             where pu.id=(x->>'unit_id')::uuid and pu.product_id=v_product.id and pu.is_active=true) end)),0)
        from jsonb_array_elements(p_items) as a(x)
        where x->>'product_id'=v_product.id::text)>v_product.stock then
      raise exception 'Stock insuficiente para %',v_product.name;
    end if;
    v_unit=case when p_sale_type='mayorista'
      then v_product.wholesale_price else v_product.retail_price end;
    if v_unit<=0 then
      raise exception 'El producto % no tiene precio configurado para este tipo de venta',v_product.name;
    end if;
    v_total=v_total+(v_unit*v_qty);
  end loop;

  for v_item in select value from jsonb_array_elements(p_payments) loop
    v_method=v_item->>'method';
    v_amount=(v_item->>'amount')::numeric;
    if v_method is null or v_method not in ('efectivo','qr','transferencia')
       or v_amount is null or v_amount<=0 then
      raise exception 'Detalle de pago inválido';
    end if;
    v_paid=v_paid+v_amount;
    if v_method='efectivo' then v_cash_amount=v_cash_amount+v_amount; end if;
    if v_method='qr' then v_yape_amount=v_yape_amount+v_amount; end if;
  end loop;

  if p_payment_type='contado' and abs(v_paid-v_total)>0.009 then
    raise exception 'Los pagos deben sumar exactamente el total';
  end if;
  if p_payment_type='credito' and v_paid>v_total then
    raise exception 'El adelanto no puede superar el total';
  end if;

  select coalesce(sum((x->>'amount')::numeric),0) into v_cash_applied
  from jsonb_array_elements(p_payments) x where x->>'method'='efectivo';
  if coalesce(p_cash_tendered,0)<v_cash_applied then
    raise exception 'El efectivo entregado no cubre el importe en efectivo';
  end if;
  if v_cash_applied=0 and
     (coalesce(p_cash_tendered,0)<>0 or coalesce(p_cash_change,0)<>0) then
    raise exception 'No corresponde registrar efectivo entregado ni vuelto sin un pago en efectivo';
  end if;
  if round((coalesce(p_cash_tendered,0)-v_cash_applied)::numeric,2)
     <>round(coalesce(p_cash_change,0)::numeric,2) then
    raise exception 'El vuelto no coincide con el efectivo entregado';
  end if;

  v_sale_code='VTA-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));

  insert into public.sales(
    customer_id,payment_type,total,paid_amount,created_by,created_at,
    sale_type,payment_method,cash_session_id,seller_id,
    sale_code,comments,customer_name,cash_amount,yape_amount,
    cash_tendered,cash_change,due_date,next_payment_date,credit_status
  )
  values(
    p_customer_id,p_payment_type,v_total,v_paid,auth.uid(),now(),
    p_sale_type,
    case when (select count(distinct x->>'method')
               from jsonb_array_elements(p_payments) as t(x))>1
         then 'mixto' else p_payments->0->>'method' end,
    v_cash,p_responsible_id,v_sale_code,nullif(trim(p_comments),''),
    v_customer_name,v_cash_amount,v_yape_amount,
    coalesce(p_cash_tendered,0),coalesce(p_cash_change,0),
    case when p_payment_type='credito' then p_due_date else null end,
    case when p_payment_type='credito' then p_next_payment_date else null end,
    case when p_payment_type='credito' then
      case when v_paid>=v_total then 'pagado'
           when v_paid>0 then 'parcial' else 'pendiente' end
      else null end
  ) returning id into v_sale;

  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_product from public.products
    where id=(v_item->>'product_id')::uuid for update;
    v_qty_unit := coalesce((v_item->>'quantity_in_unit')::numeric, (v_item->>'quantity')::numeric);
    v_unit_id := nullif(v_item->>'unit_id','')::uuid;
    if coalesce(v_product.unit_configured,false) then
      select * into v_unit_row from public.product_units
      where id=v_unit_id and product_id=v_product.id and is_active=true for share;
      if not found then raise exception 'La presentación seleccionada ya no está activa para %',v_product.name; end if;
      v_factor := v_unit_row.factor_to_base;
      v_unit_name := v_unit_row.unit_name;
    else
      v_factor := 1;
      v_unit_name := coalesce(v_product.base_unit,'unidad');
    end if;
    v_base_raw := v_qty_unit * v_factor;
    if round(v_base_raw,6) <> v_base_raw then
      raise exception 'La cantidad de % supera seis decimales de precisión en la unidad base',v_product.name;
    end if;
    v_qty := round(v_base_raw,6);
    v_unit=case when p_sale_type='mayorista'
      then v_product.wholesale_price else v_product.retail_price end;
    v_line=v_unit*v_qty;
    insert into public.sale_items(
      sale_id,product_id,product_name,quantity,unit_price,line_total,
      unit_id,unit_name_snapshot,base_unit_snapshot,quantity_in_unit,quantity_in_base,conversion_factor_snapshot
    ) values(
      v_sale,v_product.id,v_product.name,v_qty,v_unit*v_factor,v_line,
      v_unit_id,v_unit_name,coalesce(v_product.base_unit,'unidad'),v_qty_unit,v_qty,v_factor
    );
    perform set_config('app.inventory_sale_id',v_sale::text,true);
    perform set_config('app.inventory_reason','Salida por venta',true);
    perform set_config('app.inventory_unit_name',v_unit_name,true);
    perform set_config('app.inventory_quantity_in_unit',v_qty_unit::text,true);
    perform set_config('app.inventory_conversion_factor',v_factor::text,true);
    perform set_config('app.inventory_movement_type','sale',true);
    update public.products set stock=stock-v_qty where id=v_product.id;
  end loop;

  for v_item in select value from jsonb_array_elements(p_payments) loop
    v_method=v_item->>'method';
    v_amount=(v_item->>'amount')::numeric;
    insert into public.payments(
      sale_id,amount,note,received_by,payment_method,cash_session_id
    )
    values(
      v_sale,v_amount,
      case when p_payment_type='credito' then 'Adelanto inicial' else 'Pago de venta al contado' end,
      auth.uid(),v_method,v_cash
    ) returning id into v_payment;
    insert into public.cash_movements(
      cash_session_id,seller_id,movement_type,payment_method,amount,sale_id,payment_id,description
    )
    values(
      v_cash,p_responsible_id,
      case when p_payment_type='credito' then 'credit_advance' else 'sale' end,
      v_method,v_amount,v_sale,v_payment,
      case when p_payment_type='credito' then 'Adelanto de crédito' else 'Venta al contado' end
    );
  end loop;
  return v_sale;
end
$function$;

revoke all on function public.finalize_sale_v5(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid) from public, anon;
grant execute on function public.finalize_sale_v5(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid) to authenticated;

-- Deshabilitar la RPC anterior que solo descuenta cantidades enteras y no
-- guarda la presentación. La aplicación usa finalize_sale_v5 desde esta fase.
revoke all on function public.finalize_sale_v4(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)
  from public, anon, authenticated;

commit;

-- Verificación de solo lectura:
-- select table_name,column_name,data_type,numeric_precision,numeric_scale
-- from information_schema.columns
-- where table_schema='public'
-- and ((table_name='products' and column_name='stock')
--   or (table_name='sale_items' and column_name='quantity')
--   or (table_name='inventory_movements' and column_name in ('quantity_before','quantity_change','quantity_after')))
-- order by table_name,column_name;
