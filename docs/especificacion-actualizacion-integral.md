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


## Registro de avance — etapas 1 y 2 aplicadas

- La etapa 1 (supabase/actualizacion_integral_etapa1.sql) fue ejecutada por el usuario en Supabase y verificada: existen sale_code, comments, cash_amount y yape_amount; también se confirmaron los cuatro índices previstos.
- La estructura real de customers fue verificada: id, name, phone, address, created_by y created_at.
- La etapa 2 (supabase/actualizacion_integral_etapa2.sql) fue ejecutada por el usuario y verificada: finalize_sale_v2 y get_cash_session_summary existen; authenticated puede ejecutarlas y anon no.
- Se conserva la función original finalize_sale y no se reemplazaron las funciones de apertura, abonos o cierre.
- En index.html, rama de trabajo, el formulario de ventas ahora llama a finalize_sale_v2 y envía cliente, nombre libre, comentarios, tipo de venta, artículos y pagos. También consulta get_cash_session_summary para presentar efectivo/QR esperado, ventas a crédito, abonos, saldo y total vendido.
- Se agregó validación de correspondencia entre método seleccionado e importes de efectivo/Yape para ventas al contado y crédito.

Estado: integración inicial de ventas y resumen de caja preparada en la rama de trabajo. Aún requiere pruebas funcionales completas; no se ha integrado a main ni desplegado a producción. Las demás funciones solicitadas (incluyendo historial filtrable, estado de cuenta detallado, imágenes sincronizadas, gestión de usuarios y comprobante) deben seguir verificándose e implementándose antes de considerar terminada la actualización integral.


## Integración adicional de interfaz — rama de trabajo

Se amplió index.html sin publicar a producción:
- Historial de ventas con filtros por fecha desde/hasta y búsqueda por código o cliente.
- Comprobante imprimible por venta, con código, fecha, cliente, detalle de productos, cantidades, precios, subtotales, total, abonado, saldo y comentarios.
- Consulta de estado de cuenta por cliente, con compras, total acumulado, abonado, saldo y detalle de abonos por fecha y método.
- Listado administrativo de perfiles con nombre, rol y fecha de registro. El correo no se expone porque no se ha confirmado que exista en profiles; la administración de credenciales requiere un flujo seguro de Supabase Auth.
- Búsqueda externa de imágenes por nombre/código; el usuario descarga una imagen autorizada y la carga al producto. Se conserva selección desde cámara/galería.
- Se corrigió la carga de precios y subtotales de artículos para el comprobante y se muestra el sale_code real después de guardar la venta.
- Se evitó cambiar created_by al editar un cliente.

Validación estática: el JavaScript embebido de index.html pasó una comprobación de sintaxis. Esto no sustituye pruebas en navegador ni pruebas reales contra Supabase.

Pendiente antes de producción: verificar en navegador con usuarios vendedor y administrador; probar apertura/cierre, venta contado, crédito y mixta, descuento de stock, abonos, consulta de cliente, filtros, impresión, permisos RLS y subida/visualización de imágenes. También queda por confirmar bucket y políticas de Storage, flujo de escáner por cámara y operaciones administrativas de Auth. No integrar a main ni desplegar hasta completar pruebas y autorización explícita.


## Alcance ampliado — actualización integral v2 (aprobado para desarrollo en pruebas)

El usuario autorizó avanzar con la nueva versión integral tomando como base la rama de actualización y el proyecto Supabase de pruebas. Mantener `main`, producción y los datos existentes intactos hasta aprobación final.

### Identificación y reportes de vendedores
- Asignar a cada perfil de vendedor un código único, irrepetible y permanente al crearlo. Debe generarse de forma segura en la base de datos, no depender del navegador ni del nombre editable.
- Mostrar código y nombre juntos en administración, historial, detalles, reportes y resúmenes.
- El administrador tendrá una vista de ventas por vendedor: todos o un vendedor específico, con cantidad de operaciones y total vendido por día.
- Separar total vendido, efectivo cobrado, Yape cobrado, otros medios, adelantos de créditos y saldo pendiente. No confundir ventas a crédito con dinero recibido.
- Vendedores solo consultan sus propias ventas, su propia caja y sus propios importes. Toda restricción debe aplicarse también en RLS/RPC, no solo ocultando controles de interfaz.

