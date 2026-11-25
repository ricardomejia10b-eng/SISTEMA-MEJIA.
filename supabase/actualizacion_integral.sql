-- SISTEMA MEJIA: actualizacion integral aditiva
-- No elimina tablas, columnas ni registros existentes.
begin;

alter table public.products
  add column if not exists wholesale_price numeric(12,2) not null default 0,
  add column if not exists retail_price numeric(12,2);

update public.products
set retail_price = price
where retail_price is null or retail_price = 0;

alter table public.products
  alter column retail_price set default 0;

alter table public.sales
  add column if not exists sale_code text,
  add column if not exists comments text,
  add column if not exists cash_amount numeric(12,2) not null default 0,
  add column if not exists yape_amount numeric(12,2) not null default 0;

update public.sales
set sale_code = 'LEG-' || upper(substr(replace(id::text,'-',''),1,12))
where sale_code is null;

alter table public.sales alter column sale_code set not null;
create unique index if not exists sales_sale_code_uidx on public.sales(sale_code);

alter table public.sales drop constraint if exists sales_payment_method_check;
alter table public.sales drop constraint if exists sales_payment_method_check1;
alter table public.sales add constraint sales_payment_method_check
  check (payment_method is null or payment_method in ('efectivo','yape','mixto','credito','kr'));

alter table public.payments
  add column if not exists payment_method text;
alter table public.payments drop constraint if exists payments_payment_method_check;
alter table public.payments add constraint payments_payment_method_check
  check (payment_method is null or payment_method in ('efectivo','yape','mixto','credito','kr'));

create index if not exists sales_created_at_idx on public.sales(created_at);
create index if not exists sale_items_sale_id_idx on public.sale_items(sale_id);
create index if not exists payments_sale_id_idx on public.payments(sale_id);

