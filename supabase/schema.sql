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


-- Alta automática del perfil: primera cuenta = administrador; siguientes = vendedores.
create or replace function public.handle_new_user_profile()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,full_name,role)
 values(new.id,coalesce(new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1)),
   case when not exists(select 1 from public.profiles) then 'admin' else 'vendedor' end)
 on conflict(id) do nothing;
 return new;
end $$;
drop trigger if exists create_profile_after_signup on auth.users;
create trigger create_profile_after_signup after insert on auth.users
for each row execute procedure public.handle_new_user_profile();

-- Registro seguro de abonos: valida el saldo y actualiza el crédito en una sola operación.
create or replace function public.register_payment(p_sale_id uuid,p_amount numeric,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare s public.sales%rowtype; payment_id uuid;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'El monto debe ser mayor que cero'; end if;
 select * into s from public.sales where id=p_sale_id for update;
 if not found then raise exception 'Venta no encontrada'; end if;
 if s.created_by<>auth.uid() and not public.is_admin() then raise exception 'No tienes permiso para registrar este abono'; end if;
 if s.payment_type<>'credito' then raise exception 'La venta no es al crédito'; end if;
 if p_amount>s.total-s.paid_amount then raise exception 'El abono supera el saldo pendiente'; end if;
 insert into public.payments(sale_id,amount,note,received_by) values(p_sale_id,p_amount,p_note,auth.uid()) returning id into payment_id;
 update public.sales set paid_amount=paid_amount+p_amount where id=p_sale_id;
 return jsonb_build_object('success',true,'payment_id',payment_id,'new_balance',s.total-s.paid_amount-p_amount);
end $$;
grant execute on function public.register_payment(uuid,numeric,text) to authenticated;
