# Módulo 3E3 — Comprobantes bancarios y REP

Fecha: 2026-07-17  
Decisión: **GO**

Estado: **GO técnico local / despliegue remoto pendiente**.

## Implementación cerrada

- Comprobantes bancarios PDF/JPEG/PNG y REP XML se adjuntan exclusivamente a pagos M3E2 confirmados.
- Bucket privado, rutas por empresa y SHA-256, MIME/tamaño limitados, deduplicación por contenido y UUID fiscal, RLS, aislamiento por empresa y auditoría.
- Los archivos y verificaciones ya registradas son inmutables; no existen políticas de actualización o borrado desde cliente.
- El REP se recibe; Satrapy no lo genera. El RPC vuelve a calcular SHA-256 sobre los bytes originales y analiza server-side CFDI 4.0 con complemento Pagos 2.0.
- Validación local: versión/tipo/moneda/total del CFDI, UUID, RFC emisor/receptor, fecha de emisión y pago, moneda, monto, forma de pago y, por factura, UUID, moneda/equivalencia, parcialidad, saldo anterior, pagado y saldo insoluto.
- La verificación oficial SAT es evidencia separada y versionada. Vigente, cancelado y no encontrado no reescriben el XML ni la validación local.
- Estados de seguimiento: No requerido, Pendiente, Recibido y Con diferencias. PUE inicia normalmente No requerido; PPD inicia Pendiente.
- Un REP faltante, cancelado o discordante nunca revierte el pago. La evidencia discordante se conserva para revisión.
- El expediente reutiliza `supplier_payments`, `supplier_payment_applications`, `supplier_invoices` y `accounts_payable`; no existe un flujo duplicado.
- La pantalla distingue explícitamente propuestas aprobadas pendientes de pago de pagos reales ya registrados con expediente REP.

## Evidencia de aceptación

- REP válido: PASS; estado Recibido y coincidencia completa contra pago/aplicación/factura.
- Archivo y REP duplicados: PASS; SHA-256 idempotente y UUID fiscal alternado bloqueado.
- REP cancelado: PASS; queda Con diferencias, conserva pago confirmado y saldo CxP.
- REP discordante: PASS; conserva archivo e incidencias locales y queda Con diferencias.
- Archivos privados, MIME/tamaño, RLS, aislamiento e inmutabilidad: PASS.
- PUE No requerido y PPD Pendiente sin afectar la realidad del pago: PASS.
- Facturas, CxP, importe/estado del pago, inventario, ledger y costos idénticos antes/después del expediente: PASS.
- Evidencia Alpha idéntica; no se importaron las 2,220 aplicaciones históricas: PASS.
- Regresión M1–M3E3: 42 PASS, 0 FAIL.
- Concurrencia de ventas, facturas y pagos: PASS.
- Frontend/importación y seguridad documental: 30/30 PASS; lint PASS; build PASS; reset limpio final PASS.

## Evidencia reproducible

- Resumen: `docs/validation/evidence/20260718T015304Z/summary.txt`.
- M3E3: `docs/validation/evidence/20260718T015304Z/202607180001_supplier_payment_documents_rep.log`.
- Hashes exactos: `migration-sha256.txt` y `test-sha256.txt` del mismo directorio.
- La regresión Alpha real figura como no ejecutada porque el directorio externo no está disponible. No bloquea M3E3: este módulo prohíbe promover pagos/aplicaciones históricas y la prueba confirma que el staging Alpha no cambia.

## Fuera de alcance preservado

No se añadió conciliación bancaria, estados de cuenta, saldos bancarios, contabilidad, pólizas, BI, generación de REP ni dispersión bancaria. M3E4 no fue iniciado.