-- Finaliza una compra completa en una sola transaccion: valida caja/stock,
-- crea venta y detalle, y descuenta el inventario una sola vez.
create or replace function public.finalize_sale(
  p_items jsonb,
  p_customer_id uuid default null,
  p_sale_kind text default 'menor',
  p_payment_type text default 'contado',
  p_payment_method text default 'efectivo',
  p_cash_amount numeric default 0,
  p_yape_amount numeric default 0,
  p_comments text default null,
  p_cash_register_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale_id uuid;
  v_code text;
  v_total numeric(12,2) := 0;
  v_paid numeric(12,2) := 0;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_price numeric(12,2);
  v_name text;
  v_line numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesion'; end if;
  if p_sale_kind not in ('mayor','menor') then raise exception 'Tipo de venta invalido'; end if;
  if p_payment_type not in ('contado','credito') then raise exception 'Tipo de pago invalido'; end if;
  if p_payment_method not in ('efectivo','yape','mixto','credito','kr') then raise exception 'Metodo de pago invalido'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Agrega al menos un producto al carrito';
  end if;
  if coalesce(p_cash_amount,0)<0 or coalesce(p_yape_amount,0)<0 then
    raise exception 'Los importes de pago no pueden ser negativos';
  end if;
  v_paid := coalesce(p_cash_amount,0)+coalesce(p_yape_amount,0);
  if p_payment_type='contado' and abs(v_paid) < 0 then raise exception 'Pago invalido'; end if;
  if p_payment_type='contado' and p_payment_method='credito' then raise exception 'Selecciona un metodo de pago al contado'; end if;
  if p_payment_type='credito' and p_payment_method<>'credito' and p_payment_method not in ('efectivo','yape','mixto') then
    raise exception 'Metodo de abono inicial invalido';
  end if;
  if p_payment_method='efectivo' and coalesce(p_yape_amount,0)<>0 then raise exception 'El pago en efectivo no puede incluir Yape'; end if;
  if p_payment_method='yape' and coalesce(p_cash_amount,0)<>0 then raise exception 'El pago por Yape no puede incluir efectivo'; end if;

  -- La caja abierta es obligatoria para toda venta.
  if p_cash_register_id is null or not exists (
    select 1 from public.cash_registers cr
    where cr.id=p_cash_register_id and cr.seller_id=auth.uid() and cr.closed_at is null
  ) then raise exception 'Debes tener una caja abierta para vender'; end if;

  -- Validar todos los articulos y bloquear filas de inventario.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(v_item->>'product_id','')='' then raise exception 'Producto invalido'; end if;
    v_qty := (v_item->>'quantity')::integer;
    if v_qty is null or v_qty<=0 then raise exception 'Cantidad invalida'; end if;
    select * into v_product from public.products
      where id=(v_item->>'product_id')::uuid for update;
    if not found then raise exception 'Producto no encontrado'; end if;
    if v_product.stock < v_qty then
      raise exception 'Stock insuficiente para % (disponible: %, solicitado: %)',v_product.name,v_product.stock,v_qty;
    end if;
    if p_sale_kind='mayor' then v_price:=v_product.wholesale_price;
    else v_price:=coalesce(v_product.retail_price,v_product.price); end if;
    if v_price<0 then raise exception 'Precio invalido'; end if;
    v_total := v_total + v_price*v_qty;
  end loop;

  if p_payment_type='contado' and abs(v_paid-v_total)>0.009 then
    raise exception 'El pago debe coincidir con el total de la compra';
  end if;
  if p_payment_type='credito' and v_paid>v_total then
    raise exception 'El adelanto no puede superar el total';
  end if;
  if p_payment_type='credito' and p_payment_method='credito' and v_paid<>0 then
    raise exception 'Para registrar un adelanto selecciona efectivo, Yape o mixto';
  end if;
  if p_payment_type='credito' and v_paid=0 then p_payment_method:='credito'; end if;
  if p_payment_type='credito' and v_paid>0 and p_payment_method='credito' then
    raise exception 'Selecciona el metodo del adelanto';
  end if;

  v_sale_id := gen_random_uuid();
  v_code := 'V-' || to_char(now() at time zone 'America/Lima','YYYYMMDD') || '-' || upper(substr(replace(v_sale_id::text,'-',''),1,8));

  insert into public.sales(
    id,sale_code,customer_id,sale_kind,payment_type,payment_method,
    total,paid_amount,cash_amount,yape_amount,comments,cash_register_id,
    created_by,created_at
  ) values (
    v_sale_id,v_code,p_customer_id,p_sale_kind,p_payment_type,p_payment_method,
    v_total,v_paid,coalesce(p_cash_amount,0),coalesce(p_yape_amount,0),
    p_comments,p_cash_register_id,auth.uid(),now()
  );

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::integer;
    select * into v_product from public.products
      where id=(v_item->>'product_id')::uuid for update;
    if p_sale_kind='mayor' then v_price:=v_product.wholesale_price;
    else v_price:=coalesce(v_product.retail_price,v_product.price); end if;
    v_line:=v_price*v_qty;
    insert into public.sale_items(sale_id,product_id,product_name,quantity,unit_price,line_total)
    values(v_sale_id,v_product.id,v_product.name,v_qty,v_price,v_line);
    update public.products set stock=stock-v_qty where id=v_product.id;
  end loop;

  if coalesce(p_cash_amount,0)>0 then
    insert into public.payments(sale_id,amount,note,received_by,payment_method)
    values(v_sale_id,p_cash_amount,'Pago inicial en efectivo',auth.uid(),'efectivo');
  end if;
  if coalesce(p_yape_amount,0)>0 then
    insert into public.payments(sale_id,amount,note,received_by,payment_method)
    values(v_sale_id,p_yape_amount,'Pago inicial por Yape',auth.uid(),'yape');
  end if;

  return jsonb_build_object('success',true,'sale_id',v_sale_id,'sale_code',v_code,'total',v_total,'paid',v_paid,'balance',v_total-v_paid);
end;
$$;

revoke all on function public.finalize_sale(jsonb,uuid,text,text,text,numeric,numeric,text,uuid) from public;
grant execute on function public.finalize_sale(jsonb,uuid,text,text,text,numeric,numeric,text,uuid) to authenticated;

commit;
