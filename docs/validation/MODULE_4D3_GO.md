# M4D3 — Dimensión de ubicación y custodia de efectivo

Fecha: 2026-07-23  
Dictamen exclusivo: **GO para M4D3**

La implementación y validación inicial se realizaron en local. Posteriormente, con autorización expresa del usuario, se aplicó únicamente la migración M4D3 en remoto. No se inició ni se introdujo M4D4.

## Compuerta y auditoría inicial

M4D2 cerró documentalmente con **GO exclusivo**, 69 PASS y 0 FAIL, en [`MODULE_4D2_GO.md`](./MODULE_4D2_GO.md). Su migración, prueba, hashes y reset limpio constan en la evidencia enlazada por ese dictamen.

Antes de diseñar M4D3 se inspeccionaron las migraciones y pruebas reales M1–M4D2. Se reutilizaron:

- `locations` y `user_location_access`, con `can_access_location`;
- `cash_registers`, `cash_sessions`, `cash_counts` y `cash_movements`;
- `sales`, `sale_payments`, `receivable_payments` y sus formas `cash_drawer`/`external`;
- `inventory_ledger`, recepciones, conteos y transferencias de inventario sólo como orígenes operativos, nunca como transferencias de efectivo;
- `accounting_events`, la matriz M4B, pólizas y partidas inmutables M4A/M4D2;
- periodos contables, cuentas afectables aprobadas, `audit_log`, permisos y RLS existentes.

La auditoría confirmó que no existía un traslado de efectivo canónico. Sólo existían movimientos genéricos `paid_in`/`paid_out`; no identificaban origen, destino, aprobación, entrega ni recepción. Tampoco existía una caja central especial, y M4D3 no creó una: todo destino es una `cash_register` existente.

El hallazgo crítico fue `capture_cash_accounting_event`: M4B acreditaba todo el efectivo y usaba `cash_close_offset` al cerrar una sesión. M4D3 sustituyó ese comportamiento. El cierre sólo contabiliza una diferencia real; un cierre sin diferencia no crea póliza ni traslado.

## Implementación

### Ubicación canónica

`accounting_events` y `accounting_journal_lines` incorporan `location_id` hacia `locations`. La resolución ocurre en servidor desde el documento: venta; sesión/caja de cobro; movimiento de caja; recepción; conteo; factura respaldada por una sola recepción; o ubicación explícita del concepto de gasto. Un origen ambiguo queda en `null` y las consultas lo presentan como **Sin asignar**.

Los conceptos de gasto admiten ubicación explícita mientras la factura sea borrador. `expense_category`, `cost_center_reference` y `project_reference` permanecen intactos. El constructor contable agrupa por cuenta, categoría y ubicación del concepto; no interpreta centro de costo/proyecto ni reparte una línea.

Las reversas copian las ubicaciones de las partidas originales. El backfill sólo asigna una ubicación cuando la relación es determinista. Cambiar el nombre de `locations` no cambia el UUID histórico.

Los reportes muestran **el nombre actual** de la ubicación. No se creó una etiqueta histórica duplicada: la identidad histórica preservada es `location_id`.

La corrección dimensional de una póliza contabilizada sólo se permite mediante `correct_accounting_location`, con motivo, actor, fecha, idempotencia, auditoría y renovación del hash. El guard impide cualquier modificación directa y no permite cambiar cuenta, importe ni texto.

### Custodia

Cada caja se vincula explícitamente a una cuenta afectable existente mediante `cash_register_accounting_accounts`. La empresa configura una cuenta existente de efectivo en tránsito. M4D3 no crea cuentas contables.

El flujo separa:

1. preparación;
2. aprobación por una persona distinta;
3. retiro físico confirmado (`in_transit`);
4. recepción física confirmada (`confirmed`);
5. reversa exacta.

Preparar y aprobar no cambian saldos. El retiro bloquea la caja origen, valida el saldo elegible histórico y contabiliza caja origen → tránsito. La recepción contabiliza tránsito → caja destino. Las confirmaciones son transaccionales, idempotentes y protegidas con advisory lock por caja. Una cuenta faltante o un periodo cerrado bloquean explícitamente la operación.

Los traslados confirmados no se editan ni eliminan. Su reversa genera una sola póliza que invierte exactamente las cuatro partidas originales, incluidas cuenta, importe y ubicación.

### Concentración mensual

`prepare_cash_concentration` calcula al corte desde sesiones, movimientos y traslados fechados; no usa un saldo vivo para reconstruir historia. Genera por operación de conjunto una línea por caja origen activa y elegible. Cada línea conserva saldo anterior, propuesta y saldo resultante.

