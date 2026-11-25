# SISTEMA MEJIA

Aplicación web para gestión de productos, inventario, ventas, caja, clientes, créditos y abonos.

## Ramas y despliegue

- Rama de trabajo: `actualizacion-integral-sistema-mejia`.
- Rama de producción: `main`.
- No integrar ni desplegar hasta que el usuario revise y autorice la actualización y se completen las pruebas.

## Supabase

La base existente contiene tablas y funciones ya utilizadas por la aplicación. No ejecutar `supabase/schema.sql`, `supabase/actualizacion_ventas_caja.sql` ni `supabase/actualizacion_integral_ventas_inventario.sql` ni la versión anterior de `supabase/actualizacion_integral.sql` como scripts completos sobre esa base: fueron creados para un esquema anterior y no coinciden con el estado real.

La caja canónica para la nueva interfaz es `cash_sessions`, porque las funciones actuales de ventas, pagos y movimientos dependen de ella. `cash_registers` se conserva temporalmente para compatibilidad.

Consulta `docs/especificacion-actualizacion-integral.md` antes de preparar o ejecutar migraciones.
