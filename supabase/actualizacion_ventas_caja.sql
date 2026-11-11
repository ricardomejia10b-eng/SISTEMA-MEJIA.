-- SISTEMA MEJIA: ampliación de ventas, créditos y caja
-- Ejecutar una sola vez en Supabase SQL Editor después del esquema base.
begin;

alter table public.products
  add column if not exists wholesale_price numeric(12,2) not null default 0 check (wholesale_price >= 0),
  add column if not exists retail_price numeric(12,2) not null default 0 check (retail_price >= 0),
  add column if not exists barcode text;
update public.products
set retail_price = case when retail_price=0 then price else retail_price end,
    wholesale_price = case when wholesale_price=0 then price else wholesale_price end
where retail_price=0 or wholesale_price=0;
create unique index if not exists products_barcode_unique on public.products(barcode) where barcode is not null and barcode <> '';

alter table public.sales
  add column if not exists sale_type text not null default 'minorista' check (sale_type in ('mayorista','minorista')),
  add column if not exists payment_method text,
  add column if not exists cash_session_id uuid,
  add column if not exists seller_id uuid references auth.users(id);
update public.sales set seller_id=created_by where seller_id is null;

alter table public.payments
  add column if not exists payment_method text not null default 'efectivo' check (payment_method in ('efectivo','qr','transferencia')),
  add column if not exists cash_session_id uuid;

create table if not exists public.cash_sessions (
 id uuid primary key default gen_random_uuid(),
 seller_id uuid not null references auth.users(id),
 opening_amount numeric(12,2) not null check(opening_amount>=0),
 opened_at timestamptz not null default now(),
 closing_amount numeric(12,2),
 expected_cash numeric(12,2),
 expected_qr numeric(12,2),
 difference numeric(12,2),
 closed_at timestamptz,
 status text not null default 'open' check(status in ('open','closed')),
 notes text,
 created_at timestamptz not null default now()
);
create unique index if not exists one_open_cash_per_seller on public.cash_sessions(seller_id) where status='open';

alter table public.sales drop constraint if exists sales_cash_session_id_fkey;
alter table public.sales add constraint sales_cash_session_id_fkey foreign key(cash_session_id) references public.cash_sessions(id);
alter table public.payments drop constraint if exists payments_cash_session_id_fkey;
alter table public.payments add constraint payments_cash_session_id_fkey foreign key(cash_session_id) references public.cash_sessions(id);

create table if not exists public.cash_movements (
 id uuid primary key default gen_random_uuid(),
 cash_session_id uuid not null references public.cash_sessions(id) on delete cascade,
 seller_id uuid not null references auth.users(id),
 movement_type text not null check(movement_type in ('sale','credit_advance','credit_payment','opening','adjustment')),
 payment_method text not null check(payment_method in ('efectivo','qr','transferencia')),
 amount numeric(12,2) not null check(amount>=0),
 sale_id uuid references public.sales(id) on delete set null,
 payment_id uuid references public.payments(id) on delete set null,
 description text,
 created_at timestamptz not null default now()
);

-- Reemplazar políticas permisivas del esquema inicial por controles por rol.
drop policy if exists "products insert auth" on public.products;
drop policy if exists "products update auth" on public.products;
drop policy if exists "products delete admin" on public.products;
create policy "products insert admin" on public.products for insert to authenticated with check(public.is_admin());
create policy "products update admin" on public.products for update to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "products delete admin" on public.products for delete to authenticated using(public.is_admin());

drop policy if exists "customers update auth" on public.customers;
create policy "customers update admin or own seller" on public.customers for update to authenticated
using(public.is_admin() or created_by=auth.uid()) with check(public.is_admin() or created_by=auth.uid());

drop policy if exists "sales update own or admin" on public.sales;
create policy "sales update admin only" on public.sales for update to authenticated using(public.is_admin()) with check(public.is_admin());

alter table public.cash_sessions enable row level security;
alter table public.cash_movements enable row level security;
drop policy if exists "cash sessions read own admin" on public.cash_sessions;
create policy "cash sessions read own admin" on public.cash_sessions for select to authenticated using(seller_id=auth.uid() or public.is_admin());
drop policy if exists "cash sessions insert own" on public.cash_sessions;
create policy "cash sessions insert own" on public.cash_sessions for insert to authenticated with check(seller_id=auth.uid());
drop policy if exists "cash sessions update own open admin" on public.cash_sessions;
create policy "cash sessions update own open admin" on public.cash_sessions for update to authenticated
using((seller_id=auth.uid() and status='open') or public.is_admin())
with check((seller_id=auth.uid()) or public.is_admin());
drop policy if exists "cash movements read own admin" on public.cash_movements;
create policy "cash movements read own admin" on public.cash_movements for select to authenticated using(seller_id=auth.uid() or public.is_admin());
drop policy if exists "cash movements insert own" on public.cash_movements;
create policy "cash movements insert own" on public.cash_movements for insert to authenticated with check(seller_id=auth.uid() and exists(select 1 from public.cash_sessions cs where cs.id=cash_session_id and cs.seller_id=auth.uid() and cs.status='open'));

