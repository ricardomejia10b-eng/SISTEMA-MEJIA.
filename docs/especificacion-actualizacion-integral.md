# SISTEMA MEJIA — especificación consolidada de actualización

La actualización se implementará sobre la rama de trabajo y sobre la estructura real de Supabase. No se deben borrar registros, perfiles ni usuarios. No publicar en producción hasta completar las pruebas.

## Decisiones de compatibilidad confirmadas

- El control de caja canónico será `cash_sessions`: las funciones actuales de ventas, pagos y movimientos ya dependen de esa tabla.
- `cash_registers` queda en compatibilidad temporal; no se debe abrir ni cerrar una caja nueva desde la interfaz ni eliminar la tabla durante esta fase.
- Las ventas deben finalizar mediante una única operación transaccional en Supabase. La interfaz no debe insertar venta, detalle y descuento de inventario en solicitudes separadas.
- Los métodos de cobro de la aplicación se expresarán como efectivo, Yape, mixto y crédito. Antes de cambiar las restricciones SQL existentes hay que comprobar los valores admitidos por cada tabla.
- Las políticas RLS existentes se conservan como base: administrador gestiona productos; vendedores consultan catálogo y operan sus ventas, créditos y caja; administrador supervisa globalmente. No se relajan políticas para hacer funcionar la interfaz.

## Productos
- Búsqueda por nombre, código y código de barras.
- Listado: foto, producto, código, precio mayorista, precio minorista, stock y acción de escáner.
- Alta y edición: nombre, código, precios mayorista/minorista, stock y foto desde cámara o archivo.
- Las imágenes se guardan en Supabase Storage y se sincronizan entre dispositivos. Mostrar imagen predeterminada cuando no exista foto.

## Ventas y caja
- Apertura y cierre usando exclusivamente `cash_sessions`.
- No permitir ventas sin sesión abierta.
- Apertura registra fecha/hora y efectivo inicial.
- Cierre resume movimientos registrados y separa efectivo, Yape y crédito. Debe mostrar esperado, contado y diferencia; no declarar conciliado si no coincide. Cualquier ajuste requiere autorización y registro.
- Historial filtrable por fecha.
- Carrito multi-producto, código único por compra, selector mayorista/minorista, cantidades +/-, eliminación de líneas y cálculo automático.
- Pago efectivo, Yape, mixto o crédito. En crédito se permite adelanto y saldo pendiente.
- Comentarios opcionales y nombre libre del cliente para compras grandes.
- El inventario se descuenta exactamente una vez al confirmar la venta; nunca al editar el carrito. Bloquear stock insuficiente.
- La confirmación de venta, detalle, pagos, movimientos de caja y descuento de stock deben ser atómicos.

## Clientes
- Nombre, teléfono y dirección; crear, editar y buscar.
- Historial por cliente: compras, productos, fechas, cantidades, créditos/deudas y abonos.
- Estado de cuenta con total, abonado y saldo.

## Créditos
- Historial con fecha, cliente, código de venta, total, abonado y saldo.
- Registrar abonos con validación de saldo; actualizar automáticamente el saldo.
- Un abono no vuelve a descontar inventario.

## Usuarios
- Sección solo para administrador.
- Listado de nombre, correo, rol y estado.
- Nunca mostrar contraseñas. Los cambios de acceso deben usar los flujos seguros de Supabase Authentication.

## Reglas de entrega
1. Migraciones aditivas, revisadas contra el esquema real; no ejecutar los SQL antiguos incompatibles.
2. Mantener intacta la rama `main` durante el desarrollo.
3. Probar apertura/cierre, ventas contado/crédito/mixtas, concurrencia de stock, abonos, RLS e imágenes.
4. Solo después de aprobación explícita, integrar a producción y desplegar.


## Etapa 2 preparada: datos de venta y resumen de caja

Se añadió `supabase/actualizacion_integral_etapa2.sql` como migración complementaria, pendiente de revisión y ejecución autorizada.

- Crea `finalize_sale_v2`, sin reemplazar `finalize_sale`. Conserva la transacción de venta, detalle, pagos, movimientos y descuento de stock; además guarda nombre libre, comentarios y código único.
- Crea `get_cash_session_summary` para separar el efectivo y QR realmente recibidos del total vendido a crédito y del saldo pendiente.
- La función de cierre actual `close_cash_session` se conserva. Su conciliación de efectivo/QR no debe sumar el saldo pendiente de crédito como si fuera dinero en caja.
- La interfaz no debe cambiar a estas funciones hasta que la migración sea revisada y ejecutada correctamente en Supabase.

Orden previsto: revisar etapa 1 y etapa 2; ejecutar ambas solo con aprobación; adaptar la interfaz para las nuevas funciones; probar con datos de prueba; recién después evaluar publicación.
