# Bancos y conciliación — dictamen técnico

Fecha: 2026-07-21  
Dictamen: **GO técnico**  
Validación con estado bancario real: **PENDIENTE**

## Alcance cerrado

- Las cuentas pagadoras existentes se convierten idempotentemente en `financial_accounts` usando el mismo UUID. `supplier_payments.paying_account_id` permanece intacto y cada pago recibe el vínculo canónico `financial_account_id`; un trigger conserva sincronizadas las altas y modificaciones hechas desde la funcionalidad existente.
- Los estados se cargan exclusivamente desde el Centro de Migración. El detector reconoce por estructura CSV/XLSX, obtiene cuenta, moneda, periodo y saldos con evidencia, y no solicita seleccionar un tipo de archivo.
- La plantilla es neutral y ningún nombre de institución está codificado en el dominio.
- Cada lote conserva SHA-256, archivo, cuenta y periodo; la unicidad por empresa, cuenta y hash impide duplicados. El staging recibe bloques de hasta 2,000 filas y el workspace lista 50 movimientos por página.
- La promoción es una operación server-side, transaccional e idempotente. Los movimientos promovidos son inmutables y no existe captura movimiento por movimiento.
- La validación bloquea promoción salvo que `saldo inicial + abonos - cargos = saldo final` con diferencia cero y sin filas inválidas.
- Los candidatos comparan cuenta, moneda, importe, fecha y referencia. Una coincidencia exacta queda pendiente de confirmación; una diferencia exige justificación; ambigüedad o ausencia permanece como excepción.
- La desconciliación exige permiso, motivo y llave de idempotencia. Cambia el vínculo a `disconnected`, conserva movimiento, candidato, conciliación, motivo, actor, fechas y auditoría.
- Se añadieron permisos separados para consulta, carga, conciliación y desconciliación; todas las tablas tienen RLS y las escrituras directas están revocadas para `authenticated` y `anon`.
- La UI vive en la ruta guiada `/satrapy/contabilidad/bancos`, enlaza al Centro de Migración para carga y ofrece operaciones masivas de hasta 500 candidatos/vínculos.

## Entregables

- SQL completo: [`202607210001_m4c_banking_reconciliation.sql`](../../supabase/migrations/202607210001_m4c_banking_reconciliation.sql)
- Detector neutral: [`bank-statement-import.ts`](../../app/lib/bank-statement-import.ts)
- UI: [`BankingModule.tsx`](../../app/components/BankingModule.tsx)
- Prueba SQL: [`202607210001_m4c_banking_reconciliation.sql`](../../supabase/tests/202607210001_m4c_banking_reconciliation.sql)
- Pruebas de detector/contrato: [`bank-statement-import.test.ts`](../../tests/bank-statement-import.test.ts)
- Concurrencia: [`banking-setup.sql`](../../supabase/concurrency/banking-setup.sql), [`banking-promote.sql`](../../supabase/concurrency/banking-promote.sql), [`banking-verify.sql`](../../supabase/concurrency/banking-verify.sql)
- Plantillas controladas: [`XLSX`](../../public/templates/plantilla_estado_bancario_neutral.xlsx) y [`CSV`](../../public/templates/plantilla_estado_bancario_neutral.csv)

## Evidencia reproducible

Corrida limpia: [`summary.txt`](./evidence/20260721T231809Z/summary.txt) — **55 PASS, 0 FAIL**.

- Aplicación desde cero y reset final: [`migration-reset.log`](./evidence/20260721T231809Z/migration-reset.log), [`final-clean-reset.log`](./evidence/20260721T231809Z/final-clean-reset.log)
- Prueba bancaria transaccional/RLS: [`202607210001_m4c_banking_reconciliation.log`](./evidence/20260721T231809Z/202607210001_m4c_banking_reconciliation.log)
- Dos promociones simultáneas, un movimiento y una llave: [`a`](./evidence/20260721T231809Z/concurrency_banking-a.log), [`b`](./evidence/20260721T231809Z/concurrency_banking-b.log), [`verificación`](./evidence/20260721T231809Z/concurrency_banking-verify.log)
- Detector, carga duplicada y reglas estructurales: [`frontend-test-imports.log`](./evidence/20260721T231809Z/frontend-test-imports.log)
- Calidad frontend: [`frontend-lint.log`](./evidence/20260721T231809Z/frontend-lint.log), [`frontend-build.log`](./evidence/20260721T231809Z/frontend-build.log)
- Integridad de entregables: [`migration-sha256.txt`](./evidence/20260721T231809Z/migration-sha256.txt), [`test-sha256.txt`](./evidence/20260721T231809Z/test-sha256.txt)

La alerta `missing_separate_fiscal_source` registrada por la regresión Alpha pertenece a la validación fiscal previa y no afecta Bancos; no se abrió ni modificó ese alcance.

## Separación del dictamen

El archivo utilizado es controlado y prueba el contrato neutral, la aritmética, duplicados, conciliación, desconciliación, permisos, RLS y concurrencia. No se encontró ni se proporcionó un estado emitido por una institución financiera real. Por tanto:

- **GO técnico:** sí; migración limpia, pruebas completas y build sin fallas.
- **GO de validación bancaria real:** no emitido. Requiere cargar en el mismo Centro de Migración un estado real autorizado, confirmar detección de metadatos/columnas, totales y candidatos con Tesorería, y registrar evidencia sin añadir un adaptador salvo que ese archivo demuestre una necesidad estructural.
- **Módulo siguiente:** no iniciado.

Hashes de las plantillas entregadas:

- XLSX: `db21511693f5b399e3514cd138884186c53286eab93e1b46cc3d844fdc8cc0dd`
- CSV: `a82ececa08e5f5e0211e54f6d4cdec274aa68a7dac69e2cf0200dd9cfe3e3a9f`
