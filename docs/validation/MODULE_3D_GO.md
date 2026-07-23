# Módulo 3D — Factura de proveedor y Cuentas por Pagar

Fecha: 2026-07-16  
Decisión: **GO**

## Extensión final 2026-07-16

Estado: **GO local / despliegue remoto pendiente**.

- Se añadió expediente privado XML/PDF con SHA-256 único, extracción CFDI 4.0 y comparación de UUID, RFC emisor/receptor cuando están configurados, moneda, fecha, tipo, total y proveedor.
- La validación local del XML no se presenta como verificación SAT. El resultado SAT se registra por separado con fecha y evidencia; un XML discordante bloquea la confirmación.
- Se añadieron facturas de gasto o servicio sin recepción. Conservan los estados mínimos de factura y exigen aprobación motivada antes de crear CxP; nunca crean recepción, inventario o costo.
- Se añadieron moneda base, tipo de cambio y saldos base sincronizados. Las notas de crédito y reversas actualizan ambos saldos sin modificar la factura original.
- Se añadió antigüedad de CxP por moneda: por vencer, 1–30, 31–60, 61–90 y más de 90 días. No se mezclan monedas en un total agregado.
- La interfaz ahora separa origen contra recepción / gasto-servicio, muestra expediente fiscal, evidencia SAT, tipo de cambio y pestaña de antigüedad.
- M3E conserva propiedad exclusiva de anticipos, pagos, bancos, aplicaciones y conciliación bancaria.

## Cierre fiscal de gasto/servicio 2026-07-17

- La migración `202607170003_supplier_expense_cfdi_concepts.sql` conserva por concepto clave SAT, identificación, cantidad, unidad, descripción, valor unitario, importe, descuento, objeto de impuesto y detalle de traslados/retenciones.
- El XML CFDI 4.0 puede cargarse antes del borrador y autollena proveedor por RFC, identidad, fechas, moneda, método/forma, conceptos e impuestos. La captura manual queda como respaldo excepcional de bajo volumen.
- Categoría, centro de costo y proyecto se guardan como referencias internas del concepto; no se presentan como datos exigidos por el SAT ni crean contabilidad.
- Para proveedores mexicanos, una factura de gasto no puede confirmar CxP sin XML CFDI 4.0 coincidente. La aprobación motivada continúa siendo independiente.
- Traslados y retenciones se separan; la CxP usa `subtotal - descuento + traslados - retenciones` y nunca modifica inventario ni costo.
- Validación frontend: 26/26 pruebas de importación, lint y build de producción PASS. La prueba SQL local nueva está preparada, pero no pudo ejecutarse en esta estación porque no hay motor Docker/PostgreSQL instalado.

## Auditoría previa, volumen e impacto

- M3A, M3B y M3C aplican desde una base limpia y sus regresiones pasan.
- Evidencia Alpha: 84 OC aprobadas / 731 partidas; 62 documentos abiertos por 9,999,955.47 MXN; 2 saldos negativos pendientes de clasificación; 2,220 aplicaciones de pago. Todo permanece en staging/evidencia.
- La fuente Alpha no contiene comprobante inequívoco de recepción. No se promovieron recepciones, facturas, CxP, notas de crédito ni pagos históricos.
- La base local limpia tiene 0 recepciones operativas confirmadas disponibles; los casos M3D se validaron con operaciones controladas y reversibles.
- `OC-2026-000085` permanece cancelada y queda excluida por la regla que exige una OC `approved`, `operational` y una recepción `confirmed`.
- Cantidades e importes usan `numeric(18,6)`, porcentajes `numeric(9,4)` y moneda ISO de tres letras. No se inventaron reglas fiscales, tolerancias, límites ni tipos de cambio.

## Implementación

- Entidad canónica `supplier_invoices` con factura/nota de crédito, identidad documental, estados mínimos, referencias canónicas, valores server-side y auditoría.
- Partidas ligadas a partida de OC y partida de recepción; relación explícita con una o varias recepciones confirmadas.
- CxP canónica `accounts_payable`, con importe original, saldo no editable por cliente, emisión, vencimiento y condición vencida/no vencida calculada.
- Ajustes de CxP separados para reversa y nota de crédito; no existen tablas ni RPC de pagos en M3D.
- Bandeja auditada para UUID/identidad duplicada y diferencias de conciliación.
- RLS y permisos separados para consulta, borradores, confirmación, autorización de diferencias, reversa, nota de crédito, CxP y costos.
- Interfaz paginada de Facturas, CxP y Excepciones; alta desde recepción, conciliación de tres vías, detalle, historial, reversa y crédito.
- Interfaz de gasto/servicio aprobado, expediente fiscal y antigüedad de saldos por moneda.

