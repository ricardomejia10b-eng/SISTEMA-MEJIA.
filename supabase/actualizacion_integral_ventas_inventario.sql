-- SISTEMA MEJIA: actualizacion integral aditiva.
-- Ejecutar solo despues de revisar el respaldo. No elimina ventas, productos ni clientes.
begin;

alter table public.products
  add column if not exists price_wholesale numeric(12,2),
  add column if not exists price_retail numeric(12,2),
  add column if not exists barcode text;

update public.products
set price_retail = coalesce(price_retail, price),
    price_wholesale = coalesce(price_wholesale, price),
    barcode = coalesce(barcode, code)
where price_retail is null or price_wholesale is null or barcode is null;

alter table public.products
  alter column price_retail set default 0,
  alter column price_wholesale set default 0;

alter table public.sales
  add column if not exists payment_cash numeric(12,2) not null default 0,
  add column if not exists payment_qr numeric(12,2) not null default 0;

alter table public.payments
  add column if not exists payment_method text;

-- Quita únicamente restricciones CHECK antiguas que limitaban payment_method
-- a efectivo/KR; no toca otras restricciones ni los registros existentes.
do $$
declare c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.sales'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%payment_method%'
  loop
    execute format('alter table public.sales drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.sales
  add constraint sales_payment_method_allowed
  check (payment_method is null or payment_method in ('efectivo','qr','mixto','transferencia'));

alter table public.payments
  drop constraint if exists payments_payment_method_allowed;
alter table public.payments
  add constraint payments_payment_method_allowed
  check (payment_method is null or payment_method in ('efectivo','qr','transferencia','mixto'));

create index if not exists products_barcode_idx on public.products(barcode);
create index if not exists sales_customer_credit_idx on public.sales(customer_id, created_at)
  where payment_type = 'credito';

-- Venta completa en una sola transacción: valida caja, cliente, precios y stock;
-- registra cabecera, detalle, pago inicial y descuenta inventario sin dobles descuentos.
create or replace function public.finalize_sale(
  p_items jsonb,
  p_customer_id uuid,
  p_sale_kind text,
  p_payment_type text,
  p_payment_method text,
  p_cash_amount numeric default 0,
  p_qr_amount numeric default 0,
  p_advance_amount numeric default 0,
  p_advance_method text default null,
  p_cash_register_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale_id uuid;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_unit numeric(12,2);
  v_line numeric(12,2);
  v_total numeric(12,2) := 0;
  v_paid numeric(12,2) := 0;
  v_method text;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Agrega al menos un producto al carrito';
  end if;
  if p_sale_kind is null or p_sale_kind not in ('mayor','menor') then raise exception 'Tipo de venta inválido'; end if;
  if p_payment_type is null or p_payment_type not in ('contado','credito') then raise exception 'Tipo de pago inválido'; end if;
  if p_cash_register_id is null or not exists (
    select 1 from public.cash_registers
    where id = p_cash_register_id and seller_id = auth.uid() and closed_at is null
  ) then raise exception 'Debes tener una caja abierta para registrar ventas'; end if;
  if p_payment_type = 'credito' and p_customer_id is null then
    raise exception 'Selecciona un cliente registrado para vender al crédito';
  end if;
  if p_customer_id is not null and not exists(select 1 from public.customers where id=p_customer_id) then
    raise exception 'El cliente seleccionado no existe';
  end if;

  -- Valida stock y calcula el total con precio vigente según mayor/menor.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;
    if v_qty is null or v_qty < 1 then raise exception 'Cantidad inválida'; end if;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid for update;
    if not found then raise exception 'Uno de los productos ya no existe'; end if;
    if v_product.stock < v_qty then
      raise exception 'Stock insuficiente para % (disponible: %)', v_product.name, v_product.stock;
    end if;
    v_unit := case when p_sale_kind='mayor'
      then coalesce(v_product.price_wholesale, v_product.price)
      else coalesce(v_product.price_retail, v_product.price)
    end;
    if v_unit < 0 then raise exception 'Precio inválido para %', v_product.name; end if;
    v_total := v_total + (v_unit * v_qty);
  end loop;

  if p_payment_type = 'contado' then
    if p_payment_method is null or p_payment_method not in ('efectivo','qr','mixto') then
      raise exception 'Selecciona efectivo, QR o mixto';
    end if;
    if coalesce(p_cash_amount,0) < 0 or coalesce(p_qr_amount,0) < 0
      or round(coalesce(p_cash_amount,0)+coalesce(p_qr_amount,0),2) <> round(v_total,2) then
      raise exception 'El efectivo más QR debe ser igual al total de la compra';
    end if;
    if p_payment_method='efectivo' and (coalesce(p_cash_amount,0)<>v_total or coalesce(p_qr_amount,0)<>0) then
      raise exception 'El importe debe registrarse íntegramente en efectivo';
    elsif p_payment_method='qr' and (coalesce(p_qr_amount,0)<>v_total or coalesce(p_cash_amount,0)<>0) then
      raise exception 'El importe debe registrarse íntegramente por QR';
    elsif p_payment_method='mixto' and (coalesce(p_cash_amount,0)<=0 or coalesce(p_qr_amount,0)<=0) then
      raise exception 'Para pago mixto ingresa un importe en efectivo y otro por QR';
    end if;
    v_paid := v_total;
  else
    if coalesce(p_advance_amount,0) < 0 or coalesce(p_advance_amount,0) > v_total then
      raise exception 'El adelanto no puede superar el total de la compra';
    end if;
    if p_advance_amount > 0 and (p_advance_method is null or p_advance_method not in ('efectivo','transferencia','qr')) then
      raise exception 'Selecciona cómo se recibió el adelanto';
    end if;
    v_paid := coalesce(p_advance_amount,0);
    v_method := null;
  end if;

  insert into public.sales(
    customer_id, customer_name, sale_kind, payment_type, payment_method,
    payment_cash, payment_qr, cash_register_id, total, paid_amount, created_by
  ) values (
    p_customer_id, null, p_sale_kind, p_payment_type,
    case when p_payment_type='contado' then p_payment_method else null end,
    case when p_payment_type='contado' then coalesce(p_cash_amount,0) else 0 end,
    case when p_payment_type='contado' then coalesce(p_qr_amount,0) else 0 end,
    p_cash_register_id, v_total, v_paid, auth.uid()
  ) returning id into v_sale_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products
      where id = (v_item->>'product_id')::uuid for update;
    v_unit := case when p_sale_kind='mayor'
      then coalesce(v_product.price_wholesale, v_product.price)
      else coalesce(v_product.price_retail, v_product.price)
    end;
    v_line := v_unit * v_qty;
    insert into public.sale_items(sale_id, product_id, product_name, quantity, unit_price, line_total)
    values(v_sale_id, v_product.id, v_product.name, v_qty, v_unit, v_line);
    update public.products set stock = stock - v_qty where id = v_product.id;
  end loop;

  if p_payment_type='contado' then
    insert into public.payments(sale_id, amount, note, received_by, payment_method)
    values(v_sale_id, v_total, 'Pago al contado', auth.uid(), p_payment_method);
  elsif v_paid > 0 then
    insert into public.payments(sale_id, amount, note, received_by, payment_method)
    values(v_sale_id, v_paid, 'Adelanto de venta al crédito', auth.uid(), p_advance_method);
  end if;

  return jsonb_build_object('success',true,'sale_id',v_sale_id,'total',v_total,
    'paid_amount',v_paid,'balance',v_total-v_paid);
end;
$$;

grant execute on function public.finalize_sale(jsonb,uuid,text,text,text,numeric,numeric,numeric,text,uuid)
to authenticated;

-- Abonos posteriores con método y control de saldo bajo bloqueo de la venta.
create or replace function public.register_credit_payment(
  p_sale_id uuid,
  p_amount numeric,
  p_method text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s public.sales%rowtype; v_payment_id uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'El abono debe ser mayor que cero'; end if;
  if p_method is null or p_method not in ('efectivo','transferencia','qr') then raise exception 'Forma de pago inválida'; end if;
  select * into s from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Venta no encontrada'; end if;
  if s.created_by<>auth.uid() and not public.is_admin() then
    raise exception 'No tienes permiso para registrar este abono';
  end if;
  if s.payment_type<>'credito' then raise exception 'La venta no es al crédito'; end if;
  if p_amount > s.total-s.paid_amount then raise exception 'El abono supera el saldo pendiente'; end if;
  insert into public.payments(sale_id,amount,note,received_by,payment_method)
  values(p_sale_id,p_amount,'Abono de crédito',auth.uid(),p_method)
  returning id into v_payment_id;
  update public.sales set paid_amount=paid_amount+p_amount where id=p_sale_id;
  return jsonb_build_object('success',true,'payment_id',v_payment_id,
    'new_balance',s.total-s.paid_amount-p_amount);
end;
$$;
grant execute on function public.register_credit_payment(uuid,numeric,text) to authenticated;

commit;
