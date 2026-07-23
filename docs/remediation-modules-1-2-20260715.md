# Cierre de remediación de Módulos 1 y 2 — 2026-07-15

## Dictamen

**NO-GO para iniciar Módulo 3.** La remediación de código y la validación técnica están completas, pero la jornada con datos reales queda bloqueada antes de la venta porque no se entregó una fuente fiscal separada y siguen pendientes los mapeos comerciales de precios/costos. No se inició trabajo de Compras, Proveedores ni Cuentas por Pagar.

## Tarea 1 — Contrato de catálogo

**Completo y probado.** `cata_prd` acepta productos con clave/nombre aunque no contenga impuesto. La promoción conserva `tax_category_id = null`; readiness reporta `missing_tax_category`; una importación fiscal posterior completa el mismo producto sin que una reimportación base borre su impuesto.

Evidencia:

- 15/15 pruebas TypeScript.
- Regresión SQL `202607150001_alpha_product_tax_import`: PASS.
- Catálogos reales: 1,670 y 1,628 productos, cero errores de parseo, cero impuestos inventados.
- Promoción transaccional real: 1,670 productos; 1,670 pendientes fiscales; segundo `confirm` idempotente; rollback al finalizar.

## Tarea 2 — Entorno, seguridad, idempotencia y concurrencia

**Completo y probado.** La base se reconstruye desde las mismas migraciones. La UI conserva la clave mientras no cambie la huella de la operación y solo la libera al concluir con éxito. Aplica a venta, abono, apertura y cierre de caja.

La suite detectó y corrigió:

- ejecución directa de RPC de negocio por `anon`;
- cursor inválido por `max(uuid)`;
- filtro vacío de readiness tratado como estado inválido;
- sobrecarga antigua que hacía ambigua la paginación de CxC;
- resolución de `digest` fuera del `search_path` al emitir ticket;
- pruebas antiguas que resolvían al actor después de activar RLS o invocaban contratos retirados.

Resultado final integrado: **21/21 PASS, 0 FAIL** (16 casos SQL, concurrencia, catálogo real, 15 pruebas frontend, lint y build). Dos ventas simultáneas por una existencia producen una venta y un rechazo por existencia insuficiente, sin saldo negativo. Dos llamadas simultáneas con la misma clave producen una venta, un ticket y una respuesta `idempotent=true`.

## Tarea 3 — Jornada end-to-end real

**Bloqueante.** La ruta funcional con fixtures ejecuta apertura, venta, impuesto, inventario, efectivo, ticket canónico, reintento idempotente, cierre y arqueo sin diferencia. Con datos Alpha reales se ejecutó importación y promoción masiva del catálogo, pero los productos quedaron correctamente no vendibles por falta fiscal.

Bloqueos de datos/configuración:

- **P0:** no existe en la carpeta entregada una fuente fiscal con `staiva/porceniva` (o equivalentes); 3,298 filas de los dos catálogos tienen `taxConfigured=0`.
- **P0 para la jornada:** precios contiene 2,251 registros, pero reporta listas y moneda sin mapear; no puede definirse un precio efectivo sin una asignación comercial aprobada.
- **P1:** costos contiene 1,670 registros, con moneda sin mapear y faltantes que deben conciliarse antes del cierre operativo definitivo.

Inventario sí es legible: 2,239 registros en 8 ubicaciones, sin errores de parseo.

## Evidencia final

Directorio: `docs/validation/evidence/20260715T180803Z/`

- `summary.txt`: resultado consolidado.
- `migration-sha256.txt` y `test-sha256.txt`: identidad de lo ejecutado.
- `202607130004_pos_sales_transaction.log`: jornada funcional hasta cierre/arqueo.
- `concurrency_sales-*.log`: clientes paralelos y verificación de efectos únicos.
- `real-alpha-profile.log`: conteos y bloqueos de archivos reales.
- `real-alpha-catalog-transaction.log`: staging/promoción/reintento real con rollback.

Además: lint PASS y build de producción PASS.

## Condición para reabrir el gate

Entregar la exportación fiscal separada y las asignaciones aprobadas de moneda/listas de precio y moneda de costo. Luego volver a ejecutar `npm run test:sql` y completar la jornada real hasta cierre de caja. Solo un resultado sin `FAIL` ni `BLOCKED` permite cambiar el dictamen a GO.
