-- SISTEMA MEJIA — instalación inicial del entorno AISLADO DE PRUEBAS
-- Proyecto esperado: vrgfwefnkrdwrtdymfin
-- NO ejecutar en producción (aqjhsrwzdnugwcgeqohg).
-- Crear Auth users desde Authentication después de ejecutar este archivo.
-- El primer administrador se asigna manualmente; ningún registro público
-- permite que un usuario se conceda el rol admin.
--
-- Este bootstrap está basado en el snapshot real de producción compartido
-- por el usuario. Crea tablas vacías: NO copia ni elimina datos de producción.
-- Si alguna tabla de negocio ya existe, aborta antes de crear objetos.

begin;

do $guard$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema='public'
      and table_name in (
        'profiles','products','customers','sales','sale_items','payments',
        'cash_sessions','cash_movements','cash_registers'
      )
  ) then
    raise exception 'El esquema de pruebas ya contiene tablas de SISTEMA MEJIA. Detenerse y revisar antes de ejecutar este bootstrap.';
  end if;
end
$guard$;

create extension if not exists pgcrypto;

-- 1. Tablas y relaciones
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null default 'vendedor'
    constraint profiles_role_check check (role in ('admin','vendedor')),
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text unique,
  price numeric(12,2) not null default 0 check (price>=0),
  stock integer not null default 0 check (stock>=0),
  image_url text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  wholesale_price numeric(12,2) not null default 0 check (wholesale_price>=0),
  retail_price numeric(12,2) not null default 0 check (retail_price>=0),
  barcode text
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.cash_sessions (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id),
  opening_amount numeric(12,2) not null check (opening_amount>=0),
  opened_at timestamptz not null default now(),
  closing_amount numeric(12,2),
  expected_cash numeric(12,2),
  expected_qr numeric(12,2),
  difference numeric(12,2),
  closed_at timestamptz,
  status text not null default 'open' check (status in ('open','closed')),
  notes text,
  created_at timestamptz not null default now()
);

-- Tabla heredada conservada por compatibilidad; la interfaz nueva usa cash_sessions.
create table public.cash_registers (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id),
  opened_at timestamptz not null default now(),
  opening_amount numeric(12,2) not null default 0 check (opening_amount>=0),
  opening_cash numeric(12,2) not null default 0 check (opening_cash>=0),
  opening_kr numeric(12,2) not null default 0 check (opening_kr>=0),
  closed_at timestamptz,
  closing_cash numeric(12,2),
  closing_kr numeric(12,2),
  closing_total numeric(12,2),
  notes text,
  created_at timestamptz not null default now(),
  constraint cash_registers_close_fields_check check (
    (closing_cash is null and closing_kr is null and closed_at is null)
    or
    (closing_cash is not null and closing_kr is not null and closed_at is not null)
  )
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers(id) on delete set null,
  payment_type text not null check (payment_type in ('contado','credito')),
  total numeric(12,2) not null check (total>=0),
  paid_amount numeric(12,2) not null default 0 check (paid_amount>=0),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  sale_type text not null default 'minorista' check (sale_type in ('mayorista','minorista')),
  payment_method text,
  cash_session_id uuid references public.cash_sessions(id),
  seller_id uuid references auth.users(id),
  sale_kind text not null default 'menor' check (sale_kind in ('mayor','menor')),
  customer_name text,
  cash_register_id uuid references public.cash_registers(id) on delete set null,
  sale_code text,
  comments text,
  cash_amount numeric(12,2) not null default 0,
  yape_amount numeric(12,2) not null default 0
);

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  quantity integer not null check (quantity>0),
  unit_price numeric(12,2) not null check (unit_price>=0),
  line_total numeric(12,2) not null check (line_total>=0)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  amount numeric(12,2) not null check (amount>0),
  note text,
  received_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  payment_method text not null default 'efectivo'
    check (payment_method in ('efectivo','qr','transferencia')),
  cash_session_id uuid references public.cash_sessions(id)
);

create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  cash_session_id uuid not null references public.cash_sessions(id) on delete cascade,
  seller_id uuid not null references auth.users(id),
  movement_type text not null
    check (movement_type in ('sale','credit_advance','credit_payment','opening','adjustment')),
  payment_method text not null
    check (payment_method in ('efectivo','qr','transferencia')),
  amount numeric(12,2) not null check (amount>=0),
  sale_id uuid references public.sales(id) on delete set null,
  payment_id uuid references public.payments(id) on delete set null,
  description text,
  created_at timestamptz not null default now()
);

