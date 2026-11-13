-- Verificación de la actualización integral v2.
-- SOLO LECTURA. Ejecutar únicamente en el proyecto de PRUEBAS después
-- de aplicar supabase/actualizacion_integral_v2.sql.

-- 1. Códigos únicos de vendedores y preferencia visual.
select
  count(*) filter (where role='vendedor') as vendedores,
  count(*) filter (where role='vendedor' and seller_code is null) as vendedores_sin_codigo,
  count(distinct seller_code) filter (where role='vendedor') as codigos_distintos,
  count(*) filter (where preferred_theme not in ('light','dark')) as temas_invalidos
from public.profiles;

-- 2. Columnas nuevas de ventas.
select column_name, data_type
from information_schema.columns
where table_schema='public' and table_name='sales'
  and column_name in (
    'seller_name','seller_code','due_date','next_payment_date',
    'credit_status','cash_tendered','cash_change'
  )
order by column_name;

-- 3. Fotografía de vendedor en ventas históricas.
select
  count(*) as ventas,
  count(*) filter (where seller_name is null) as ventas_sin_nombre_vendedor,
  count(*) filter (where seller_code is null and coalesce(seller_id,created_by) is not null) as ventas_sin_codigo_vendedor
from public.sales;

-- 4. Auditoría de inventario.
select movement_type, count(*) as movimientos
from public.inventory_movements
group by movement_type
order by movement_type;

select
  count(*) as movimientos,
  count(*) filter (where performed_by is null) as movimientos_sin_usuario,
  count(*) filter (where quantity_after < 0) as stocks_resultantes_negativos
from public.inventory_movements;

-- 5. RLS y políticas.
select
  c.relname as tabla,
  c.relrowsecurity as rls_habilitado
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname='inventory_movements';

select policyname, cmd, roles
from pg_policies
where schemaname='public' and tablename='inventory_movements';

-- 6. Triggers nuevos.
select
  event_object_table as tabla,
  trigger_name,
  action_timing,
  event_manipulation
from information_schema.triggers
where trigger_schema='public'
  and trigger_name in (
    'assign_seller_code_on_profile',
    'sales_seller_snapshot',
    'products_stock_audit',
    'sales_credit_status_sync'
  )
order by tabla, trigger_name;

-- 7. RPC y permisos efectivos.
select
  p.oid::regprocedure as funcion,
  has_function_privilege('anon',p.oid,'EXECUTE') as anon_ejecuta,
  has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_ejecuta
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname in (
    'finalize_sale_v3',
    'update_credit_dates',
    'admin_set_product_stock'
  )
order by p.proname;

-- 8. Estado de las cajas: solo lectura; no cerrar ni conciliar.
select status, count(*) as sesiones
from public.cash_sessions
group by status
order by status;
