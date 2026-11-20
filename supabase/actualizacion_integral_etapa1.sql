-- SISTEMA MEJIA — etapa 1 de actualización integral
-- Migración ADITIVA y conservadora. No borra ni trunca datos.
-- No cambia políticas RLS ni reemplaza funciones existentes.
-- Revisar el resultado antes de ejecutar en Supabase.

begin;

-- Campos necesarios para la futura interfaz. Se agregan sin NOT NULL
-- para no bloquear la aplicación que aún está desplegada.
alter table public.sales
  add column if not exists sale_code text,
  add column if not exists comments text,
  add column if not exists cash_amount numeric(12,2) not null default 0,
  add column if not exists yape_amount numeric(12,2) not null default 0;

-- Asignar códigos de referencia a ventas antiguas sin modificar importes.
update public.sales
set sale_code = 'LEG-' || upper(substr(replace(id::text, '-', ''), 1, 12))
where sale_code is null;

-- Índice parcial: la versión desplegada puede seguir creando ventas
-- mientras la interfaz nueva todavía no envía sale_code.
create unique index if not exists sales_sale_code_uidx
  on public.sales (sale_code)
  where sale_code is not null;

create index if not exists sales_created_at_idx
  on public.sales (created_at desc);

create index if not exists sale_items_sale_id_idx
  on public.sale_items (sale_id);

create index if not exists payments_sale_id_idx
  on public.payments (sale_id);

commit;

-- IMPORTANTE:
-- Esta etapa NO modifica finalize_sale, register_payment, open_cash_session
-- ni close_cash_session. La integración transaccional de esos procesos
-- requiere conservar exactamente sus firmas y validar los valores de
-- payment_method y movement_type vigentes en la base antes de reemplazarlos.
-- No ejecutar todavía una segunda etapa de funciones/caja sin esa validación.
