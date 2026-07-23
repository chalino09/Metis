# M4A — Base contable y apertura: GO

Fecha de validación: 2026-07-20  
Alcance histórico del dictamen: M4A exclusivamente; M4B todavía no se había iniciado en esa validación.

## Dictamen

**GO de ingeniería para M4A.** La instalación limpia, la regresión SQL completa, concurrencia y frontend terminaron con **50 verificaciones aprobadas y 0 fallas**. La capacidad está lista para cargar los archivos primero, confirmar la detección asistida y ejecutar una apertura controlada.

Este GO no inventa ni aprueba decisiones contables de una empresa. Satrapy detecta moneda, corte y estructura con evidencia de hoja/celda; cualquier ausencia, conflicto o corrección exige revisión. La promoción real permanece bloqueada hasta confirmar políticas, responsables vigentes, nueve cuentas de control y un periodo abierto, y hasta que la balanza concilie con los auxiliares canónicos disponibles.

## Resultado funcional

- Configuración contable versionada; una sola versión aprobada por empresa y versiones anteriores preservadas.
- Catálogo jerárquico con identidad canónica, tipo, naturaleza, nivel, afectabilidad y estado.
- Periodos no superpuestos, cierre auditado y reapertura por una persona distinta de quien cerró.
- Pólizas/partidas de doble entrada, ajustes idempotentes y bloqueo de periodos cerrados.
- Permisos separados para consulta, configuración, importación, ajustes, cierre y reapertura; RLS por empresa y escrituras únicamente por RPC.
- Un único Centro de Migración. Catálogo y balanza se guardan en staging antes de existir configuración; el detector busca encabezados en cualquier fila y obtiene fecha, moneda y estructura con evidencia. Los lotes incompletos quedan en revisión sin exigir volver a subirlos.
- Ruta bloqueada también en servidor: carga → revisión automática → catálogo → cuentas de control/aprobación → periodo → conciliación → apertura.
- Configuración guiada con políticas fiscales explícitas, responsables seleccionados entre usuarios vigentes, sugerencias de cuentas de control y motivo solicitado únicamente al corregir detección o aprobar.
- Módulo superior visible **Contabilidad** con Resumen, Catálogo, Periodos, Pólizas, Apertura y Configuración. No contiene un segundo cargador: la apertura remite al Centro de Migración principal.
- Conciliación bloqueante de la balanza contra CxC, CxP, inventario con costo disponible y caja. Para bancos se auditan cuentas pagadoras y egresos, pero se muestra una alerta no conciliable porque Satrapy no posee saldo bancario canónico; no se inventa uno. IVA y retenciones se exigen como cuentas y decisiones explícitas, pero aún no existen auxiliares fiscales canónicos independientes.
- Póliza de apertura contabilizada, con hash, inmutable y sin posibilidad de duplicación por lote o solicitud.

## Evidencia

- Paquete reproducible: [`evidence/20260720T191202Z`](./evidence/20260720T191202Z/summary.txt)
- Pruebas dedicadas: [`fundación contable`](./evidence/20260720T191202Z/202607200002_m4a_accounting_foundation.log), [`Centro unificado`](./evidence/20260720T191202Z/202607200003_m4a_unified_migration_center.log) y [`staging primero`](./evidence/20260720T191202Z/202607200004_m4a_staging_first_detection.log)
- Migración nueva: [`202607200004_m4a_staging_first_detection.sql`](../../supabase/migrations/202607200004_m4a_staging_first_detection.sql)
- Prueba transaccional nueva: [`202607200004_m4a_staging_first_detection.sql`](../../supabase/tests/202607200004_m4a_staging_first_detection.sql)

Resumen ejecutado:

- 38 pruebas SQL funcionales: PASS.
- 4 pruebas de concurrencia: PASS.
- 83 pruebas Node/importación: PASS.
- ESLint: PASS.
- Build Next.js y TypeScript: PASS.
- Reset limpio final con todas las migraciones: PASS.
- Total del runner: `passed=50`, `failed=0`.

La jornada real integral sigue marcando `BLOCKED missing_separate_fiscal_source`, una dependencia previa ajena a M4A. No afecta este dictamen: M4A se validó con archivos contables controlados y no inicia contabilización automática de M4B.

## Condiciones para la apertura real

1. Subir en el único **Centro de Migración** todos los archivos contables disponibles.
2. Confirmar la detección y las políticas en **Contabilidad → Configuración**.
3. Promover el catálogo; no se capturan cuentas registro por registro.
4. Confirmar cuentas de control, aprobar y crear el periodo sugerido por la fecha de corte.
5. Resolver excepciones, conciliar auxiliares y promover una sola póliza de apertura inmutable.

## Fuera de alcance confirmado

Los eventos contables automáticos no formaron parte de este dictamen M4A. Su implementación y evidencia posterior se documentan por separado en `MODULE_4B_GO.md`.
