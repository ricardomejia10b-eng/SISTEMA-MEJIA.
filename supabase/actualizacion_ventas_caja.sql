-- SISTEMA MEJIA: ampliacion de ventas y caja (migracion aditiva)
-- Ejecutar una sola vez en Supabase SQL Editor. No elimina datos existentes.
alter table public.sales
  add column if not exists sale_kind text not null default 'menor'
    check (sale_kind in ('mayor','menor')),
  add column if not exists customer_name text,
  add column if not exists payment_method text
    check (payment_method in ('efectivo','kr')),
  add column if not exists cash_register_id uuid;

create table if not exists public.cash_registers (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id),
  opened_at timestamptz not null default now(),
  opening_amount numeric(12,2) not null default 0 check (opening_amount >= 0),
  opening_cash numeric(12,2) not null default 0 check (opening_cash >= 0),
  opening_kr numeric(12,2) not null default 0 check (opening_kr >= 0),
  closed_at timestamptz,
  closing_cash numeric(12,2),
  closing_kr numeric(12,2),
  closing_total numeric(12,2),
  notes text,
  created_at timestamptz not null default now(),
  check ((closing_cash is null and closing_kr is null and closed_at is null)
      or (closing_cash is not null and closing_kr is not null and closed_at is not null))
);

create unique index if not exists cash_registers_one_open_per_seller
  on public.cash_registers(seller_id) where closed_at is null;

alter table public.sales
  drop constraint if exists sales_cash_register_id_fkey;
alter table public.sales
  add constraint sales_cash_register_id_fkey
  foreign key (cash_register_id) references public.cash_registers(id) on delete set null;

alter table public.cash_registers enable row level security;
drop policy if exists "cash register read own or admin" on public.cash_registers;
create policy "cash register read own or admin" on public.cash_registers
  for select to authenticated using (seller_id = auth.uid() or public.is_admin());
drop policy if exists "cash register insert own" on public.cash_registers;
create policy "cash register insert own" on public.cash_registers
  for insert to authenticated with check (seller_id = auth.uid());
drop policy if exists "cash register close own or admin" on public.cash_registers;
create policy "cash register close own or admin" on public.cash_registers
  for update to authenticated using (seller_id = auth.uid() or public.is_admin())
  with check (seller_id = auth.uid() or public.is_admin());

-- Permite a los vendedores consultar sus propias ventas y al administrador todas.