-- 2. Índices presentes/necesarios en el esquema real
create unique index sales_sale_code_uidx on public.sales(sale_code) where sale_code is not null;
create index sales_created_at_idx on public.sales(created_at desc);
create index sale_items_sale_id_idx on public.sale_items(sale_id);
create index payments_sale_id_idx on public.payments(sale_id);
create index cash_sessions_seller_status_idx on public.cash_sessions(seller_id,status);
create index cash_movements_session_idx on public.cash_movements(cash_session_id);
create index customers_name_idx on public.customers(name);

-- 3. Función de autorización usada por las políticas
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $function$
  select exists (
    select 1 from public.profiles
    where id=auth.uid() and role='admin'
  );
$function$;

-- 4. Protección de rol: un usuario no puede elevarse a administrador.
create or replace function public.prevent_profile_role_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if new.role is distinct from old.role and not public.is_admin() then
    raise exception 'No tienes permiso para modificar el rol del perfil';
  end if;
  return new;
end
$function$;

create trigger protect_profile_role
before update of role on public.profiles
for each row execute function public.prevent_profile_role_escalation();

-- Los nuevos usuarios reciben siempre rol vendedor.
-- El primer admin se asigna manualmente desde SQL Editor después del alta.
create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  insert into public.profiles(id,full_name,role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name',split_part(coalesce(new.email,''),'@',1)),
    'vendedor'
  )
  on conflict (id) do nothing;
  return new;
end
$function$;

create trigger create_profile_after_signup
after insert on auth.users
for each row execute function public.handle_new_user_profile();

-- 5. Funciones operativas conservadas con las firmas del snapshot

create or replace function public.open_cash_session(p_opening_amount numeric)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if p_opening_amount is null or p_opening_amount<0 then raise exception 'Monto inicial inválido'; end if;
  insert into public.cash_sessions(seller_id,opening_amount)
  values(auth.uid(),p_opening_amount) returning id into v_id;
  insert into public.cash_movements(
    cash_session_id,seller_id,movement_type,payment_method,amount,description
  )
  values(v_id,auth.uid(),'opening','efectivo',p_opening_amount,'Monto inicial de caja');
  return v_id;
end
$function$;

