# Validación RLS de Tarea 2.5

Usa cuentas reales separadas. No pruebes `Ver como rol`: esa función cambia la UI, no el JWT ni RLS.

1. Dirección/Admin: puede abrir Centro de Migración, subir, resolver, reconocer, descartar, reintentar y confirmar.
2. Sucursal: no ve Centro de Migración ni Auditoría; en consultas directas no puede leer `import_batches`, staging ni ejecutar las RPC de Tarea 2.5. Solo ve inventario de sus ubicaciones en `user_location_access`.
3. Ingeniero de Campo: mismas restricciones de importación; solo ve items de la ubicación de campo asignada.
4. Almacén: ve Productos, Inventario y Ubicaciones; no ve ni puede consultar staging o auditoría.
5. Punto de Venta: ve Productos e inventario local asignado; no ve staging, auditoría ni columnas de costo.

Para cada cuenta operativa, una llamada REST/RPC directa a `get_import_staging_preview`, `resolve_staged_product`, `acknowledge_staged_warnings`, `discard_staged_import`, `retry_staged_import` o `confirm_staged_import` debe responder sin autorización. Esto confirma que ocultar el módulo en React no sustituye RLS/RBAC.
