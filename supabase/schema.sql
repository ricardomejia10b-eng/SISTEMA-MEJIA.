-- SISTEMA MEJIA: esquema inicial para Supabase
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text,
 role text not null default 'vendedor' check (role in ('admin','vendedor')),
 created_at timestamptz not null default now()
);
create table if not exists public.products (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 code text unique,
 price numeric(12,2) not null default 0 check(price>=0),
 stock integer not null default 0 check(stock>=0),
 image_url text,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.customers (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 phone text,
 address text,
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.sales (
 id uuid primary key default gen_random_uuid(),
 customer_id uuid references public.customers(id) on delete set null,
 payment_type text not null check(payment_type in ('contado','credito')),
 total numeric(12,2) not null check(total>=0),
 paid_amount numeric(12,2) not null default 0 check(paid_amount>=0),
 created_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create table if not exists public.sale_items (
 id uuid primary key default gen_random_uuid(),
 sale_id uuid not null references public.sales(id) on delete cascade,
 product_id uuid references public.products(id) on delete set null,
 product_name text not null,
 quantity integer not null check(quantity>0),
 unit_price numeric(12,2) not null check(unit_price>=0),
 line_total numeric(12,2) not null check(line_total>=0)
);
create table if not exists public.payments (
 id uuid primary key default gen_random_uuid(),
 sale_id uuid not null references public.sales(id) on delete cascade,
 amount numeric(12,2) not null check(amount>0),
 note text,
 received_by uuid references auth.users(id),
 created_at timestamptz not null default now()
);
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles where id=auth.uid() and role='admin');
$$;
alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.payments enable row level security;
create policy "profiles read self or admin" on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
create policy "profile update self or admin" on public.profiles for update to authenticated using(id=auth.uid() or public.is_admin()) with check(id=auth.uid() or public.is_admin());
create policy "profiles insert self" on public.profiles for insert to authenticated with check(id=auth.uid());
create policy "products read auth" on public.products for select to authenticated using(true);
create policy "products insert auth" on public.products for insert to authenticated with check(true);
create policy "products update auth" on public.products for update to authenticated using(true) with check(true);
create policy "products delete admin" on public.products for delete to authenticated using(public.is_admin());
create policy "customers read auth" on public.customers for select to authenticated using(true);
create policy "customers insert auth" on public.customers for insert to authenticated with check(true);
create policy "customers update auth" on public.customers for update to authenticated using(true) with check(true);
create policy "sales read own or admin" on public.sales for select to authenticated using(created_by=auth.uid() or public.is_admin());
create policy "sales insert auth" on public.sales for insert to authenticated with check(created_by=auth.uid());
create policy "sales update own or admin" on public.sales for update to authenticated using(created_by=auth.uid() or public.is_admin()) with check(created_by=auth.uid() or public.is_admin());
create policy "items read sale access" on public.sale_items for select to authenticated using(exists(select 1 from public.sales s where s.id=sale_id and (s.created_by=auth.uid() or public.is_admin())));
create policy "items insert sale access" on public.sale_items for insert to authenticated with check(exists(select 1 from public.sales s where s.id=sale_id and (s.created_by=auth.uid() or public.is_admin())));
create policy "payments read sale access" on public.payments for select to authenticated using(exists(select 1 from public.sales s where s.id=sale_id and (s.created_by=auth.uid() or public.is_admin())));
create policy "payments insert sale access" on public.payments for insert to authenticated with check(received_by=auth.uid() and exists(select 1 from public.sales s where s.id=sale_id and (s.created_by=auth.uid() or public.is_admin())));
insert into storage.buckets(id,name,public) values('product-images','product-images',true) on conflict(id) do nothing;
create policy "product images view" on storage.objects for select to authenticated using(bucket_id='product-images');
create policy "product images upload own folder" on storage.objects for insert to authenticated with check(bucket_id='product-images' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "product images update own folder" on storage.objects for update to authenticated using(bucket_id='product-images' and (storage.foldername(name))[1]=auth.uid()::text) with check(bucket_id='product-images' and (storage.foldername(name))[1]=auth.uid()::text);
-- Tras crear el primer usuario desde Authentication, convertirlo en administrador ejecutando:
-- update public.profiles set role='admin', full_name='Administrador' where id='UUID_DEL_USUARIO';
-- Crear el perfil de usuario (reemplazar UUID):
-- insert into public.profiles(id,full_name,role) values('UUID_DEL_USUARIO','Administrador','admin');
