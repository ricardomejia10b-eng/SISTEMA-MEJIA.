# SISTEMA MEJIA — especificacion consolidada de actualizacion

Esta especificacion se implementa sobre el sistema existente y preserva sus registros.

## Productos
- Busqueda por nombre o codigo y lectura de codigo de barras mediante camara cuando el dispositivo/navegador lo permita.
- Listado: foto, producto, codigo, precio mayorista, precio minorista, stock y accion de escaner.
- Alta y edicion de producto: nombre, codigo, precios mayorista/minorista, stock y foto desde camara o archivo.
- Mantener fotos sincronizadas mediante Storage de Supabase.

## Ventas y caja
- Pestañas de apertura y cierre de caja. No permitir ventas sin caja abierta.
- Apertura registra fecha/hora y efectivo inicial.
- Cierre resume el historial del dia: efectivo, Yape, credito y gran total; no permitir cerrar si el conteo declarado no cuadra con los importes registrados, salvo ajuste autorizado y documentado.
- Historial consultable por fecha.
- Iniciar venta con carrito multi-producto, codigo unico por compra, selector mayorista/minorista, cantidades +/-, eliminar linea, calculo automatico y comprobante.
- Pago: efectivo, Yape, mixto o credito. Credito permite cliente registrado y adelanto; el saldo se refleja en el historial de creditos.
- Comentarios opcionales. Nombre libre opcional solo para compras grandes sin cliente registrado.
- El inventario se descuenta una sola vez al confirmar toda la venta, tanto contado como credito. Agregar o quitar articulos del carrito no modifica stock. Bloquear stock insuficiente.
- Pago mixto requiere importes de efectivo y Yape cuya suma sea el importe pagado. En contado, la suma debe igualar el total; en credito, el pago inicial no puede superar el total.

## Clientes
- Nombre, telefono y direccion; crear y editar.
- Consulta por cliente de compras, productos, fechas, cantidades, creditos/deudas y pagos/abonos.
- Detalle de cuenta: fecha, cliente, total venta, abono y saldo.

## Creditos
- Historial: fecha, cliente, codigo de venta, total, abonado y saldo.
- Registrar abonos con validacion de saldo y actualizar el saldo automaticamente.

## Usuarios
- Seccion visible solo para administrador.
- Listado de nombre, correo y rol/estado. Nunca mostrar contrasenas: Authentication no permite leer contrasenas en texto claro; usar restablecimiento seguro.

## Seguridad y compatibilidad
- Migraciones aditivas; no borrar ni truncar datos.
- Acceso vendedor limitado a sus operaciones y administrador con supervision global.
- Probar flujos de venta, pagos, caja, inventario y creditos antes de publicar.
