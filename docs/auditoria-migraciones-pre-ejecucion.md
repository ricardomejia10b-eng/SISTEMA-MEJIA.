# Auditoría previa de migraciones — SISTEMA MEJÍA

Fecha de revisión: 2026-11-17  
Rama revisada: `actualizacion-integral-sistema-mejia`  
Proyecto objetivo declarado: Supabase de PRUEBAS `vrgfwefnkrdwrtdymfin`

## Resultado

**No ejecutar todavía las migraciones.** Se revisaron los archivos SQL de la rama y se detectaron dependencias importantes. Esta auditoría es estática: no sustituye la comprobación del esquema real de Supabase.

## Secuencia candidata para validar contra la base real

1. `supabase/actualizacion_integral_etapa1.sql`
2. `supabase/actualizacion_integral_etapa2.sql`
3. `supabase/actualizacion_integral_v2.sql`
4. `supabase/ventas_responsable_caja_v4.sql`
5. `supabase/unidades_medida_presentaciones_v1.sql`
6. `supabase/inventario_presentaciones_v2.sql`
7. `supabase/ventas_presentaciones_v5.sql`
8. `supabase/inventario_precision_decimal_v1.sql`

La secuencia es provisional. Antes de aplicarla hay que confirmar que las tablas, columnas, triggers, funciones y tipos previos existen en el proyecto de pruebas y que no hay migraciones equivalentes ya aplicadas.

## Hallazgos que condicionan la ejecución

### 1. Etapa 1 debe preceder a etapa 2

`actualizacion_integral_etapa1.sql` agrega columnas a `sales` que la función `finalize_sale_v2` de etapa 2 utiliza. La propia etapa 2 declara que depende de la etapa 1.

### 2. Etapa 2 crea dos funciones con propósitos distintos

- `finalize_sale_v2` registra ventas con cantidades enteras y no debe quedar como RPC activa para la interfaz actual.
- `get_cash_session_summary` es consumida por la interfaz para mostrar los resúmenes de caja.

La migración decimal posterior revoca la ejecución de `finalize_sale_v2`, pero no elimina `get_cash_session_summary`. Debe comprobarse la firma y permisos de esta última en la base después de migrar.

### 3. La migración de responsables/caja es dependencia de ventas v5

`ventas_responsable_caja_v4.sql` crea `finalize_sale_v4`, actualiza `register_payment` y define políticas de lectura para ventas, detalles, pagos y movimientos de caja. Tanto `ventas_presentaciones_v5.sql` como la migración decimal declaran esta etapa como dependencia.

### 4. El archivo de ventas v5 por sí solo no es la versión decimal final

`ventas_presentaciones_v5.sql` declara cantidades enteras en parte de su implementación. La migración `inventario_precision_decimal_v1.sql` vuelve a definir `finalize_sale_v5` con cantidades `numeric(18,6)` y convierte las columnas correspondientes a tipos decimales.

Por tanto, no se debe detener la actualización después de ejecutar solo `ventas_presentaciones_v5.sql`. La definición final que debe quedar instalada es la de `inventario_precision_decimal_v1.sql`.

### 5. Inventario por presentaciones tiene dos fases

`inventario_presentaciones_v2.sql` trabaja mientras `products.stock` sigue siendo entero y rechaza conversiones fraccionarias a unidad base. La migración decimal posterior cambia el stock y los movimientos a `numeric(18,6)` y reemplaza la función de movimientos para admitir fracciones.

La prueba definitiva de kilogramos, litros y cantidades fraccionarias solo corresponde después de la fase decimal.

### 6. Riesgo de revocación de funciones antiguas

La migración decimal revoca funciones RPC anteriores si existen. Antes de ejecutarla hay que inventariar las firmas actualmente instaladas y comprobar que la interfaz desplegada en la vista previa llama a `finalize_sale_v5`. La revocación puede afectar a clientes o versiones antiguas si se usa una interfaz distinta.

### 7. Seguridad y datos históricos

Los archivos contienen actualizaciones de códigos, snapshots de responsables, políticas RLS y triggers de auditoría. Aunque se describen como aditivos, deben comprobarse en la base real: especialmente políticas RLS preexistentes, triggers duplicados, permisos de funciones `SECURITY DEFINER` y restricciones de las tablas existentes.

## Comprobaciones obligatorias antes de ejecutar

- Confirmar el identificador del proyecto conectado y que sea exactamente el entorno de pruebas.
- Revisar las migraciones ya aplicadas y el esquema actual.
- Confirmar que existen las tablas y columnas referenciadas por cada script.
- Obtener las definiciones actuales de funciones y triggers que serán reemplazados.
- Revisar políticas RLS actuales antes de reemplazarlas.
- Confirmar backup/restauración disponible para el proyecto de pruebas.
- Aplicar una migración por vez y verificar el resultado después de cada una.
- Detenerse ante cualquier error; no continuar con la siguiente migración automáticamente.

## Estado

- Auditoría estática de archivos: realizada parcialmente.
- Compatibilidad con el esquema real de Supabase: pendiente.
- Migraciones ejecutadas: ninguna confirmada.
- Ventas, stock, créditos y cajas modificados por esta auditoría: ninguno.
- PR fusionado / producción: no autorizado.
