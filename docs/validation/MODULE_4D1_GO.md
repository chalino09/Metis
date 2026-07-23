# M4D1 — Confiabilidad del núcleo financiero

Fecha: 2026-07-23  
Dictamen exclusivo: **GO para M4D1**

La remediación remota fue autorizada expresamente por el usuario. Codex aplicó únicamente `202607230001_m4d1_remove_premature_close.sql`; no avanzó M4D2, M4D3 ni M4D4.

## Auditoría previa

- M4A ya aportaba catálogo, cuentas de control, periodos, pólizas inmutables y el contrato `canonical_accounting_auxiliaries(company, cutoff)`; se reutilizaron.
- M4B ya aportaba eventos efectivos, pólizas operativas y reversas exactas. Se corrigió el evento existente de cobro para reclasificar proporcionalmente IVA pendiente a IVA cobrado; no se creó otro dominio fiscal.
- M4C define conciliaciones con estados `confirmed` y `disconnected`. El borrador M4D consultaba el estado inexistente `active`; M4D1 usa la historia real de confirmación/desconexión.
- Las remediaciones R-OP posteriores conservan identidades canónicas, arranque contable manual y permisos. M4D1 no añadió cargadores, catálogos ni captura registro por registro.
- El borrador `202607210002_m4d_financial_close.sql` mezclaba reportes con vista previa, aprobación, cierre y reapertura. La versión local fue sustituida por una migración exclusiva de auxiliares y reportes.
- La base remota había recibido parte del borrador anterior. La migración transaccional `202607230001` archivó el único `preview` y sus 13 comprobaciones en `audit_log`, bloqueó la operación ante cualquier cierre no preliminar y retiró las tablas y RPC prematuras sin `CASCADE`.

## Implementación M4D1

- CxC reconstruida desde documentos, cobros, aplicaciones y reversas efectivas al corte.
- CxP reconstruida desde facturas, notas de crédito, pagos, aplicaciones y reversas efectivas al corte, en moneda base.
- Inventario valuado con suma histórica del kardex y costo configurado vigente al corte; no usa `inventory_balances.quantity_on_hand`.
- Caja calculada con movimientos y sesiones bajo custodia existentes al corte.
- Bancos calculados con el último estado promovido y balanceado por cuenta; separa movimientos conciliados, pendientes y desconciliados con importes no nulos.
- IVA pendiente, cobrado, pagado y retenciones derivados de eventos contables efectivos contabilizados.
- Mayor con saldo anterior y saldo corrido según naturaleza.
- Balanza con saldo inicial, cargos, abonos, saldo final natural y totales deudores/acredores.
- Estado de resultados limitado a la actividad del rango.
- Balance general a la fecha final con resultado del ejercicio incorporado y comprobación explícita `Activo = Pasivo + Capital`.
- Entradas/salidas básicas de caja y bancos.
- Totales exactos independientes de la página y páginas de hasta 200 filas. La exportación itera páginas desde el servidor y conserva los totales calculados en servidor.

## Evidencia reproducible

Ejecutar desde la raíz:

```bash
npm run test:sql
```

Corrida definitiva: [`evidence/20260723T150050Z/summary.txt`](./evidence/20260723T150050Z/summary.txt) — **67 PASS, 0 FAIL**.

- Instalación limpia y migraciones completas: [`migration-reset.log`](./evidence/20260723T150050Z/migration-reset.log)
- Caso M4D1 no nulo, cortes, parciales, reversas, bancos, impuestos, reportes y RLS: [`202607210002_m4d_financial_close.log`](./evidence/20260723T150050Z/202607210002_m4d_financial_close.log)
- Volumen de 10,000 partidas y paginación máxima de 200: [`202607210003_m4d_report_volume.log`](./evidence/20260723T150050Z/202607210003_m4d_report_volume.log)
- Cobro parcial, IVA efectivo y reversa exacta: [`202607200006_m4b_operational_event_capture.log`](./evidence/20260723T150050Z/202607200006_m4b_operational_event_capture.log)
- Conciliación bancaria M4C: [`202607210001_m4c_banking_reconciliation.log`](./evidence/20260723T150050Z/202607210001_m4c_banking_reconciliation.log)
- Remediación M4D1 y ausencia de objetos M4D2: [`202607230001_m4d1_remove_premature_close.log`](./evidence/20260723T150050Z/202607230001_m4d1_remove_premature_close.log)
- Lecturas financieras concurrentes: [`setup`](./evidence/20260723T150050Z/concurrency_accounting_reports-setup.log), [`consulta A`](./evidence/20260723T150050Z/concurrency_accounting_reports-a.log), [`consulta B`](./evidence/20260723T150050Z/concurrency_accounting_reports-b.log), [`verificación`](./evidence/20260723T150050Z/concurrency_accounting_reports-verify.log)
- Regresión M1–M4C: todos los casos enumerados en el resumen están en PASS.
- RLS multiempresa: incluido en el caso M4D1 y en la matriz global de RLS.
- Frontend/importaciones, lint y build: [`tests`](./evidence/20260723T150050Z/frontend-test-imports.log), [`lint`](./evidence/20260723T150050Z/frontend-lint.log), [`build`](./evidence/20260723T150050Z/frontend-build.log)
- Reset limpio final: [`final-clean-reset.log`](./evidence/20260723T150050Z/final-clean-reset.log)
- Hashes reproducibles: [`migraciones`](./evidence/20260723T150050Z/migration-sha256.txt), [`pruebas`](./evidence/20260723T150050Z/test-sha256.txt)

La corrida conserva `BLOCKED real_alpha_end_to_end missing_separate_fiscal_source`, una dependencia histórica de datos Alpha ya documentada en M4A. Las validaciones reales disponibles de catálogo, compras, proveedores y órdenes están en PASS. El bloqueo no pertenece a M4D1 y no se usó para simular evidencia financiera.

## Verificación posterior al despliegue

Evidencia final: [`remediation-verification.md`](./evidence/20260723T150050Z/remediation-verification.md). El hallazgo previo se conserva en [`post-deploy-verification.md`](./evidence/20260723T145204Z/post-deploy-verification.md).

- `list_accounting_report` está publicado y rechaza al rol anónimo con `42501`; la interfaz autenticada lo ejecutó correctamente.
- Balanza del 01/07/2026 al 23/07/2026: 8 renglones, cargos `$1,396.00`, abonos `$1,396.00`.
- Estado de resultados del mismo rango: ingresos `$100.00`, gastos `$80.00`, resultado `$20.00`.
- Balance general al corte: activo `$36.00`, pasivo `$16.00`, capital y resultado `$20.00`, diferencia `$0.00`; contiene `RESULTADO-EJERCICIO`.
- La exportación Excel terminó sin error visible.
- El módulo bancario cargó sin error; esta empresa de QA no tiene movimientos bancarios remotos, por lo que los estados conciliado/pendiente/desconciliado continúan respaldados por la prueba SQL local no nula.
- El catálogo OpenAPI remoto no contiene tablas ni RPC `accounting_close*`.
- `audit_log` conserva exactamente un archivo del `preview`, con sus 13 comprobaciones y la migración de origen.
- El historial remoto registra `202607230001`.
- La balanza autenticada posterior a la remediación conserva 8 renglones, debe `$1,396.00` y haber `$1,396.00`.

## Dictamen

**GO exclusivo para M4D1.** La funcionalidad responde, el esquema remoto volvió a la frontera M4D1, la evidencia prematura quedó preservada y la validación definitiva termina en **67 PASS, 0 FAIL**.

M4D2, M4D3 y M4D4 permanecen sin iniciar.
