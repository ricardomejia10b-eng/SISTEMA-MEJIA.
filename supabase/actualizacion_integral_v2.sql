-- SISTEMA MEJÍA — migración aditiva v2
-- SOLO proyecto Supabase de PRUEBAS: vrgfwefnkrdwrtdymfin
-- Preparada para revisión; no ejecutar en producción.
-- No borra tablas, registros, perfiles, funciones ni políticas existentes.

begin;

-- 1. Código permanente de vendedor y preferencia visual por usuario.
alter table public.profiles
  add column if not exists seller_code text,
  add column if not exists preferred_theme text not null default 'light';

update public.profiles
set seller_code = 'VEN-' || upper(substr(replace(id::text, '-', ''), 1, 8))
where role = 'vendedor' and seller_code is null;

create unique index if not exists profiles_seller_code_uidx
  on public.profiles (seller_code)
  where seller_code is not null;

alter table public.profiles
  drop constraint if exists profiles_preferred_theme_check;
alter table public.profiles
  add constraint profiles_preferred_theme_check
  check (preferred_theme in ('light','dark'));

create or replace function public.assign_seller_code()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role = 'vendedor' and (new.seller_code is null or btrim(new.seller_code) = '') then
    new.seller_code := 'VEN-' || upper(substr(replace(new.id::text, '-', ''), 1, 8));
  end if;
  return new;
end;
$$;

drop trigger if exists assign_seller_code_on_profile on public.profiles;
create trigger assign_seller_code_on_profile
before insert or update of role on public.profiles
for each row execute function public.assign_seller_code();

-- 2. Fechas de seguimiento de créditos. Los datos históricos quedan NULL
-- porque no se deben inventar vencimientos o acuerdos pasados.
alter table public.sales
  add column if not exists due_date date,
  add column if not exists next_payment_date date,
  add column if not exists credit_status text;

alter table public.sales
  drop constraint if exists sales_credit_status_check;
alter table public.sales
  add constraint sales_credit_status_check
  check (credit_status is null or credit_status in ('pendiente','parcial','pagado','vencido'));

-- 3. Datos de efectivo entregado y vuelto. El efectivo aplicado a la venta
-- continúa siendo cash_amount; el vuelto no es un movimiento de caja.
alter table public.sales
  add column if not exists cash_tendered numeric(12,2),
  add column if not exists cash_change numeric(12,2) not null default 0;

-- 4. Libro de movimientos de inventario.
create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  movement_type text not null
    check (movement_type in ('stock_initial','sale','stock_in','adjustment','stock_edit')),
  quantity_before integer not null,
  quantity_change integer not null,
  quantity_after integer not null,
  reason text,
  sale_id uuid references public.sales(id) on delete set null,
  performed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists inventory_movements_product_created_idx
  on public.inventory_movements(product_id, created_at desc);
create index if not exists inventory_movements_performed_by_idx
  on public.inventory_movements(performed_by, created_at desc);

alter table public.inventory_movements enable row level security;

drop policy if exists "inventory movements read admin or own" on public.inventory_movements;
create policy "inventory movements read admin or own"
on public.inventory_movements for select to authenticated
using (performed_by = auth.uid() or public.is_admin());

-- Escritura únicamente mediante trigger/RPC privilegiada; no conceder INSERT directo.
revoke all on public.inventory_movements from anon, authenticated;

create or replace function public.log_product_stock_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_reason text := nullif(current_setting('app.inventory_reason', true), '');
  v_sale uuid;
begin
  if tg_op = 'INSERT' then
    insert into public.inventory_movements(
      product_id, product_name, movement_type, quantity_before,
      quantity_change, quantity_after, reason, performed_by
    ) values (
      new.id, new.name, 'stock_initial', 0, new.stock, new.stock,
      coalesce(v_reason, 'Stock registrado al crear producto'), v_user
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
      quantity_change, quantity_after, reason, sale_id, performed_by
    ) values (
      new.id, new.name,
      case
        when v_sale is not null then 'sale'
        when new.stock > old.stock then 'stock_in'
        else 'stock_edit'
      end,
      old.stock, new.stock - old.stock, new.stock,
      coalesce(v_reason,
        case when v_sale is not null then 'Salida por venta'
             when new.stock > old.stock then 'Ingreso de stock'
             else 'Ajuste de stock' end),
      v_sale, v_user
    );
  end if;
  return new;
end;
$$;

