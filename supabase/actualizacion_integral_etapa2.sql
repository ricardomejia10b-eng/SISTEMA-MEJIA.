-- SISTEMA MEJIA — etapa 2: datos de venta y resumen de caja
-- PREPARADO PARA REVISION. No ejecutar hasta revisar la etapa 1 y aprobar.
-- Conserva intactas finalize_sale, register_payment y close_cash_session.
-- La interfaz nueva deberá llamar finalize_sale_v2 en vez de finalize_sale.

begin;

create or replace function public.finalize_sale_v2(
  p_customer_id uuid,
  p_customer_name text,
  p_comments text,
  p_sale_type text,
  p_payment_type text,
  p_items jsonb,
  p_payments jsonb
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
  v_qty integer;
  v_unit numeric(12,2);
  v_line numeric(12,2);
  v_method text;
  v_amount numeric(12,2);
  v_payment uuid;
  v_customer_name text;
  v_cash_amount numeric(12,2) := 0;
  v_yape_amount numeric(12,2) := 0;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if p_sale_type not in ('mayorista','minorista') then raise exception 'Tipo de venta inválido'; end if;
  if p_payment_type not in ('contado','credito') then raise exception 'Tipo de pago inválido'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then
    raise exception 'El carrito está vacío';
  end if;
  if p_payments is null or jsonb_typeof(p_payments) <> 'array' then
    raise exception 'Detalle de pagos inválido';
  end if;

  select id into v_cash
  from public.cash_sessions
  where seller_id=auth.uid() and status='open'
  limit 1;
  if v_cash is null then raise exception 'Primero debes abrir tu caja'; end if;

  if p_customer_id is not null then
    select name into v_customer_name from public.customers where id=p_customer_id;
    if not found then raise exception 'El cliente seleccionado ya no existe'; end if;
  end if;
  v_customer_name := coalesce(nullif(trim(p_customer_name),''), v_customer_name);

  -- Validar stock y calcular total usando siempre los precios vigentes del catálogo.
  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_product
    from public.products
    where id=(v_item->>'product_id')::uuid
    for update;
    if not found then raise exception 'Uno de los productos ya no existe'; end if;

    v_qty := (v_item->>'quantity')::integer;
    if v_qty is null or v_qty<1 then raise exception 'Cantidad inválida'; end if;

    -- También controla cantidades repetidas del mismo producto dentro del JSON.
    if (select coalesce(sum((x->>'quantity')::integer),0)
        from jsonb_array_elements(p_items) as a(x)
        where x->>'product_id'=v_product.id::text) > v_product.stock then
      raise exception 'Stock insuficiente para %', v_product.name;
    end if;

    v_unit := case when p_sale_type='mayorista'
      then v_product.wholesale_price else v_product.retail_price end;
    if v_unit<=0 then
      raise exception 'El producto % no tiene precio configurado para este tipo de venta',v_product.name;
    end if;
    v_total := v_total + (v_unit*v_qty);
  end loop;

  for v_item in select value from jsonb_array_elements(p_payments) loop
    v_method := v_item->>'method';
    v_amount := (v_item->>'amount')::numeric;
    if v_method not in ('efectivo','qr','transferencia') or v_amount is null or v_amount<=0 then
      raise exception 'Detalle de pago inválido';
    end if;
    v_paid := v_paid + v_amount;
    if v_method='efectivo' then v_cash_amount := v_cash_amount+v_amount; end if;
    if v_method='qr' then v_yape_amount := v_yape_amount+v_amount; end if;
  end loop;

  if p_payment_type='contado' and abs(v_paid-v_total)>0.009 then
    raise exception 'Los pagos deben sumar exactamente el total';
  end if;
  if p_payment_type='credito' and v_paid>v_total then
    raise exception 'El adelanto no puede superar el total';
  end if;

  v_sale_code := 'VTA-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));

  insert into public.sales(
    customer_id,payment_type,total,paid_amount,created_by,created_at,
    sale_type,payment_method,cash_session_id,seller_id,
    sale_code,comments,customer_name,cash_amount,yape_amount
  )
  values(
    p_customer_id,p_payment_type,v_total,v_paid,auth.uid(),now(),
    p_sale_type,
    case
      when (select count(distinct x->>'method') from jsonb_array_elements(p_payments) as t(x))>1 then 'mixto'
      else p_payments->0->>'method'
    end,
    v_cash,auth.uid(),v_sale_code,nullif(trim(p_comments),''),v_customer_name,
    v_cash_amount,v_yape_amount
  ) returning id into v_sale;

  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_product
    from public.products
    where id=(v_item->>'product_id')::uuid
    for update;
    v_qty := (v_item->>'quantity')::integer;
    v_unit := case when p_sale_type='mayorista'
      then v_product.wholesale_price else v_product.retail_price end;
    v_line := v_unit*v_qty;

    insert into public.sale_items(sale_id,product_id,product_name,quantity,unit_price,line_total)
    values(v_sale,v_product.id,v_product.name,v_qty,v_unit,v_line);

    update public.products set stock=stock-v_qty where id=v_product.id;
  end loop;

  for v_item in select value from jsonb_array_elements(p_payments) loop
    v_method := v_item->>'method';
    v_amount := (v_item->>'amount')::numeric;

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
      v_cash,auth.uid(),
      case when p_payment_type='credito' then 'credit_advance' else 'sale' end,
      v_method,v_amount,v_sale,v_payment,
      case when p_payment_type='credito' then 'Adelanto de crédito' else 'Venta al contado' end
    );
  end loop;

  return v_sale;
