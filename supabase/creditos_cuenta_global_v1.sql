-- Cuenta global de créditos por cliente.
-- Aditiva: conserva ventas, pagos y movimientos históricos.
-- Ejecutar únicamente en el proyecto Supabase de PRUEBAS.

alter table public.customers
  add column if not exists credit_due_date date;

create table if not exists public.customer_account_payments (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete restrict,
  amount numeric(12,2) not null check (amount > 0),
  payment_method text not null check (payment_method in ('efectivo','qr','transferencia')),
  note text,
  received_by uuid not null references auth.users(id),
  cash_session_id uuid not null references public.cash_sessions(id),
  created_at timestamptz not null default now()
);

alter table public.customer_account_payments enable row level security;
revoke all on table public.customer_account_payments from anon, authenticated;
grant all on table public.customer_account_payments to service_role;

alter table public.payments
  add column if not exists account_payment_id uuid
    references public.customer_account_payments(id) on delete restrict;

create index if not exists customer_account_payments_customer_created_idx
  on public.customer_account_payments(customer_id, created_at desc);
create index if not exists payments_account_payment_id_idx
  on public.payments(account_payment_id);

-- La fecha de la ficha se copia a las compras nuevas; las ventas históricas no cambian.
create or replace function public.apply_customer_credit_due_date()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_due_date date;
begin
  if new.payment_type = 'credito' and new.customer_id is not null then
    select c.credit_due_date into v_due_date
    from public.customers c
    where c.id = new.customer_id;

    if v_due_date is not null then
      new.due_date := v_due_date;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists sales_00_customer_credit_due_date on public.sales;
create trigger sales_00_customer_credit_due_date
before insert on public.sales
for each row execute function public.apply_customer_credit_due_date();

-- Resumen global: una sola fila por cliente con saldo pendiente.
create or replace function public.get_customer_credit_accounts()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select p.role into v_role from public.profiles p where p.id = auth.uid();
  if v_role not in ('admin','vendedor') then
    raise exception 'No tienes permiso para consultar cuentas de crédito';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'customer_id', a.customer_id,
      'customer_name', a.customer_name,
      'phone', a.phone,
      'credit_due_date', a.credit_due_date,
      'open_purchases', a.open_purchases,
      'total_registered', a.total_registered,
      'total_paid', a.total_paid,
      'balance', a.balance,
      'next_due_date', a.next_due_date
    ) order by a.next_due_date nulls last, a.customer_name
  ), '[]'::jsonb)
  into v_result
  from (
    select
      c.id as customer_id,
      c.name as customer_name,
      c.phone,
      c.credit_due_date,
      count(*) filter (where s.total > coalesce(s.paid_amount,0))::integer as open_purchases,
      coalesce(sum(s.total),0)::numeric(12,2) as total_registered,
      coalesce(sum(coalesce(s.paid_amount,0)),0)::numeric(12,2) as total_paid,
      coalesce(sum(s.total-coalesce(s.paid_amount,0)),0)::numeric(12,2) as balance,
      min(s.due_date) filter (where s.total > coalesce(s.paid_amount,0)) as next_due_date
    from public.customers c
    join public.sales s on s.customer_id = c.id and s.payment_type = 'credito'
    group by c.id, c.name, c.phone, c.credit_due_date
    having sum(s.total-coalesce(s.paid_amount,0)) > 0
  ) a;

  return v_result;
end;
$$;

