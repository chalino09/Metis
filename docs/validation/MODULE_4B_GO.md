# M4B — Contabilización operativa: GO

Fecha de validación: 2026-07-20  
Decisión: **GO técnico local**

## Dictamen

La compuerta M4B queda en **GO**. La instalación limpia y la regresión completa terminaron con **53 verificaciones aprobadas y 0 fallas**. Cada evento cubierto genera una sola póliza balanceada y enlazada al documento origen; los reintentos no duplican y las reversas comprobadas neutralizan por cuenta la póliza original. Un periodo cerrado rechaza la contabilización.

El despliegue remoto y la activación para una empresa real no forman parte de este dictamen. Para operar, esa empresa debe tener M4A lista y aprobar su propia matriz de cuentas; Satrapy no inventa cuentas ni políticas contables.

## Cobertura de la compuerta

- Venta confirmada y cancelación, incluido costo de venta e inventario.
- Cobro aplicado a CxC y reversa con restauración del saldo.
- Apertura, entrada/salida, contramovimiento y cierre de caja con faltante o sobrante.
- Recepción de compra, inventario, costo de reposición y reversa.
- Ajuste físico de inventario valuado con el método vigente.
- Factura de proveedor, variación de compra, IVA/retenciones, CxP y reversa.
- Nota de crédito de proveedor y reversa con restauración de CxP.
- Pago a proveedor, reclasificación de IVA y reversa.
- Ajustes manuales limitados a reclasificación, corrección o cierre: solicitud, aprobación por otra persona, póliza sólo al aprobar y reversa sin edición ni eliminación.

## Controles implementados

- Matriz versionada de reconocimiento, método de costo y cuentas por rol contable.
- Cálculo server-side y promoción transaccional con doble entrada obligatoria.
- Identidad única por empresa, tipo de evento, documento origen y versión.
- Cola de eventos pendientes con reproceso seguro, paginado y `SKIP LOCKED`.
- Póliza inmutable después de contabilizar, trazabilidad bidireccional y auditoría.
- Permisos separados para configurar, aprobar, reprocesar y operar ajustes manuales; RLS por empresa.
- Pantalla **Contabilidad → Eventos contables** con ruta guiada, activación masiva de la matriz, indicadores, pendientes y vínculo a póliza.
- Pantalla **Pólizas** con flujo excepcional de ajustes manuales y segregación de aprobación.

## Evidencia reproducible

- Resumen final: [`evidence/20260720T220142Z/summary.txt`](./evidence/20260720T220142Z/summary.txt)
- Motor, idempotencia y periodo cerrado: [`202607200005_m4b_event_matrix_engine.log`](./evidence/20260720T220142Z/202607200005_m4b_event_matrix_engine.log)
- Venta, cobro, caja y reversas: [`202607200006_m4b_operational_event_capture.log`](./evidence/20260720T220142Z/202607200006_m4b_operational_event_capture.log)
- Ajustes manuales: [`202607200007_m4b_manual_adjustment_approval.log`](./evidence/20260720T220142Z/202607200007_m4b_manual_adjustment_approval.log)
- Recepción y reversa exacta: [`202607160008_purchase_receipts_inventory_cost.log`](./evidence/20260720T220142Z/202607160008_purchase_receipts_inventory_cost.log)
- Facturas, CxP y notas de crédito: [`202607170001_supplier_invoices_payables.log`](./evidence/20260720T220142Z/202607170001_supplier_invoices_payables.log)
- Pagos y reversa exacta: [`202607170005_supplier_payments.log`](./evidence/20260720T220142Z/202607170005_supplier_payments.log)
- Ajuste físico valuado: [`202607150014_physical_inventory_counts.log`](./evidence/20260720T220142Z/202607150014_physical_inventory_counts.log)

Resultado del runner:

- SQL funcional, incluyendo M1–M4B: PASS.
- Concurrencia de venta, recepción, factura y pago: PASS.
- Pruebas de importación/frontend: PASS.
- ESLint: PASS.
- Build Next.js/TypeScript: PASS.
- Reset final limpio con todas las migraciones: PASS.
- Total: `passed=53`, `failed=0`.

El runner conserva `BLOCKED real_alpha_end_to_end missing_separate_fiscal_source`. Es una dependencia histórica de la validación integral Alpha ya documentada en M4A; no corresponde a la contabilización de eventos M4B ni invalida las pruebas controladas de esta compuerta.

## Prueba funcional en sesión — 2026-07-21

- Empresa de prueba: Teza Agricultura Sustentable; matriz operativa V1 activa.
- Se comprobó primero el bloqueo de una venta cuando su fecha no pertenecía a un periodo abierto; la operación no cobró ni afectó inventario.
- Se creó el periodo abierto `2026-07-2`, del 09/07/2026 al 31/07/2026.
- Venta controlada `0000000002`: subtotal $6.90, IVA $1.10, total $8.00 y costo $5.81.
- Póliza #1: debe $13.81 y haber $13.81, con caja, ventas, IVA, costo e inventario.
- Cancelación auditada desde el ticket con restitución de inventario y salida de caja.
- Póliza #2: inversa exacta de la #1, debe $13.81 y haber $13.81.
- Resultado visible en Eventos: 2 contabilizados, 0 pendientes y 1 reversa exacta.
- Caja abierta en $0.00 y cerrada en $0.00, sin diferencia; el efecto operativo neto de la prueba quedó en cero.

## Archivos principales

- `202607200005_m4b_event_matrix_engine.sql`: matriz, cola, motor, idempotencia, doble entrada y bloqueo por periodo.
- `202607200006_m4b_operational_event_capture.sql`: captura automática desde operaciones M1–M3.
- `202607200007_m4b_manual_adjustment_approval.sql`: ajustes manuales con aprobación separada.
- `202607200008_m4b_operational_reversals.sql`: documentos de reversa operativa y neutralización exacta.

No se inicia un módulo posterior con este dictamen.