end
$function$;

-- Resumen de sesión: lo cobrado realmente va a efectivo/QR;
-- el total a crédito y el saldo pendiente se muestran aparte.
create or replace function public.get_cash_session_summary(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_session public.cash_sessions%rowtype;
  v_cash numeric(12,2);
  v_qr numeric(12,2);
  v_credit_total numeric(12,2);
  v_credit_paid numeric(12,2);
  v_credit_balance numeric(12,2);
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;

  select * into v_session
  from public.cash_sessions
  where id=p_session_id
  for share;
  if not found then raise exception 'Caja no encontrada'; end if;
  if v_session.seller_id<>auth.uid() and not public.is_admin() then
    raise exception 'No tienes permiso para consultar esta caja';
  end if;

  select coalesce(sum(amount),0) into v_cash
  from public.cash_movements
  where cash_session_id=p_session_id
    and payment_method='efectivo'
    and movement_type<>'opening';

  select coalesce(sum(amount),0) into v_qr
  from public.cash_movements
  where cash_session_id=p_session_id
    and payment_method='qr';

  select
    coalesce(sum(total),0),
    coalesce(sum(paid_amount),0),
    coalesce(sum(total-paid_amount),0)
  into v_credit_total,v_credit_paid,v_credit_balance
  from public.sales
  where cash_session_id=p_session_id and payment_type='credito';

  return jsonb_build_object(
    'session_id',p_session_id,
    'status',v_session.status,
    'opening_cash',v_session.opening_amount,
    'cash_received',v_cash,
    'qr_received',v_qr,
    'expected_cash',v_session.opening_amount+v_cash,
    'expected_qr',v_qr,
    'credit_sales_total',v_credit_total,
    'credit_paid_total',v_credit_paid,
    'credit_balance_total',v_credit_balance,
    'sales_grand_total',(
      select coalesce(sum(total),0) from public.sales where cash_session_id=p_session_id
    )
  );
end
$function$;

commit;

-- No se reemplaza ninguna función anterior.
-- Para habilitar el flujo nuevo, primero revisar y ejecutar esta migración
-- después de la etapa 1; luego actualizar la interfaz para llamar:
-- finalize_sale_v2(p_customer_id,p_customer_name,p_comments,p_sale_type,
--                 p_payment_type,p_items,p_payments)
-- y get_cash_session_summary(p_session_id).
