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


## Segunda revisión: scripts adicionales encontrados en el PR

La comparación completa del PR muestra otros archivos SQL que no forman parte de la secuencia candidata anterior. No se deben ignorar:

- `supabase/actualizacion_integral.sql`
- `supabase/actualizacion_integral_ventas_inventario.sql`
- `supabase/bootstrap_entorno_pruebas.sql`
- `supabase/seguridad_entorno_pruebas.sql`
- `supabase/correccion_codigos_responsables.sql`
- `supabase/verificar_entorno_pruebas.sql`
- `supabase/verificar_actualizacion_integral_v2.sql`

### Bloqueos nuevos identificados

1. **Hay scripts de instalación alternativos.** `actualizacion_integral.sql` y `actualizacion_integral_ventas_inventario.sql` definen versiones propias de `finalize_sale` y modifican columnas de ventas, pagos y productos. No deben ejecutarse junto con otras etapas sin comparar sus firmas y propósito; podrían sobrescribir una RPC o esquema esperado por el código actual.

2. **El bootstrap no es una migración para una base con datos.** `bootstrap_entorno_pruebas.sql` crea el esquema inicial, perfiles, productos, ventas, pagos, cajas y funciones. Es únicamente para crear un proyecto de pruebas vacío. No debe ejecutarse sobre la base actual ni sobre producción.

3. **La seguridad tiene firmas concretas.** `seguridad_entorno_pruebas.sql` revoca y concede EXECUTE sobre firmas específicas de funciones, incluidas versiones antiguas de `finalize_sale`. Si esas firmas no coinciden exactamente con las instaladas, puede fallar o dejar permisos distintos de los esperados. Debe ajustarse al inventario real de funciones y al RPC final que use la aplicación.

4. **La corrección de códigos actualiza datos existentes.** `correccion_codigos_responsables.sql` ejecuta un UPDATE sobre perfiles y crea una función de asignación de códigos. Antes de ejecutarlo, hay que medir cuántos perfiles serían afectados, detectar códigos duplicados y comprobar que no sobrescribe identificadores válidos.

5. **Las consultas de verificación son de solo lectura.** `verificar_entorno_pruebas.sql` y `verificar_actualizacion_integral_v2.sql` deben ejecutarse primero para inspeccionar el entorno, siempre que sus consultas sean compatibles con el esquema presente. La consulta de presentaciones se ejecuta después de instalar esas tablas y funciones.

## Orden de trabajo revisado

No se declara todavía un orden SQL definitivo. El procedimiento seguro es:

A. Identificar si el proyecto ya tiene esquema y datos. Si está vacío, evaluar el bootstrap como instalación inicial aislada. Si ya tiene datos, excluir el bootstrap.

B. Ejecutar primero las consultas de verificación compatibles y obtener inventario de tablas, columnas, funciones, triggers, políticas y versiones de migración.

C. Elegir una sola ruta de migración. No mezclar `actualizacion_integral.sql` ni `actualizacion_integral_ventas_inventario.sql` con las etapas incrementales hasta demostrar que no duplican o reemplazan las mismas RPC.

D. Comparar las firmas reales con las que revoca/concede `seguridad_entorno_pruebas.sql`; ajustar permisos para dejar solo el RPC final compatible con la interfaz.

E. Evaluar `correccion_codigos_responsables.sql` con conteos previos y respaldo de perfiles.

F. Aplicar las etapas incrementales de unidades, inventario, ventas y precisión decimal solo después de confirmar sus precondiciones y que no hayan sido instaladas previamente.

G. Ejecutar las verificaciones de solo lectura y detenerse ante cualquier diferencia.

## Estado actualizado de la auditoría

- Revisión estática de los SQL del PR: ampliada; hay scripts alternativos y de bootstrap que requieren decisión explícita.
- Workflow de validación estática asociado al commit `b8c21af1`: completado con conclusión `success` (run 16, 2026-11-17). Esta validación no comprueba la ejecución ni la compatibilidad de las migraciones SQL.
- Comparación de ramas: 142 commits adelantados, 0 detrás; PR #1 abierto, no fusionado y GitHub informa `mergeable`.
- Proyecto Supabase real: no inspeccionado desde este conector; no se confirma que ningún SQL se haya ejecutado.
- No autorizar despliegue ni fusión por el resultado de validación estática: no prueba integridad de SQL ni comportamiento de base de datos.


## Tercera revisión — 2026-11-17

- Se volvió a consultar el PR #1: permanece abierto, no fusionado y con la rama de trabajo separada de `main`.
- El workflow de validación estática del HEAD `b8c21af1c9aae214e1bcd01e36084521268114fa` terminó correctamente: run 16, conclusión `success`.
- Se detectó una discrepancia entre documentos: `docs/especificacion-actualizacion-integral.md` contiene un registro que afirma que las etapas 1 y 2 fueron ejecutadas y verificadas por el usuario; esta auditoría no tiene evidencia de conexión directa que permita reconfirmarlo. Por seguridad, su estado operativo queda como **pendiente de verificación directa**, no como confirmación de que deban ejecutarse otra vez.
- La revisión estática confirmó que `index.html` llama a `finalize_sale_v5` con la firma documentada y que la migración decimal define esa RPC con cantidades `numeric(18,6)`. También se confirmó que la interfaz usa `admin_configure_product_units` y `admin_record_inventory_movement`, cuyas definiciones están presentes en la cadena de migraciones revisada.
- No hay una herramienta/conexión Supabase disponible en esta sesión. No se consultó el project ref activo, el historial real de migraciones, las políticas instaladas ni los respaldos; tampoco se ejecutó SQL ni se escribieron registros funcionales.
- Próximo paso bloqueante: obtener acceso de solo lectura al proyecto de pruebas `vrgfwefnkrdwrtdymfin` y contrastar esquema, migraciones, RPC, triggers, RLS y grants antes de decidir si se aplica alguna migración. No ejecutar bootstrap ni repetir etapas 1 y 2 sin esa comprobación.
