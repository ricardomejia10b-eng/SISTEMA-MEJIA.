# Plan de pruebas — unidades, presentaciones y cantidades decimales

Este plan se ejecuta únicamente después de aplicar y verificar la secuencia de migraciones en el proyecto Supabase de PRUEBAS. Usar productos de prueba identificados expresamente; no modificar stock, ventas, créditos ni cajas históricas.

## Preparación controlada

1. Confirmar visualmente que el proyecto Supabase seleccionado es el proyecto de pruebas, no producción.
2. Crear o seleccionar productos exclusivos de prueba, con precios conocidos y sin ventas históricas relevantes.
3. Abrir una caja de prueba para el vendedor que corresponda. No cerrar ni conciliar cajas preexistentes.
4. Anotar stock inicial, equivalencias, precio base y responsable de la prueba.

## Casos funcionales

| Caso | Preparación / acción | Resultado esperado |
|---|---|---|
| Unidad base | Producto configurado con unidad=1, stock 30; vender 3 unidades | Descuenta 3; registra cantidad 3, factor 1 y saldo 27 |
| Paquete | unidad=1, paquete=12, stock 36; vender 2 paquetes | Descuenta 24 unidades base; quedan 12; detalle conserva 2 paquetes y factor 12 |
| Presentaciones mixtas | Mismo producto, agregar 1 paquete y 3 unidades en líneas distintas | Descuenta 15 unidades base; el comprobante conserva ambas presentaciones |
| Caja / presentación mayor | unidad=1, paquete=12, caja=144; vender 1 caja | Descuenta 144 unidades base; saldo y auditoría coherentes |
| Peso fraccionario | Base kg=1, g=0.001; stock 2.500000 kg; vender 0.750000 kg | Descuenta 0.750000 kg; quedan 1.750000 kg |
| Volumen fraccionario | Base litro=1, ml=0.001; ingreso de 250 ml | Aumenta 0.250000 litros; movimiento guarda 250 ml y factor 0.001 |
| Ajuste negativo | Stock 1.750000 kg; ajustar −250 g | Descuenta 0.250000 kg y deja 1.500000 kg |
| Stock insuficiente | Intentar vender una cantidad mayor al saldo disponible | RPC rechaza la operación completa; no crea venta, pagos ni movimientos parciales |
| Precisión excedida | Enviar cantidad o equivalencia con más de seis decimales | Configuración/RPC rechaza la operación; no redondea silenciosamente |
| Configuración inválida | Presentación sin factor, factor cero/negativo o dos unidades base | Rechaza guardar la configuración |
| Presentación inactiva | Desactivar una presentación y tratar de venderla | RPC rechaza la venta; las ventas antiguas conservan su snapshot |
| Historial | Consultar movimientos antes y después de los casos anteriores | Fecha, responsable, motivo, presentación, equivalencia, variación base y saldo coinciden |
| Precio | Vender una presentación con factor conocido | Precio por presentación = precio de unidad base × factor; subtotal y total coinciden |
| Caja y crédito | Hacer una venta de prueba contado y otra crédito con adelanto | Pagos, caja, efectivo/Yape, saldo y fechas se conservan igual que el flujo anterior |
| Permisos | Consultar como vendedor y como administrador | Vendedor solo ve su información; administrador puede consultar el detalle global permitido |
| Compatibilidad histórica | Consultar ventas y movimientos anteriores a la migración | Los valores históricos permanecen iguales; campos nuevos pueden quedar NULL y se muestran con fallback |

## Verificación posterior

- Ejecutar `supabase/verificar_presentaciones_y_ventas_v1.sql` (solo lectura).
- Comparar stock inicial/final de cada producto de prueba con las cantidades base calculadas.
- Verificar que cada venta nueva tiene su detalle de presentación y su movimiento de salida vinculado por `sale_id`.
- Verificar que una operación rechazada no dejó registros parciales.
- Repetir la prueba con dos solicitudes concurrentes para confirmar que los bloqueos de producto evitan sobreventa.
- Documentar capturas/resultados y cualquier error antes de considerar lista la actualización.

## Condiciones de cierre

No fusionar el PR, desplegar a producción ni ejecutar migraciones en producción. No borrar productos de prueba ni registros hasta que el usuario revise los resultados. No cerrar ni conciliar cajas preexistentes.


## Verificación adicional: coherencia de cantidades y precios por presentación

- Registrar una venta de 1 paquete cuando el paquete contiene 12 unidades base.
- Confirmar que `sale_items.quantity` y `quantity_in_unit` indiquen 1 paquete, y que `unit_price` sea el precio por paquete.
- Confirmar que `line_total = quantity × unit_price`.
- Confirmar que `quantity_in_base` registre 12 y que el inventario disminuya exactamente 12 unidades base.
- Repetir con cantidades fraccionarias permitidas, por ejemplo 0.5 kg, y verificar que el total, la cantidad vendida y el stock coincidan con seis decimales.
- Confirmar que los comprobantes muestren la cantidad y el precio de la presentación vendida, además de su equivalente en unidad base.
- No realizar estas pruebas en producción ni usar datos reales; requieren autorización para operaciones que escriban ventas o stock.


## Verificación de responsables, códigos y permisos RLS

- Confirmar que cada perfil con rol `vendedor` tenga código `VEN-...` y cada perfil `admin` que pueda registrar ventas tenga código `ADM-...`.
- Confirmar unicidad de `profiles.seller_code` y que los códigos no puedan modificarse después de asignados.
- Con sesión de vendedor, consultar ventas propias y comprobar que las ventas de otros responsables no aparezcan.
- Con sesión de vendedor, consultar `sale_items` y `payments` de ventas propias y comprobar que no pueda leer detalles o abonos de otros responsables.
- Verificar que ventas históricas sin `seller_id` sigan siendo visibles para su creador mediante `created_by`, sin exponerlas a otros vendedores.
- Verificar que solo el administrador pueda consultar ventas y cajas de todos los responsables.
- Confirmar que los abonos solo puedan registrarse para créditos del responsable o por el administrador, y que el método efectivo/QR quede reflejado en el movimiento de caja.
- Ejecutar las pruebas con cuentas separadas de administrador y vendedor, sin cerrar cajas existentes ni alterar ventas reales.


## Comprobantes y estados de cuenta: PDF e intercambio por WhatsApp

- Desde el historial de ventas, abrir el comprobante de una venta individual y confirmar que solo incluya los datos de esa venta.
- Verificar código, fecha, cliente, vendedor/código, productos, presentación, cantidad, precio unitario, subtotal, total, abonado, saldo, efectivo, Yape, efectivo entregado y vuelto.
- Usar «Imprimir / Guardar como PDF» y comprobar que el documento se genere correctamente desde el diálogo del navegador.
- Usar «Compartir por WhatsApp» y confirmar que el mensaje preparado corresponda únicamente al comprobante seleccionado.
- Desde Créditos y abonos, abrir la cuenta completa del cliente y comprobar que el PDF muestre vencimiento y próximo pago además de compras, abonos, saldo y totales.
- Comprobar que los campos históricos no disponibles se muestren como no indicados/no registrados, sin inventar datos.
- Repetir con una cuenta que tenga más de un crédito y varios abonos; verificar que no se mezclen clientes.
