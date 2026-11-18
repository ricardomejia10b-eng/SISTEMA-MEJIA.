# SISTEMA MEJÍA — orden de migraciones y bloqueos para pruebas

**Estado:** revisión estática de los archivos de la rama `actualizacion-integral-sistema-mejia`.  
**No ejecutar todavía:** no se ha confirmado por conexión directa el esquema real ni el historial de migraciones del proyecto Supabase.  
**Proyecto de pruebas esperado:** `vrgfwefnkrdwrtdymfin`.  
**Producción prohibida:** `aqjhsrwzdnugwcgeqohg`.

## 1. Regla antes de ejecutar

1. Confirmar el project ref activo en Supabase y detenerse si no coincide exactamente con el proyecto de pruebas.
2. Consultar en solo lectura las tablas, columnas, tipos, funciones, triggers, políticas RLS y migraciones ya aplicadas.
3. Comparar el resultado con las dependencias descritas abajo. No volver a ejecutar una migración ya aplicada solo porque sea idempotente en parte: varias incluyen reemplazo de funciones, cambios de permisos o backfills.
4. Tomar/confirmar un respaldo recuperable del proyecto de pruebas.
5. Aplicar un archivo por vez, comprobar el resultado y detenerse ante el primer error.
6. No registrar ventas, abonos, ajustes de stock ni cerrar cajas durante esta etapa. Esas pruebas de escritura necesitan una autorización separada.

## 2. Orden candidato (sujeto a la inspección real)

| Orden | Archivo | Motivo / dependencia |
|---:|---|---|
| 1 | `supabase/actualizacion_integral_etapa1.sql` | Añade campos e índices de ventas utilizados por las siguientes etapas. |
| 2 | `supabase/actualizacion_integral_etapa2.sql` | Crea `finalize_sale_v2` y `get_cash_session_summary`; la interfaz consulta el resumen de caja. |
| 3 | `supabase/actualizacion_integral_v2.sql` | Añade códigos de responsables, snapshots de vendedor, auditoría inicial, fechas de crédito y `finalize_sale_v3`. |
| 4 | `supabase/seguridad_entorno_pruebas.sql` | Endurecimiento del esquema base; solo después de comprobar que todas las funciones que exige existen. Debe revisarse el efecto de sus permisos antes de aplicarla. |
| 5 | `supabase/ventas_responsable_caja_v4.sql` | Asignación de ventas a responsables, abonos y políticas de acceso de ventas/detalles/pagos/movimientos. |
| 6 | `supabase/unidades_medida_presentaciones_v1.sql` | Crea presentaciones y snapshots de unidad; requiere productos, ventas y movimientos existentes. |
| 7 | `supabase/inventario_presentaciones_v2.sql` | Auditoría y RPC de ingresos/ajustes por presentación; depende de unidades y movimientos. |
| 8 | `supabase/ventas_presentaciones_v5.sql` | Primera versión de venta por presentación; es requisito declarado por la migración decimal. |
| 9 | `supabase/inventario_precision_decimal_v1.sql` | Convierte cantidades a `numeric(18,6)`, reemplaza la RPC v5 por su versión decimal y revoca RPC antiguas. Debe ser la última migración funcional de esta cadena. |
| 10 | `supabase/verificar_presentaciones_y_ventas_v1.sql` | Consultas de solo lectura posteriores a la instalación. |

**Importante:** este orden es un candidato derivado de los comentarios y referencias entre archivos, no una autorización para ejecutarlo. En particular, confirmar si etapa 1/2 ya están instaladas o si sus objetos los creó el bootstrap.

## 3. Archivos que NO se deben ejecutar junto con esa cadena

- `supabase/actualizacion_integral.sql`: implementación anterior alternativa de `finalize_sale`; no mezclar con la cadena v2/v4/v5.
- `supabase/actualizacion_integral_ventas_inventario.sql`: implementación anterior alternativa que también reemplaza RPC de ventas y abonos; no mezclar con la cadena actual.
- `supabase/correccion_codigos_responsables.sql`: parche anterior de códigos, hoy la lógica está incorporada en `actualizacion_integral_v2.sql`; solo usar si la inspección demuestra que el esquema quedó en un estado parcial que requiere ese parche.
- `supabase/bootstrap_entorno_pruebas.sql`: únicamente para crear un entorno de pruebas completamente vacío. El propio script aborta si detecta tablas de negocio; nunca ejecutarlo sobre una base ya inicializada.
- `supabase/verificar_actualizacion_integral_v2.sql` y `supabase/verificar_entorno_pruebas.sql`: solo lectura, pero deben ejecutarse únicamente cuando existan los objetos que consultan.

## 4. Hallazgos que requieren comprobación en la base

- La migración decimal reemplaza `finalize_sale_v5` y `admin_record_inventory_movement`; no ejecutar una versión anterior después de ella.
- `ventas_responsable_caja_v4.sql` crea políticas de lectura para ventas, detalles, pagos y movimientos. Hay que revisar políticas preexistentes porque PostgreSQL combina políticas permisivas con OR; una política antigua demasiado amplia podría seguir exponiendo datos.
- `seguridad_entorno_pruebas.sql` concede ejecución a algunas funciones antiguas. La migración decimal revoca varias RPC antiguas al final, pero la comprobación de privilegios efectiva debe hacerse después de toda la cadena.
- La tabla `inventory_movements` se crea inicialmente con cantidades enteras en `actualizacion_integral_v2.sql`; la migración decimal convierte sus columnas principales a `numeric(18,6)`. Confirmar tipos finales y triggers.
- La instalación debe conservar los snapshots históricos de unidad, nombre, código y vendedor. No completar fechas antiguas de crédito con valores inventados.
- La aplicación y el SQL deben compartir exactamente la firma de `finalize_sale_v5`:
  `(uuid,text,text,text,text,jsonb,jsonb,numeric,numeric,date,date,uuid)`.

## 5. Verificación posterior (solo lectura)

Después de aplicar la cadena, ejecutar `supabase/verificar_presentaciones_y_ventas_v1.sql` y revisar:

- Tipos decimales y escala de stock, cantidades, precios y movimientos.
- Presentaciones y unidad base por producto.
- Snapshots de presentación y equivalencias en detalles de venta.
- Triggers de auditoría de stock.
- RLS habilitado y políticas de tablas sensibles.
- Firma y privilegios de `finalize_sale_v5` y `admin_record_inventory_movement`.
- Que las RPC antiguas no tengan EXECUTE para `anon` ni `authenticated`.
- Que los históricos sigan presentes y sin cambios de cantidades/importes.

La verificación SQL no sustituye las pruebas de acceso con una sesión real de administrador y otra de vendedor.

## 6. Bloqueo actual

No hay un conector Supabase disponible en esta sesión. Por ello no se ha consultado el project ref activo, el esquema real, el historial de migraciones ni los respaldos. **No se ha ejecutado ningún SQL.** La rama de GitHub sí puede seguir preparándose, pero la instalación y el visto bueno final quedan bloqueados hasta completar esas comprobaciones.