-- Cada vendedor solo puede registrar cobros en una caja abierta propia.
create or replace function public.open_cash_session(p_opening_amount numeric)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 if p_opening_amount is null or p_opening_amount<0 then raise exception 'Monto inicial inválido'; end if;
 insert into public.cash_sessions(seller_id,opening_amount) values(auth.uid(),p_opening_amount) returning id into v_id;
 insert into public.cash_movements(cash_session_id,seller_id,movement_type,payment_method,amount,description)
 values(v_id,auth.uid(),'opening','efectivo',p_opening_amount,'Monto inicial de caja');
 return v_id;
end $$;

create or replace function public.close_cash_session(p_session_id uuid,p_counted_cash numeric,p_counted_qr numeric default 0,p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.cash_sessions%rowtype; v_cash numeric(12,2); v_qr numeric(12,2); v_diff numeric(12,2);
begin
 select * into v from public.cash_sessions where id=p_session_id for update;
 if not found then raise exception 'Caja no encontrada'; end if;
 if v.seller_id<>auth.uid() and not public.is_admin() then raise exception 'No tienes permiso para cerrar esta caja'; end if;
 if v.status<>'open' then raise exception 'La caja ya está cerrada'; end if;
 if p_counted_cash is null or p_counted_cash<0 or p_counted_qr is null or p_counted_qr<0 then raise exception 'Importes de cierre inválidos'; end if;
 select coalesce(sum(amount),0) into v_cash from public.cash_movements where cash_session_id=p_session_id and payment_method='efectivo' and movement_type<>'opening';
 select coalesce(sum(amount),0) into v_qr from public.cash_movements where cash_session_id=p_session_id and payment_method='qr';
 v_diff=(p_counted_cash-(v.opening_amount+v_cash))+(p_counted_qr-v_qr);
 update public.cash_sessions set closing_amount=p_counted_cash,expected_cash=v.opening_amount+v_cash,expected_qr=v_qr,difference=v_diff,closed_at=now(),status='closed',notes=p_notes where id=p_session_id;
 return jsonb_build_object('expected_cash',v.opening_amount+v_cash,'expected_qr',v_qr,'counted_cash',p_counted_cash,'counted_qr',p_counted_qr,'difference',v_diff);
end $$;

-- Abono protegido y contabilizado en la caja abierta del vendedor.
create or replace function public.register_payment(p_sale_id uuid,p_amount numeric,p_note text default null,p_payment_method text default 'efectivo')
returns jsonb language plpgsql security definer set search_path=public as $$
declare s public.sales%rowtype; payment_id uuid; v_cash uuid;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'El monto debe ser mayor que cero'; end if;
 if p_payment_method not in ('efectivo','qr','transferencia') then raise exception 'Forma de pago inválida'; end if;
 select * into s from public.sales where id=p_sale_id for update;
 if not found then raise exception 'Venta no encontrada'; end if;
 if s.created_by<>auth.uid() and not public.is_admin() then raise exception 'No tienes permiso para registrar este abono'; end if;
 if s.payment_type<>'credito' then raise exception 'La venta no es al crédito'; end if;
 if p_amount>s.total-s.paid_amount then raise exception 'El abono supera el saldo pendiente'; end if;
 select id into v_cash from public.cash_sessions where seller_id=auth.uid() and status='open' limit 1;
 insert into public.payments(sale_id,amount,note,received_by,payment_method,cash_session_id)
 values(p_sale_id,p_amount,p_note,auth.uid(),p_payment_method,v_cash) returning id into payment_id;
 update public.sales set paid_amount=paid_amount+p_amount where id=p_sale_id;
 if v_cash is not null then
  insert into public.cash_movements(cash_session_id,seller_id,movement_type,payment_method,amount,sale_id,payment_id,description)
  values(v_cash,auth.uid(),'credit_payment',p_payment_method,p_amount,p_sale_id,payment_id,'Abono de crédito');
 end if;
 return jsonb_build_object('success',true,'payment_id',payment_id,'new_balance',s.total-s.paid_amount-p_amount);
end $$;

grant execute on function public.open_cash_session(numeric) to authenticated;
grant execute on function public.close_cash_session(uuid,numeric,numeric,text) to authenticated;
grant execute on function public.register_payment(uuid,numeric,text,text) to authenticated;


-- Finalización transaccional de carrito, inventario, pagos y caja.
create or replace function public.finalize_sale(
 p_customer_id uuid, p_sale_type text, p_payment_type text, p_items jsonb, p_payments jsonb
) returns uuid language plpgsql security definer set search_path=public as $
declare
 v_cash uuid; v_total numeric(12,2):=0; v_paid numeric(12,2):=0; v_sale uuid;
 v_item jsonb; v_product public.products%rowtype; v_qty integer; v_unit numeric(12,2); v_line numeric(12,2);
 v_method text; v_amount numeric(12,2); v_payment uuid;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 if p_sale_type not in ('mayorista','minorista') then raise exception 'Tipo de venta inválido'; end if;
 if p_payment_type not in ('contado','credito') then raise exception 'Tipo de pago inválido'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'El carrito está vacío'; end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' then raise exception 'Detalle de pagos inválido'; end if;
 select id into v_cash from public.cash_sessions where seller_id=auth.uid() and status='open' limit 1;
 if v_cash is null then raise exception 'Primero debes abrir tu caja'; end if;
 for v_item in select value from jsonb_array_elements(p_items) loop
  select * into v_product from public.products where id=(v_item->>'product_id')::uuid for update;
  if not found then raise exception 'Uno de los productos ya no existe'; end if;
  v_qty=(v_item->>'quantity')::integer;
  if v_qty is null or v_qty<1 then raise exception 'Cantidad inválida'; end if;
  if v_product.stock<v_qty then raise exception 'Stock insuficiente para %',v_product.name; end if;
  v_unit=case when p_sale_type='mayorista' then v_product.wholesale_price else v_product.retail_price end;
  if v_unit<=0 then raise exception 'El producto % no tiene precio configurado para este tipo de venta',v_product.name; end if;
  v_total=v_total+(v_unit*v_qty);
 end loop;
 for v_item in select value from jsonb_array_elements(p_payments) loop
  v_method=v_item->>'method'; v_amount=(v_item->>'amount')::numeric;
  if v_method not in ('efectivo','qr','transferencia') or v_amount is null or v_amount<=0 then raise exception 'Detalle de pago inválido'; end if;
  v_paid=v_paid+v_amount;
 end loop;
 if p_payment_type='contado' and abs(v_paid-v_total)>0.009 then raise exception 'Los pagos deben sumar exactamente el total'; end if;
 if p_payment_type='credito' and v_paid>v_total then raise exception 'El adelanto no puede superar el total'; end if;
 insert into public.sales(customer_id,payment_type,total,paid_amount,created_by,created_at,sale_type,payment_method,cash_session_id,seller_id)
 values(p_customer_id,p_payment_type,v_total,v_paid,auth.uid(),now(),p_sale_type,
  case when (select count(distinct x->>'method') from jsonb_array_elements(p_payments) as t(x))>1 then 'mixto' else (p_payments->0->>'method') end,
  v_cash,auth.uid()) returning id into v_sale;
 for v_item in select value from jsonb_array_elements(p_items) loop
  select * into v_product from public.products where id=(v_item->>'product_id')::uuid for update;
  v_qty=(v_item->>'quantity')::integer;
  v_unit=case when p_sale_type='mayorista' then v_product.wholesale_price else v_product.retail_price end;
  v_line=v_unit*v_qty;
  insert into public.sale_items(sale_id,product_id,product_name,quantity,unit_price,line_total)
  values(v_sale,v_product.id,v_product.name,v_qty,v_unit,v_line);
  update public.products set stock=stock-v_qty where id=v_product.id;
 end loop;
 for v_item in select value from jsonb_array_elements(p_payments) loop
  v_method=v_item->>'method'; v_amount=(v_item->>'amount')::numeric;
  insert into public.payments(sale_id,amount,note,received_by,payment_method,cash_session_id)
  values(v_sale,v_amount,case when p_payment_type='credito' then 'Adelanto inicial' else 'Pago de venta al contado' end,auth.uid(),v_method,v_cash)
  returning id into v_payment;
  insert into public.cash_movements(cash_session_id,seller_id,movement_type,payment_method,amount,sale_id,payment_id,description)
  values(v_cash,auth.uid(),case when p_payment_type='credito' then 'credit_advance' else 'sale' end,v_method,v_amount,v_sale,v_payment,
   case when p_payment_type='credito' then 'Adelanto de crédito' else 'Venta al contado' end);
 end loop;
 return v_sale;
end $;
grant execute on function public.finalize_sale(uuid,text,text,jsonb,jsonb) to authenticated;

commit;