drop trigger if exists products_stock_audit on public.products;
create trigger products_stock_audit
after insert or update of stock on public.products
for each row execute function public.log_product_stock_change();

-- La creación de la tabla de auditoría no inventa el stock inicial histórico.
-- El primer registro stock_initial se genera al crear productos nuevos.
-- Para los productos existentes, se registra un corte de apertura con la
-- cantidad actual, explícitamente identificado como saldo de partida de auditoría.
insert into public.inventory_movements(
  product_id, product_name, movement_type, quantity_before,
  quantity_change, quantity_after, reason, performed_by
)
select p.id, p.name, 'stock_initial', 0, p.stock, p.stock,
       'Saldo de partida de auditoría al activar el módulo; no representa stock histórico original',
       auth.uid()
from public.products p
where not exists (
  select 1 from public.inventory_movements m
  where m.product_id = p.id
);

-- Mantener el estado del crédito sincronizado con abonos y vencimiento.
create or replace function public.set_credit_status()
returns trigger
language plpgsql
set search_path = public
as $
begin
  if new.payment_type <> 'credito' then
    new.credit_status := null;
  elsif new.paid_amount >= new.total then
    new.credit_status := 'pagado';
  elsif new.due_date is not null and new.due_date < current_date then
    new.credit_status := 'vencido';
  elsif new.paid_amount > 0 then
    new.credit_status := 'parcial';
  else
    new.credit_status := 'pendiente';
  end if;
  return new;
end;
$;
drop trigger if exists sales_credit_status_sync on public.sales;
create trigger sales_credit_status_sync
before insert or update of paid_amount, total, payment_type, due_date on public.sales
for each row execute function public.set_credit_status();

-- 5. Versión de RPC compatible con la operación transaccional existente:
-- delega en finalize_sale_v2 y guarda entregado/vuelto en la misma transacción.
create or replace function public.finalize_sale_v3(
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
  p_next_payment_date date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale uuid;
  v_cash_applied numeric(12,2) := 0;
begin
  if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
  if coalesce(p_cash_tendered,0) < 0 or coalesce(p_cash_change,0) < 0 then
    raise exception 'El efectivo entregado y el vuelto no pueden ser negativos';
  end if;

  select coalesce(sum((x->>'amount')::numeric),0)
    into v_cash_applied
  from jsonb_array_elements(coalesce(p_payments,'[]'::jsonb)) x
  where x->>'method' = 'efectivo';

  if p_cash_tendered < v_cash_applied then
    raise exception 'El efectivo entregado no cubre el importe en efectivo';
  end if;
  if round((p_cash_tendered - v_cash_applied)::numeric,2) <> round(coalesce(p_cash_change,0)::numeric,2) then
    raise exception 'El vuelto no coincide con el efectivo entregado';
  end if;

  v_sale := public.finalize_sale_v2(
    p_customer_id, p_customer_name, p_comments, p_sale_type,
    p_payment_type, p_items, p_payments
  );

  update public.sales
  set cash_tendered = p_cash_tendered,
      cash_change = coalesce(p_cash_change,0),
      due_date = case when p_payment_type='credito' then p_due_date else null end,
      next_payment_date = case when p_payment_type='credito' then p_next_payment_date else null end,
      credit_status = case when p_payment_type='credito' then
        case when (select paid_amount from public.sales where id=v_sale) >= (select total from public.sales where id=v_sale) then 'pagado'
             when (select paid_amount from public.sales where id=v_sale) > 0 then 'parcial'
             else 'pendiente' end
        else null end
  where id = v_sale and created_by = auth.uid();

  return v_sale;
end;
$$;

revoke all on function public.finalize_sale_v3(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date) from public, anon;
grant execute on function public.finalize_sale_v3(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date) to authenticated;

commit;

-- Verificación posterior sugerida:
-- SELECT seller_code, role, preferred_theme FROM public.profiles ORDER BY role, full_name;
-- SELECT count(*) FROM public.inventory_movements;
-- SELECT column_name FROM information_schema.columns
-- WHERE table_schema='public' AND table_name='sales'
-- AND column_name IN ('due_date','next_payment_date','credit_status','cash_tendered','cash_change');
-- SELECT has_function_privilege('anon',
--   'public.finalize_sale_v3(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date)','EXECUTE') AS anon_exec,
--   has_function_privilege('authenticated',
--   'public.finalize_sale_v3(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric)','EXECUTE') AS auth_exec;
