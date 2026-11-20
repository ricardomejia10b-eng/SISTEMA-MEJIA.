-- SISTEMA MEJÍA — verificación de unidades, presentaciones, ventas y precisión decimal
-- SOLO LECTURA. Ejecutar únicamente en Supabase de PRUEBAS después de aplicar
-- la secuencia completa de migraciones documentada. No registra ventas ni cambia stock.

-- 1. Tipos de datos y precisión efectiva.
select table_name, column_name, data_type, numeric_precision, numeric_scale
from information_schema.columns
where table_schema='public'
  and (
    (table_name='products' and column_name='stock')
    or (table_name='sale_items' and column_name in (
      'quantity','unit_price','unit_id','unit_name_snapshot','base_unit_snapshot',
      'quantity_in_unit','quantity_in_base','conversion_factor_snapshot'
    ))
    or (table_name='inventory_movements' and column_name in (
      'quantity_before','quantity_change','quantity_after','unit_name',
      'quantity_in_unit','quantity_change_base','conversion_factor','stock_after_base'
    ))
  )
order by table_name, column_name;

-- 2. Productos con presentaciones y su unidad base.
select
  p.id, p.name, p.stock, p.base_unit, p.unit_configured,
  count(u.id) filter (where u.is_active) as presentaciones_activas,
  count(u.id) filter (where u.is_active and u.is_base) as unidades_base_activas
from public.products p
left join public.product_units u on u.product_id=p.id
group by p.id,p.name,p.stock,p.base_unit,p.unit_configured
order by p.name;

-- 3. Configuraciones que requieren revisión: cero o más de una unidad base activa.
select p.id,p.name,p.base_unit,
       count(u.id) filter (where u.is_active and u.is_base) as unidades_base_activas
from public.products p
left join public.product_units u on u.product_id=p.id
where p.unit_configured
group by p.id,p.name,p.base_unit
having count(u.id) filter (where u.is_active and u.is_base) <> 1;

-- 4. Valores negativos y cantidades fuera de la precisión de seis decimales.
select
  (select count(*) from public.products where stock < 0) as productos_stock_negativo,
  (select count(*) from public.sale_items where quantity <= 0) as lineas_venta_no_positivas,
  (select count(*) from public.inventory_movements where quantity_after < 0) as movimientos_stock_negativo;

-- 5. Cobertura de snapshots de ventas. Las líneas antiguas pueden tener campos nuevos NULL.
select
  count(*) as lineas_venta,
  count(*) filter (where unit_name_snapshot is not null) as lineas_con_presentacion,
  count(*) filter (where quantity_in_unit is not null and conversion_factor_snapshot is not null) as lineas_con_equivalencia,
  count(*) filter (where base_unit_snapshot is not null and quantity_in_base is not null) as lineas_con_unidad_base_snapshot
from public.sale_items;

-- 6. Movimientos de inventario con detalle de presentación.
select
  movement_type,
  count(*) as movimientos,
  count(*) filter (where unit_name is not null) as con_presentacion,
  count(*) filter (where quantity_in_unit is not null and conversion_factor is not null) as con_factor,
  count(*) filter (where quantity_change_base is not null) as con_variacion_base
from public.inventory_movements
group by movement_type
order by movement_type;

-- 7. Trigger de auditoría y RLS.
select event_object_table, trigger_name, action_timing, event_manipulation
from information_schema.triggers
where trigger_schema='public' and trigger_name='products_stock_audit';

select c.relname as tabla, c.relrowsecurity as rls_habilitado
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('product_units','inventory_movements')
order by c.relname;

-- 8. RPC actual y permisos; las RPC heredadas deben quedar deshabilitadas.
select
  'finalize_sale_v5' as rpc,
  to_regprocedure('public.finalize_sale_v5(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)') is not null as existe,
  coalesce(has_function_privilege('authenticated',
    to_regprocedure('public.finalize_sale_v5(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)'),
    'EXECUTE'),false) as authenticated_ejecuta
union all
select
  'admin_record_inventory_movement',
  to_regprocedure('public.admin_record_inventory_movement(uuid,uuid,numeric,text,text)') is not null,
  coalesce(has_function_privilege('authenticated',
    to_regprocedure('public.admin_record_inventory_movement(uuid,uuid,numeric,text,text)'),
    'EXECUTE'),false)
union all
select
  'finalize_sale_v4_legacy',
  to_regprocedure('public.finalize_sale_v4(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)') is not null,
  coalesce(has_function_privilege('authenticated',
    to_regprocedure('public.finalize_sale_v4(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)'),
    'EXECUTE'),false);

-- 9. Sesiones de caja: solo lectura.
select status,count(*) as sesiones
from public.cash_sessions
group by status
order by status;

-- Esta verificación no certifica por sí sola el flujo funcional. Después de
-- revisarla, ejecutar pruebas controladas con productos de prueba y caja de prueba.