### Confirmación de venta y vuelto
- En ventas al contado con efectivo, añadir el importe entregado por el cliente y calcular automáticamente el vuelto: efectivo recibido menos importe que corresponde cobrar en efectivo.
- Validar que el importe entregado cubra la parte en efectivo. No calcular vuelto sobre Yape ni sobre un saldo a crédito.
- En pagos mixtos, separar importe efectivo e importe Yape; el vuelto se calcula únicamente sobre el efectivo recibido y el sistema debe distinguir dinero recibido de importe aplicado a la venta.
- Guardar importes aplicados y, si corresponde, efectivo entregado y vuelto como datos de la operación, con comprobante claro. No alterar el total ni los pagos registrados para simular el vuelto.

### Apariencia
- Incorporar modo día y modo noche con paleta coherente y contraste legible en todas las secciones, tablas, formularios, avisos y diálogos propios.
- Permitir que cada usuario elija su preferencia y conservarla entre sesiones/dispositivos cuando sea posible mediante un ajuste por usuario; no afectar permisos ni datos operativos.

### Historial de ventas e inventario
- El administrador podrá consultar el historial global o filtrarlo por vendedor; cada fila y detalle identificará al vendedor responsable por nombre y código.
- Mantener para vendedor el alcance de sus propias ventas.
- Crear auditoría de inventario por producto que registre stock inicial, ingresos, salidas por venta, ajustes manuales y cualquier edición que cambie stock: fecha/hora, usuario responsable, tipo, cantidad anterior, variación, stock resultante y motivo/comentario.
- La actualización de stock y su movimiento de auditoría deben ser atómicos; no inventar el stock inicial histórico que no exista en los registros actuales.

### Créditos
- Ampliar el módulo para fechas de vencimiento, fecha de pago/abono y próximo pago acordado, historial de abonos, saldo y estados pendiente/parcial/pagado/vencido.
- Conservar los créditos y pagos existentes. Las nuevas fechas de vencimiento históricas permanecerán sin asignar cuando no haya evidencia fiable; no inventarlas.

### Productos, búsqueda y escáner
- Añadir imágenes referenciales por producto, cámara/galería, imagen predeterminada y miniaturas en ventas; conservar sincronización entre dispositivos mediante Storage.
- La búsqueda manual debe presentar coincidencias dinámicas seleccionables conforme se escribe.
- El escaneo de código debe identificar y agregar/dirigir directamente al producto coincidente, sin presentar una lista alternativa. Si no existe coincidencia o no hay stock, informar claramente.

### Resumen de caja
- Rediseñar exclusivamente la presentación de «Resumen de caja» con bloques claros e importes destacados. No extender el rediseño a otras tablas.
- No cerrar ni conciliar sesiones existentes durante desarrollo o pruebas sin autorización explícita del usuario.

### Método de implementación y aceptación
1. Auditar esquema real, funciones, políticas RLS, permisos, triggers y código antes de cada migración.
2. Preparar migraciones aditivas e idempotentes, con verificaciones previas y posteriores; nunca ejecutar bootstrap sobre el esquema existente.
3. Mantener la lógica transaccional de ventas, pagos, movimientos y stock. Cualquier cambio de RPC debe conservar firmas compatibles o versionarse y verificarse.
4. Implementar y probar primero en la rama de actualización y el proyecto Supabase de pruebas.
5. Probar con roles de administrador y vendedor, casos contado/efectivo con vuelto, Yape, mixto, crédito, abonos, stock, auditoría, filtros, tema, Storage y permisos.
6. No modificar producción, integrar a main, cerrar cajas ni desplegar hasta que el usuario revise resultados y autorice expresamente.
