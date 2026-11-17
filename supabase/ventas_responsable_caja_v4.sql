-- SISTEMA MEJÍA · Asignación de ventas y abonos a responsable
-- Ejecutar únicamente en el proyecto Supabase de PRUEBAS.
-- No modifica ventas históricas ni cierra/actualiza sesiones de caja existentes.

begin;

create or replace function public.finalize_sale_v4(
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
  v_qty integer;
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
    v_qty=(v_item->>'quantity')::integer;
    if v_qty is null or v_qty<1 then raise exception 'Cantidad inválida'; end if;
    if (select coalesce(sum((x->>'quantity')::integer),0)
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
    v_qty=(v_item->>'quantity')::integer;
    v_unit=case when p_sale_type='mayorista'
      then v_product.wholesale_price else v_product.retail_price end;
    v_line=v_unit*v_qty;
    insert into public.sale_items(sale_id,product_id,product_name,quantity,unit_price,line_total)
    values(v_sale,v_product.id,v_product.name,v_qty,v_unit,v_line);
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

create or replace function public.register_payment(
  p_sale_id uuid,
  p_amount numeric,
  p_note text default null,
  p_payment_method text default 'efectivo'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  s public.sales%rowtype;
  payment_id uuid;
  v_cash uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if p_amount is null or p_amount<=0 then raise exception 'El monto debe ser mayor que cero'; end if;
  if p_payment_method not in ('efectivo','qr') then
    raise exception 'Para registrar el abono selecciona efectivo o QR';
  end if;

  select * into s from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Venta no encontrada'; end if;
  if not public.is_admin() and s.seller_id<>auth.uid() then
    raise exception 'No tienes permiso para registrar este abono';
  end if;
  if s.payment_type<>'credito' then raise exception 'La venta no es al crédito'; end if;
  if p_amount>s.total-s.paid_amount then raise exception 'El abono supera el saldo pendiente'; end if;

  select id into v_cash from public.cash_sessions
  where seller_id=s.seller_id and status='open'
  order by opened_at desc limit 1 for update;
  if v_cash is null then
    raise exception 'El responsable de la venta no tiene una caja abierta para recibir el abono';
  end if;

  insert into public.payments(
    sale_id,amount,note,received_by,payment_method,cash_session_id
  )
  values(p_sale_id,p_amount,p_note,auth.uid(),p_payment_method,v_cash)
  returning id into payment_id;

  update public.sales
  set paid_amount=paid_amount+p_amount
  where id=p_sale_id;

  insert into public.cash_movements(
    cash_session_id,seller_id,movement_type,payment_method,amount,sale_id,payment_id,description
  )
  values(
    v_cash,s.seller_id,'credit_payment',p_payment_method,p_amount,p_sale_id,payment_id,
    coalesce(nullif(trim(p_note),''),'Abono de crédito')
  );

  return jsonb_build_object(
    'success',true,'payment_id',payment_id,
    'new_balance',s.total-s.paid_amount-p_amount
  );
end
$function$;

-- Las ventas son visibles para su responsable y para administración.
drop policy if exists "sales read own or admin" on public.sales;
create policy "sales read responsible or admin"
on public.sales for select to authenticated
using (seller_id=auth.uid() or public.is_admin());

-- Los detalles y abonos siguen la visibilidad de la venta responsable.
drop policy if exists "items read sale access" on public.sale_items;
create policy "items read responsible sale or admin"
on public.sale_items for select to authenticated
using (
  exists(select 1 from public.sales s
         where s.id=sale_items.sale_id
           and (s.seller_id=auth.uid() or public.is_admin()))
);

drop policy if exists "payments read sale access" on public.payments;
create policy "payments read responsible sale or admin"
on public.payments for select to authenticated
using (
  exists(select 1 from public.sales s
         where s.id=payments.sale_id
           and (s.seller_id=auth.uid() or public.is_admin()))
);

-- La consulta de movimientos sigue el seller_id asignado a la caja.
drop policy if exists "cash movements read own admin" on public.cash_movements;
create policy "cash movements read responsible or admin"
on public.cash_movements for select to authenticated
using (seller_id=auth.uid() or public.is_admin());

revoke all on function public.finalize_sale_v4(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)
  from public, anon;
grant execute on function public.finalize_sale_v4(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)
  to authenticated;

revoke all on function public.register_payment(uuid,numeric,text,text) from public, anon;
grant execute on function public.register_payment(uuid,numeric,text,text) to authenticated;

commit;

-- Verificación de políticas y permisos:
-- select tablename,policyname,cmd,qual,with_check
-- from pg_policies where schemaname='public'
-- and tablename in ('sales','sale_items','payments','cash_movements')
-- order by tablename,policyname;
-- select has_function_privilege('anon',
--   'public.finalize_sale_v4(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)','EXECUTE') as anon_exec,
--   has_function_privilege('authenticated',
--   'public.finalize_sale_v4(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)','EXECUTE') as auth_exec;
-- select id,seller_id,status,opened_at from public.cash_sessions
-- where status='open' order by opened_at;