## Estrategia transaccional y concurrente

- El borrador valida empresa, proveedor, OC operativa aprobada, recepción confirmada y cantidades disponibles; calcula subtotal, descuento, impuesto y total en servidor.
- La confirmación bloquea factura, OC y partidas de recepción, recalcula el pendiente confirmado y crea factura + CxP + auditoría en una transacción.
- `confirm_request_id` es único por empresa; dos reintentos concurrentes de la misma confirmación devuelven una sola CxP.
- Dos facturas concurrentes por el mismo pendiente serializan sobre la partida recibida: sólo una consume el saldo.
- UUID fiscal es la identidad prioritaria. Sin UUID, se usa empresa + proveedor + serie + folio + fecha + total. Un duplicado se bloquea y entra a excepciones; nunca se fusiona.
- Sin política fiscal/tolerancia comprobada, toda diferencia exacta de precio, descuento, impuesto o moneda queda visible y bloqueada hasta autorización explícita, motivada y auditada.
- Cantidades superiores a lo recibido nunca son autorizables.
- La reversa libera cantidades mediante el estado documental, lleva CxP a cero y conserva motivo/actor/fecha. Una recepción facturada no puede revertirse antes que su factura.
- La nota de crédito requiere factura confirmada, reduce CxP transaccionalmente y bloquea importes que producirían saldo contrario.

## Criterios de aceptación

- Borrador sin CxP: PASS.
- Factura parcial y factura complementaria sólo sobre recibido pendiente: PASS.
- Confirmación y CxP exactamente una vez; saldo inicial igual al total: PASS.
- Sobrecantidad, partida agotada, recepción no confirmada y OC no facturable: PASS.
- UUID duplicado e identidad alternativa: bloqueados por función/índice y enviados a revisión.
- Diferencias visibles, bloqueadas y autorizables sólo con permiso + motivo: PASS.
- Confirmación concurrente e idempotente: PASS; resultados `same=0,0`, `overflow=0,3`, dos CxP finales para dos obligaciones válidas.
- Factura confirmada inmutable, reversa auditada y liberación de cantidades: PASS.
- Nota de crédito disminuye saldo y no crea pagos: PASS.
- Inventario, ledger y costos idénticos antes/después de confirmar, revertir y acreditar: PASS.
- RLS, aislamiento por empresa y matriz de permisos: PASS.
- Alpha no promovido y OC histórica excluida: PASS.

## Evidencia

- Suite completa: `docs/validation/evidence/20260717T003653Z/summary.txt`.
- Resultado: 40 PASS, 0 FAIL, incluido el reset limpio final.
- SQL M3D: `202607170001_supplier_invoices_payables.log`.
- Concurrencia M3D: `concurrency_supplier_invoices-*.log`.
- Perfil Alpha: 62 CxP, 9,999,955.47 MXN, 2 saldos negativos, 2,220 aplicaciones; `receipt_source_available=false`.
- Promoción real M3B en transacción/rollback: 84 OC, 731 partidas, 0 recepciones, 0 CxP, 0 cambios de inventario/costo.
- Frontend/importación: 26/26 pruebas PASS; lint PASS; build de producción PASS.
- Reset limpio final aplicado: 0 OC, 0 recepciones, 0 facturas, 0 CxP, 0 ledger y 0 costos en el seed local.
- Extensión local: `docs/validation/evidence/20260717T011935Z-m3d-local/`; M3D original PASS, extensión PASS, concurrencia PASS, importaciones frontend PASS, lint PASS y build PASS. El reset final limpio se completó inmediatamente después de la corrida.

## Diferencias y pendientes

- Los dos saldos Alpha negativos siguen sin clasificación y no se convirtieron en notas de crédito.
- Las 333 referencias de pago con proveedor Alpha no resuelto siguen sólo como evidencia; no afectan M3D porque no se implementaron pagos.
- El marcador preexistente `missing_separate_fiscal_source` del catálogo continúa visible en la suite general. M3D no infiere impuestos y bloquea cualquier impuesto distinto de la recepción salvo autorización explícita; no es un fallo de Factura/CxP.
- No existe una recepción operativa real en el seed limpio para UAT persistente. El siguiente uso operativo deberá comenzar por una recepción M3C confirmada.
- Pagos, bancos, egresos y conciliación bancaria quedan expresamente fuera de alcance para un módulo posterior.
- La migración `202607170003_supplier_expense_cfdi_concepts.sql` debe aplicarse después de `202607170002_complete_supplier_invoices_payables.sql` antes de probar el cierre fiscal de gasto/servicio con datos persistentes. No se desplegó automáticamente para evitar una mutación remota no autorizada.
