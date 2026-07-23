# Satrapy · Módulos 1, 2 y 3A

Plataforma multiempresa de Productos, Inventario por ubicación, preparación POS y ventas transaccionales. Alpha ERP es el primer adaptador de importación, no el dominio de Satrapy.

Las decisiones permanentes de producto y arquitectura están documentadas en `AGENTS.md`.

## Arranque local

1. Crea `.env` y completa las dos variables públicas de Supabase.
2. Aplica, en orden, todas las migraciones de `supabase/migrations/` con la CLI de Supabase o el SQL Editor. Las migraciones `202607130002` a `202607130004` instalan el dominio POS/ventas, sus RPCs transaccionales, RLS y la configuración de caja, pagos y descuentos.
3. Crea un usuario real en Supabase Auth (email/contraseña).
4. Usa las instrucciones comentadas en `supabase/bootstrap.example.sql` para crear la empresa real y asignar el rol `super_admin` al UUID de ese usuario.
5. Ejecuta `npm install` y `npm run dev`. La aplicación estará en `http://localhost:3000/satrapy`.

No se usa `service_role` en el cliente. La llave configurada en el navegador debe ser la anon/publishable.

## Importación Alpha

- Manual: inicia sesión, abre **Centro de Migración** y elige un archivo `cata_prd_*.XLS/XLSX` o `reexic2_*.XLS/XLSX`.
- El archivo se analiza del lado del servidor y cada fila se guarda en staging. El preview, sus errores y alertas sobreviven una recarga de página.
- Primero importa el catálogo `cata_prd`; después importa `reexic2`. La segunda importación valida que todos los SKU existan antes de permitir la confirmación.
- La confirmación usa una RPC transaccional: productos, ubicaciones y snapshot se aplican juntos o no se aplica ninguno. Un hash ya completado se bloquea; un lote fallido puede reintentarse y queda ligado al lote anterior.
- El reporte `reexic2` conserva la fecha efectiva indicada por Alpha. Una ubicación no reconocida se detiene en revisión manual y no se crea hasta que se seleccione su tipo.
- Las filas rechazadas conservan su número y celdas originales. Solo se permite clasificar ubicaciones, mapear un SKU inexistente a un producto activo de la misma empresa y reconocer alertas con motivo auditado.
- El staging sin actividad vence a los 30 días. Sus filas y JSON se purgan 90 días después del cierre; el lote, hash, resumen y auditoría se conservan.

## Pruebas de seguridad

- Asigna a un usuario el rol `sucursal` o `ingeniero_campo` para una empresa y crea filas de `user_location_access` únicamente para una ubicación.
- Al iniciar sesión con ese usuario, `inventory_snapshot_items` queda filtrado por RLS a esa ubicación, incluso si se intenta consultar la tabla directamente con la llave anon.
- Un `punto_venta` ve catálogo y existencias de sus ubicaciones asignadas. Los costos de inventario se guardan para trazabilidad, pero sus columnas no se conceden al rol `authenticated`; RLS sigue filtrando las filas operativas por ubicación.
- Con `super_admin`, utiliza **Ver como rol** para probar la navegación. Esta vista solo cambia la interfaz: no desactiva ni reemplaza RLS.
- Las pruebas SQL de `supabase/tests/` se ejecutan dentro de `BEGIN/ROLLBACK`: validan atomicidad, duplicados, reintentos, retención y la matriz RLS de los cinco roles no globales sin conservar fixtures.

## Preparación POS

- **Preparación POS** crea el surtido inicial en una sola operación masiva y permite elegir entre las sucursales activas importadas de la empresa.
- La membresía del surtido es una decisión comercial durable. Un producto pendiente permanece en el surtido, pero no aparece en el POS hasta recuperar precio, impuesto, unidad, estado y demás requisitos.
- **Actualizar catálogo** incorpora productos vendibles nuevos sin retirar miembros existentes. La preparación se consulta con búsqueda, estados y paginación server-side.
- El POS debe consumir `search_pos_products` y `validate_pos_product_for_location`; ambas funciones operan con IDs canónicos y referencias externas, nunca con campos Alpha.
- Los códigos de Alpha se conservan como referencias externas de compatibilidad. Alpha continúa siendo el importador inicial, pero no define la identidad del producto ni de la ubicación.

## POS + Ventas

- El POS requiere una caja abierta por el propio operador. La apertura y el cierre se cuentan por denominación; una diferencia nunca se cierra sin aprobación separada.
- El carrito solo es un borrador server-side. La confirmación de venta revalida surtido, readiness, precio efectivo, impuestos, permisos, caja y existencia dentro de una única transacción idempotente.
- El stock operativo se inicializa con `backfill_inventory_opening_balances`, una operación paginada y auditada que convierte snapshots completados en el ledger. Ejecuta sus páginas hasta recibir `complete: true` y revisa la conciliación antes de habilitar una ubicación para ventas.
- Cada venta crea un ticket canónico inmutable con hash y un evento `ticket.ready` en outbox. La impresión física no está conectada aún; el futuro agente local consumirá ese contrato, sin reconstruir importes desde tablas de trabajo.
- Contado usa una sola forma de pago configurable; solo las de tipo `cash_drawer` afectan el arqueo. Crédito exige cliente, límite, plazo y genera cuentas por cobrar; los abonos son FIFO y de una sola forma de pago.
- Precios: lista del cliente, luego de la ubicación y finalmente la predeterminada de la empresa. Descuentos fuera del límite del rol bloquean el cobro hasta aprobación auditada por otra persona.
- No se incluyen todavía modo offline, pagos mixtos, devoluciones ni cobranza avanzada. M4A incorpora la base contable y la póliza de apertura; la contabilización automática de operaciones pertenece a M4B y no está iniciada.

## Base contable y apertura (M4A)

- Existe un solo Centro de Migración para todos los XLS, XLSX o CSV. El cargador principal detecta catálogo y balanza por su estructura, conserva staging paginado, permite mapear cuentas externas y bloquea la promoción mientras existan excepciones; no hay cargadores separados por módulo.
- **Contabilidad** es un módulo superior visible con Resumen, Catálogo, Periodos, Pólizas, Apertura y Configuración. La configuración contable vive ahí y es explícita/versionada: moneda, corte, estructura, cuentas de control, tratamiento de IVA/retenciones y responsables no reciben valores inventados.
- La balanza se concilia contra CxC, CxP, inventario/costo y caja. Cuentas pagadoras y egresos bancarios se auditan sin inventar un saldo bancario que Satrapy todavía no posee; la brecha queda visible como alerta. La póliza de apertura es transaccional, idempotente e inmutable.
- Periodos, ajustes y cierre/reapertura usan permisos independientes, RLS por empresa y auditoría. Una reapertura requiere una persona distinta de quien cerró.

## Proveedores (Módulo 3A)

- El proveedor canónico vive en `suppliers`; la clave Alpha se conserva únicamente en `supplier_external_references`.
- **Compras → Proveedores** consulta nombre, código, RFC, teléfono y referencia externa con filtros y paginación server-side.
- `promote_alpha_suppliers` procesa un lote completo dentro de una transacción, admite reintentos idempotentes y envía sólo coincidencias de RFC, código o identidad a `supplier_import_exceptions`.
- Las altas y ediciones requieren permisos explícitos y registran valores anterior/posterior. La promoción y resolución de excepciones tienen permisos y eventos de auditoría independientes.
- Las OC, partidas, documentos CxP y pagos Alpha continúan como evidencia en staging. 3A no crea órdenes, recepciones, inventario/costo, facturas, CxP ni pagos operativos.