-- Detalle global de una cuenta: compras de todos los responsables y sus abonos.
create or replace function public.get_customer_credit_account(p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select p.role into v_role from public.profiles p where p.id = auth.uid();
  if v_role not in ('admin','vendedor') then
    raise exception 'No tienes permiso para consultar cuentas de crédito';
  end if;

  if not exists (select 1 from public.customers c where c.id = p_customer_id) then
    raise exception 'Cliente no encontrado';
  end if;

  select jsonb_build_object(
    'customer', (
      select jsonb_build_object(
        'id', c.id, 'name', c.name, 'phone', c.phone,
        'address', c.address, 'credit_due_date', c.credit_due_date
      ) from public.customers c where c.id = p_customer_id
    ),
    'purchases', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', s.id,
          'sale_code', s.sale_code,
          'created_at', s.created_at,
          'total', s.total,
          'paid_amount', s.paid_amount,
          'due_date', s.due_date,
          'next_payment_date', s.next_payment_date,
          'credit_status', s.credit_status,
          'comments', s.comments,
          'seller_id', s.seller_id,
          'seller_name', coalesce(nullif(s.seller_name,''), sp.full_name, 'Responsable no identificado'),
          'seller_code', coalesce(nullif(s.seller_code,''), sp.seller_code, 'Sin código'),
          'items', coalesce((
            select jsonb_agg(jsonb_build_object(
              'product_name', si.product_name,
              'quantity', coalesce(si.quantity_in_unit,si.quantity),
              'unit_name', coalesce(si.unit_name_snapshot,si.base_unit_snapshot,'unidad'),
              'line_total', si.line_total
            ) order by si.id)
            from public.sale_items si where si.sale_id = s.id
          ), '[]'::jsonb),
          'payments', coalesce((
            select jsonb_agg(jsonb_build_object(
              'id', py.id,
              'amount', py.amount,
              'payment_method', py.payment_method,
              'created_at', py.created_at,
              'note', py.note,
              'received_by', py.received_by,
              'account_payment_id', py.account_payment_id
            ) order by py.created_at, py.id)
            from public.payments py where py.sale_id = s.id
          ), '[]'::jsonb)
        ) order by s.created_at desc, s.id desc
      )
      from public.sales s
      left join public.profiles sp on sp.id = coalesce(s.seller_id,s.created_by)
      where s.customer_id = p_customer_id and s.payment_type = 'credito'
    ), '[]'::jsonb),
    'account_payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', cap.id,
        'amount', cap.amount,
        'payment_method', cap.payment_method,
        'note', cap.note,
        'created_at', cap.created_at,
        'received_by', cap.received_by,
        'receiver_name', coalesce(rp.full_name,'Responsable no identificado'),
        'receiver_code', coalesce(rp.seller_code,'Sin código'),
        'allocations', coalesce((
          select jsonb_agg(jsonb_build_object(
            'sale_code', s.sale_code,
            'amount', py.amount
          ) order by s.created_at desc, s.id desc)
          from public.payments py
          join public.sales s on s.id = py.sale_id
          where py.account_payment_id = cap.id
        ), '[]'::jsonb)
      ) order by cap.created_at desc)
      from public.customer_account_payments cap
      left join public.profiles rp on rp.id = cap.received_by
      where cap.customer_id = p_customer_id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- Créditos sin cliente asignado: permanecen separados y no se mezclan con cuentas de clientes.
create or replace function public.get_unassigned_credit_sales()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select p.role into v_role from public.profiles p where p.id = auth.uid();
  if v_role not in ('admin','vendedor') then
    raise exception 'No tienes permiso para consultar créditos';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'sale_code', s.sale_code,
    'created_at', s.created_at,
    'customer_name', s.customer_name,
    'total', s.total,
    'paid_amount', s.paid_amount,
    'balance', s.total-coalesce(s.paid_amount,0),
    'due_date', s.due_date,
    'next_payment_date', s.next_payment_date,
    'seller_id', s.seller_id,
    'seller_name', coalesce(nullif(s.seller_name,''),p.full_name,'Responsable no identificado'),
    'seller_code', coalesce(nullif(s.seller_code,''),p.seller_code,'Sin código')
  ) order by s.created_at desc, s.id desc), '[]'::jsonb)
  into v_result
  from public.sales s
  left join public.profiles p on p.id=coalesce(s.seller_id,s.created_by)
  where s.payment_type='credito'
    and s.customer_id is null
    and s.total>coalesce(s.paid_amount,0)
    and (v_role='admin' or s.seller_id=auth.uid());

  return v_result;
end;
$$;

