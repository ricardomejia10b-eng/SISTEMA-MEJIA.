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