Se puede excluir o reducir con motivo y evidencia. No se permite aumentar. La aprobación es separada. Antes de confirmar se bloquean los orígenes en orden y se vuelve a comparar el saldo elegible; cualquier cambio obliga a recalcular y aprobar de nuevo. La confirmación genera un traslado canónico por origen, no una captura por venta o movimiento. La concentración completa también admite reversa exacta.

### Consultas y seguridad

Las RPC `list_cash_custody`, `list_cash_transfers`, `list_cash_concentrations`, `list_cash_concentration_lines` y `list_unassigned_accounting_locations` filtran en servidor, limitan la página a 200 filas y calculan totales sobre el conjunto completo. Una exportación puede iterar esas páginas sin cargar el universo en el navegador.

RLS exige empresa, permiso previo y acceso a las ubicaciones involucradas. No se concedieron permisos M4D3 a roles operativos de forma implícita. No se creó ninguna entidad o dimensión `inge`; las relaciones históricas con usuarios se conservaron sin reinterpretación.

## Datos históricos Sin asignar

Permanecen sin asignar:

- eventos cuyo documento no conserva una relación canónica con ubicación;
- abonos externos sin sesión y sin origen financiero canónico de ubicación;
- gastos históricos sin ubicación explícita por concepto;
- documentos de varias ubicaciones cuando una partida no pertenece inequívocamente a una de ellas.

No se usan nombre, descripción, usuario operador, proveedor, Alpha, centro de costo ni proyecto para completar estos datos.

## Evidencia reproducible

Ejecutar desde la raíz:

```bash
npm run test:sql
```

Corrida definitiva posterior al despliegue: [`evidence/20260723T160649Z/summary.txt`](./evidence/20260723T160649Z/summary.txt) — **71 PASS, 0 FAIL**.

- Instalación limpia: [`migration-reset.log`](./evidence/20260723T160649Z/migration-reset.log)
- Caso M4D3, incluidos importes exactos y 10,000 movimientos: [`202607230003_m4d3_location_cash_custody.log`](./evidence/20260723T160649Z/202607230003_m4d3_location_cash_custody.log)
- Concurrencia, dos confirmaciones de $400 contra $500 y un solo ganador: [`setup`](./evidence/20260723T160649Z/concurrency_cash_custody-setup.log), [`cliente A`](./evidence/20260723T160649Z/concurrency_cash_custody-a.log), [`cliente B`](./evidence/20260723T160649Z/concurrency_cash_custody-b.log), [`verificación`](./evidence/20260723T160649Z/concurrency_cash_custody-verify.log)
- RLS multiempresa y acceso por ubicación: incluido en el caso M4D3.
- Regresión M1–M4D2 y ocho suites de concurrencia: enumeradas en el resumen.
- Lint y build: [`lint`](./evidence/20260723T160649Z/frontend-lint.log), [`build`](./evidence/20260723T160649Z/frontend-build.log)
- Reset limpio final: [`final-clean-reset.log`](./evidence/20260723T160649Z/final-clean-reset.log)
- Hashes: [`migraciones`](./evidence/20260723T160649Z/migration-sha256.txt), [`pruebas`](./evidence/20260723T160649Z/test-sha256.txt)

La corrida conserva `BLOCKED real_alpha_end_to_end missing_separate_fiscal_source`, dependencia histórica ya documentada desde M4A. Las validaciones reales disponibles de catálogo, compras, proveedores y órdenes están en PASS. El bloqueo no pertenece a M4D3 ni se usó para inferir ubicación o custodia.

## Dictamen

**GO exclusivo para M4D3.** La dimensión canónica, el cierre sin vaciado ficticio, la custodia en caja/tránsito/destino, la concentración mensual, la doble entrada, la reversa exacta, la concurrencia, la idempotencia, los cortes históricos, RLS, volumen, regresión, lint y build quedaron aprobados con **71 PASS y 0 FAIL**.

## Verificación remota posterior

La vista previa aislada de Supabase CLI mostró exclusivamente `202607230003_m4d3_location_cash_custody.sql`. La primera aplicación detectó que el backfill histórico debía pasar por el guard de corrección dimensional; la transacción remota se revirtió completa. Se ajustó el backfill para renovar los hashes sin habilitar cambios de cuenta o importe, se revalidó localmente y el segundo intento terminó correctamente.

El historial remoto registra `202607230003`. El catálogo OpenAPI confirmó 9/9 objetos revisados: tablas de traslados, concentraciones y correcciones, más RPC de preparación, retiro, recepción, concentración y consultas. No se insertaron datos de prueba en remoto.

M4D4 permanece sin iniciar.