-- Abono global: un solo registro de recepción y distribución LIFO, dentro de una transacción.
create or replace function public.register_customer_account_payment(
  p_customer_id uuid,
  p_amount numeric,
  p_note text default null,
  p_payment_method text default 'efectivo'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_customer_name text;
  v_cash_session_id uuid;
  v_account_payment_id uuid;
  v_balance numeric(12,2);
  v_remaining numeric(12,2);
  v_allocation numeric(12,2);
  v_sale record;
  v_allocations jsonb := '[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  select p.role into v_role from public.profiles p where p.id=auth.uid();
  if v_role not in ('admin','vendedor') then
    raise exception 'No tienes permiso para registrar abonos';
  end if;
  if p_customer_id is null then raise exception 'Selecciona un cliente';
  if p_amount is null or p_amount<=0 or round(p_amount,2)<>p_amount then
    raise exception 'El abono debe ser mayor que cero y tener como máximo dos decimales';
  end if;
  if p_payment_method is null or p_payment_method not in ('efectivo','qr','transferencia') then
    raise exception 'Método de pago inválido';
  end if;

  select c.name into v_customer_name
  from public.customers c where c.id=p_customer_id for update;
  if not found then raise exception 'Cliente no encontrado'; end if;

  select coalesce(sum(s.total-coalesce(s.paid_amount,0)),0)
  into v_balance
  from public.sales s
  where s.customer_id=p_customer_id
    and s.payment_type='credito'
    and s.total>coalesce(s.paid_amount,0);
  if p_amount>v_balance then raise exception 'El abono supera el saldo global pendiente'; end if;

  -- El dinero ingresa a la caja de quien efectivamente recibe el pago.
  select cs.id into v_cash_session_id
  from public.cash_sessions cs
  where cs.seller_id=auth.uid() and cs.status='open'
  order by cs.opened_at desc
  limit 1 for update;
  if v_cash_session_id is null then
    raise exception 'Debes tener una caja abierta para recibir este abono';
  end if;

  insert into public.customer_account_payments(
    customer_id,amount,payment_method,note,received_by,cash_session_id
  ) values (
    p_customer_id,p_amount,p_payment_method,nullif(trim(p_note),''),auth.uid(),v_cash_session_id
  ) returning id into v_account_payment_id;

  v_remaining := p_amount;
  for v_sale in
    select s.id,s.sale_code,s.total,s.paid_amount,s.created_at
    from public.sales s
    where s.customer_id=p_customer_id
      and s.payment_type='credito'
      and s.total>coalesce(s.paid_amount,0)
    order by s.created_at desc, s.id desc
    for update
  loop
    exit when v_remaining<=0;
    v_allocation := least(v_remaining, v_sale.total-coalesce(v_sale.paid_amount,0));
    if v_allocation>0 then
      update public.sales
      set paid_amount=coalesce(paid_amount,0)+v_allocation
      where id=v_sale.id;

      insert into public.payments(
        sale_id,amount,note,received_by,payment_method,cash_session_id,account_payment_id
      ) values (
        v_sale.id,v_allocation,
        coalesce(nullif(trim(p_note),''),'Abono global de cuenta · '||v_customer_name),
        auth.uid(),p_payment_method,v_cash_session_id,v_account_payment_id
      );

      v_allocations := v_allocations || jsonb_build_array(jsonb_build_object(
        'sale_id',v_sale.id,
        'sale_code',v_sale.sale_code,
        'amount',v_allocation
      ));
      v_remaining := v_remaining-v_allocation;
    end if;
  end loop;

  if v_remaining<>0 then
    raise exception 'No se pudo distribuir íntegramente el abono; la operación fue cancelada';
  end if;

  -- Un solo movimiento de caja por el importe recibido, no uno por cada compra.
  insert into public.cash_movements(
    cash_session_id,seller_id,movement_type,payment_method,amount,description
  ) values (
    v_cash_session_id,auth.uid(),'credit_payment',p_payment_method,p_amount,
    'Abono global de cuenta · '||v_customer_name||' · Ref. '||left(v_account_payment_id::text,8)
  );

  return jsonb_build_object(
    'success',true,
    'account_payment_id',v_account_payment_id,
    'amount',p_amount,
    'new_balance',v_balance-p_amount,
    'allocations',v_allocations
  );
end;
$$;

revoke execute on function public.get_customer_credit_accounts() from public, anon;
revoke execute on function public.get_customer_credit_account(uuid) from public, anon;
revoke execute on function public.get_unassigned_credit_sales() from public, anon;
revoke execute on function public.register_customer_account_payment(uuid,numeric,text,text) from public, anon;
grant execute on function public.get_customer_credit_accounts() to authenticated;
grant execute on function public.get_customer_credit_account(uuid) to authenticated;
grant execute on function public.get_unassigned_credit_sales() to authenticated;
grant execute on function public.register_customer_account_payment(uuid,numeric,text,text) to authenticated;