create or replace function public.close_cash_session(
  p_session_id uuid,
  p_counted_cash numeric,
  p_counted_qr numeric default 0,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v public.cash_sessions%rowtype;
  v_cash numeric(12,2);
  v_qr numeric(12,2);
  v_diff numeric(12,2);
begin
  select * into v from public.cash_sessions where id=p_session_id for update;
  if not found then raise exception 'Caja no encontrada'; end if;
  if v.seller_id<>auth.uid() and not public.is_admin() then
    raise exception 'No tienes permiso para cerrar esta caja';
  end if;
  if v.status<>'open' then raise exception 'La caja ya está cerrada'; end if;
  if p_counted_cash is null or p_counted_cash<0 or p_counted_qr is null or p_counted_qr<0 then
    raise exception 'Importes de cierre inválidos';
  end if;
  select coalesce(sum(amount),0) into v_cash
  from public.cash_movements
  where cash_session_id=p_session_id
    and payment_method='efectivo' and movement_type<>'opening';
  select coalesce(sum(amount),0) into v_qr
  from public.cash_movements
  where cash_session_id=p_session_id and payment_method='qr';
  v_diff=(p_counted_cash-(v.opening_amount+v_cash))+(p_counted_qr-v_qr);
  update public.cash_sessions
  set closing_amount=p_counted_cash,
      expected_cash=v.opening_amount+v_cash,
      expected_qr=v_qr,
      difference=v_diff,
      closed_at=now(),
      status='closed',
      notes=p_notes
  where id=p_session_id;
  return jsonb_build_object(
    'expected_cash',v.opening_amount+v_cash,
    'expected_qr',v_qr,
    'counted_cash',p_counted_cash,
    'counted_qr',p_counted_qr,
    'difference',v_diff
  );
end
$function$;

create or replace function public.finalize_sale(
  p_customer_id uuid,
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
  v_total numeric(12,2):=0;
  v_paid numeric(12,2):=0;
  v_sale uuid;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty integer;
  v_unit numeric(12,2);
  v_line numeric(12,2);
  v_method text;
  v_amount numeric(12,2);
  v_payment uuid;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if p_sale_type not in ('mayorista','minorista') then raise exception 'Tipo de venta inválido'; end if;
  if p_payment_type not in ('contado','credito') then raise exception 'Tipo de pago inválido'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'El carrito está vacío';
  end if;
  if p_payments is null or jsonb_typeof(p_payments)<>'array' then
    raise exception 'Detalle de pagos inválido';
  end if;
  select id into v_cash from public.cash_sessions
  where seller_id=auth.uid() and status='open' limit 1;
  if v_cash is null then raise exception 'Primero debes abrir tu caja'; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_product from public.products
    where id=(v_item->>'product_id')::uuid for update;
    if not found then raise exception 'Uno de los productos ya no existe'; end if;
    v_qty=(v_item->>'quantity')::integer;
    if v_qty is null or v_qty<1 then raise exception 'Cantidad inválida'; end if;
    if v_product.stock<v_qty then raise exception 'Stock insuficiente para %',v_product.name; end if;
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
    if v_method not in ('efectivo','qr','transferencia') or v_amount is null or v_amount<=0 then
      raise exception 'Detalle de pago inválido';
    end if;
    v_paid=v_paid+v_amount;
  end loop;
  if p_payment_type='contado' and abs(v_paid-v_total)>0.009 then
    raise exception 'Los pagos deben sumar exactamente el total';
  end if;
  if p_payment_type='credito' and v_paid>v_total then
    raise exception 'El adelanto no puede superar el total';
  end if;

  insert into public.sales(
    customer_id,payment_type,total,paid_amount,created_by,created_at,
    sale_type,payment_method,cash_session_id,seller_id
  )
  values(
    p_customer_id,p_payment_type,v_total,v_paid,auth.uid(),now(),p_sale_type,
    case
      when (select count(distinct x->>'method') from jsonb_array_elements(p_payments) as t(x))>1
        then 'mixto'
      else (p_payments->0->>'method')
    end,
    v_cash,auth.uid()
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
      v_cash,auth.uid(),
      case when p_payment_type='credito' then 'credit_advance' else 'sale' end,
      v_method,v_amount,v_sale,v_payment,
      case when p_payment_type='credito' then 'Adelanto de crédito' else 'Venta al contado' end
    );
  end loop;
  return v_sale;
end
$function$;

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

  select id into v_cash from public.cash_sessions
  where seller_id=auth.uid() and status='open' limit 1;
  if v_cash is null then raise exception 'Primero debes abrir tu caja'; end if;

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
    if (
      select coalesce(sum((x->>'quantity')::integer),0)
      from jsonb_array_elements(p_items) as a(x)
      where x->>'product_id'=v_product.id::text
    )>v_product.stock then
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

  v_sale_code='VTA-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));

  insert into public.sales(
    customer_id,payment_type,total,paid_amount,created_by,created_at,
    sale_type,payment_method,cash_session_id,seller_id,
    sale_code,comments,customer_name,cash_amount,yape_amount
  )
  values(
    p_customer_id,p_payment_type,v_total,v_paid,auth.uid(),now(),
    p_sale_type,
    case
      when (select count(distinct x->>'method')
            from jsonb_array_elements(p_payments) as t(x))>1 then 'mixto'
      else p_payments->0->>'method'
    end,
    v_cash,auth.uid(),v_sale_code,nullif(trim(p_comments),''),v_customer_name,
    v_cash_amount,v_yape_amount
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
      v_cash,auth.uid(),
      case when p_payment_type='credito' then 'credit_advance' else 'sale' end,
      v_method,v_amount,v_sale,v_payment,
      case when p_payment_type='credito' then 'Adelanto de crédito' else 'Venta al contado' end
    );
  end loop;
  return v_sale;
end
$function$;

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
  select * into v_session from public.cash_sessions where id=p_session_id for share;
  if not found then raise exception 'Caja no encontrada'; end if;
  if v_session.seller_id<>auth.uid() and not public.is_admin() then
    raise exception 'No tienes permiso para consultar esta caja';
  end if;
  select coalesce(sum(amount),0) into v_cash
  from public.cash_movements
  where cash_session_id=p_session_id and payment_method='efectivo'
    and movement_type<>'opening';
  select coalesce(sum(amount),0) into v_qr
  from public.cash_movements
  where cash_session_id=p_session_id and payment_method='qr';
  select coalesce(sum(total),0),coalesce(sum(paid_amount),0),
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
    'sales_grand_total',(select coalesce(sum(total),0)
                         from public.sales where cash_session_id=p_session_id)
  );
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
  if p_payment_method not in ('efectivo','qr','transferencia') then
    raise exception 'Forma de pago inválida';
  end if;
  select * into s from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Venta no encontrada'; end if;
  if s.created_by<>auth.uid() and not public.is_admin() then
    raise exception 'No tienes permiso para registrar este abono';
  end if;
  if s.payment_type<>'credito' then raise exception 'La venta no es al crédito'; end if;
  if p_amount>s.total-s.paid_amount then raise exception 'El abono supera el saldo pendiente'; end if;
  select id into v_cash from public.cash_sessions
  where seller_id=auth.uid() and status='open' limit 1;
  insert into public.payments(
    sale_id,amount,note,received_by,payment_method,cash_session_id
  )
  values(p_sale_id,p_amount,p_note,auth.uid(),p_payment_method,v_cash)
  returning id into payment_id;
  update public.sales set paid_amount=paid_amount+p_amount where id=p_sale_id;
  if v_cash is not null then
    insert into public.cash_movements(
      cash_session_id,seller_id,movement_type,payment_method,amount,sale_id,payment_id,description
    )
    values(
      v_cash,auth.uid(),'credit_payment',p_payment_method,p_amount,p_sale_id,payment_id,
      'Abono de crédito'
    );
  end if;
  return jsonb_build_object(
    'success',true,'payment_id',payment_id,
    'new_balance',s.total-s.paid_amount-p_amount
  );
end
$function$;

-- 6. RLS y políticas: equivalentes a las del snapshot, con protección
-- adicional para que INSERT/UPDATE de profiles no permita autoasignar admin.
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.payments enable row level security;
alter table public.cash_sessions enable row level security;
alter table public.cash_movements enable row level security;
alter table public.cash_registers enable row level security;

create policy "profiles read self or admin"
on public.profiles for select to authenticated
using (id=auth.uid() or public.is_admin());

create policy "profiles insert self vendedor or admin"
on public.profiles for insert to authenticated
with check (id=auth.uid() and role='vendedor' or public.is_admin());

create policy "profile update self or admin"
on public.profiles for update to authenticated
using (id=auth.uid() or public.is_admin())
with check (id=auth.uid() or public.is_admin());

create policy "products read auth"
on public.products for select to authenticated using (true);

create policy "products insert admin"
on public.products for insert to authenticated with check (public.is_admin());

create policy "products update admin"
on public.products for update to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy "products delete admin"
on public.products for delete to authenticated using (public.is_admin());

create policy "customers insert auth"
on public.customers for insert to authenticated with check (true);

create policy "customers read auth"
on public.customers for select to authenticated using (true);

create policy "customers update admin or own seller"
on public.customers for update to authenticated
using (public.is_admin() or created_by=auth.uid())
with check (public.is_admin() or created_by=auth.uid());

create policy "sales insert auth"
on public.sales for insert to authenticated with check (created_by=auth.uid());

create policy "sales read own or admin"
on public.sales for select to authenticated
using (created_by=auth.uid() or public.is_admin());

create policy "sales update admin only"
on public.sales for update to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy "items insert sale access"
on public.sale_items for insert to authenticated
with check (
  exists(select 1 from public.sales s
         where s.id=sale_items.sale_id
           and (s.created_by=auth.uid() or public.is_admin()))
);

create policy "items read sale access"
on public.sale_items for select to authenticated
using (
  exists(select 1 from public.sales s
         where s.id=sale_items.sale_id
           and (s.created_by=auth.uid() or public.is_admin()))
);

create policy "payments insert sale access"
on public.payments for insert to authenticated
with check (
  received_by=auth.uid()
  and exists(select 1 from public.sales s
             where s.id=payments.sale_id
               and (s.created_by=auth.uid() or public.is_admin()))
);

create policy "payments read sale access"
on public.payments for select to authenticated
using (
  exists(select 1 from public.sales s
         where s.id=payments.sale_id
           and (s.created_by=auth.uid() or public.is_admin()))
);

create policy "cash sessions insert own"
on public.cash_sessions for insert to authenticated
with check (seller_id=auth.uid());

create policy "cash sessions read own admin"
on public.cash_sessions for select to authenticated
using (seller_id=auth.uid() or public.is_admin());

create policy "cash sessions update own open admin"
on public.cash_sessions for update to authenticated
using ((seller_id=auth.uid() and status='open') or public.is_admin())
with check (seller_id=auth.uid() or public.is_admin());

create policy "cash movements insert own"
on public.cash_movements for insert to authenticated
with check (
  seller_id=auth.uid()
  and exists(select 1 from public.cash_sessions cs
             where cs.id=cash_movements.cash_session_id
               and cs.seller_id=auth.uid() and cs.status='open')
);

create policy "cash movements read own admin"
on public.cash_movements for select to authenticated
using (seller_id=auth.uid() or public.is_admin());

create policy "cash register insert own"
on public.cash_registers for insert to authenticated
with check (seller_id=auth.uid());

create policy "cash register read own or admin"
on public.cash_registers for select to authenticated
using (seller_id=auth.uid() or public.is_admin());

create policy "cash register close own or admin"
on public.cash_registers for update to authenticated
using (seller_id=auth.uid() or public.is_admin())
with check (seller_id=auth.uid() or public.is_admin());

-- 7. Permisos SQL explícitos
grant usage on schema public to authenticated;
grant select,insert,update on public.profiles to authenticated;
grant select,insert,update,delete on public.products to authenticated;
grant select,insert,update on public.customers to authenticated;
grant select,insert,update on public.sales to authenticated;
grant select,insert on public.sale_items to authenticated;
grant select,insert on public.payments to authenticated;
grant select,insert,update on public.cash_sessions to authenticated;
grant select,insert on public.cash_movements to authenticated;
grant select,insert,update on public.cash_registers to authenticated;

revoke all on function public.is_admin() from public, anon;
revoke all on function public.prevent_profile_role_escalation() from public, anon, authenticated;
revoke all on function public.handle_new_user_profile() from public, anon, authenticated;
revoke all on function public.open_cash_session(numeric) from public, anon;
revoke all on function public.close_cash_session(uuid,numeric,numeric,text) from public, anon;
revoke all on function public.finalize_sale(uuid,text,text,jsonb,jsonb) from public, anon;
revoke all on function public.finalize_sale_v2(uuid,text,text,text,text,jsonb,jsonb) from public, anon;
revoke all on function public.get_cash_session_summary(uuid) from public, anon;
revoke all on function public.register_payment(uuid,numeric,text,text) from public, anon;

grant execute on function public.is_admin() to authenticated;
grant execute on function public.open_cash_session(numeric) to authenticated;
grant execute on function public.close_cash_session(uuid,numeric,numeric,text) to authenticated;
grant execute on function public.finalize_sale(uuid,text,text,jsonb,jsonb) to authenticated;
grant execute on function public.finalize_sale_v2(uuid,text,text,text,text,jsonb,jsonb) to authenticated;
grant execute on function public.get_cash_session_summary(uuid) to authenticated;
grant execute on function public.register_payment(uuid,numeric,text,text) to authenticated;

-- 8. Storage para imágenes de productos
insert into storage.buckets(id,name,public)
values('product-images','product-images',true);

create policy "product images view"
on storage.objects for select to authenticated
using (bucket_id='product-images');

create policy "product images upload own folder"
on storage.objects for insert to authenticated
with check (
  bucket_id='product-images'
  and (storage.foldername(name))[1]=auth.uid()::text
);

create policy "product images update own folder"
on storage.objects for update to authenticated
using (
  bucket_id='product-images'
  and (storage.foldername(name))[1]=auth.uid()::text
)
with check (
  bucket_id='product-images'
  and (storage.foldername(name))[1]=auth.uid()::text
);

commit;

-- 9. Configuración posterior (ejecutar manualmente después de crear Auth users):
-- Para promover la cuenta elegida como administradora, sustituir el UUID:
-- update public.profiles set role='admin', full_name='Administrador'
-- where id='UUID_REAL_DEL_USUARIO';
--
-- Para comprobar el esquema y permisos:
-- select table_name from information_schema.tables
-- where table_schema='public' and table_name in
-- ('profiles','products','customers','sales','sale_items','payments',
--  'cash_sessions','cash_movements','cash_registers') order by table_name;
-- select p.oid::regprocedure,
--   has_function_privilege('anon',p.oid,'EXECUTE') anon_exec,
--   has_function_privilege('authenticated',p.oid,'EXECUTE') auth_exec
-- from pg_proc p join pg_namespace n on n.oid=p.pronamespace
-- where n.nspname='public' and p.proname in
-- ('close_cash_session','finalize_sale','finalize_sale_v2',
--  'get_cash_session_summary','is_admin','open_cash_session','register_payment')
-- order by p.proname;
