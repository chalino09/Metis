# Módulo 3C — Evidencia de cierre

Fecha: 2026-07-16  
Resultado: **GO**

## Impacto y regla conservada

- Fuente histórica conocida: 84 OC y 731 partidas; 0 recepciones históricas inequívocas promovibles.
- Los estados Alpha `Por Surtir`, `Parcial` y `Surtido` permanecen como evidencia. M3C no crea recepciones ni movimientos históricos.
- No existe captura manual registro por registro ni una nueva importación de Excel.
- El método operativo auditado de Satrapy es `replacement_cost` con vigencias no traslapadas. La recepción conserva ese método; no introduce costo promedio.
- Factura, CxP y Pago permanecen fuera del alcance.

## Estrategia transaccional

- `save_purchase_receipt`: valida OC aprobada, empresa, ubicación, partidas y pendientes bajo bloqueo de la OC; toma cantidades del cliente, pero deriva producto y costo neto desde la OC.
- `confirm_purchase_receipt`: bloquea recepción, OC, partidas y saldos producto–ubicación; valida nuevamente pendientes; crea ledger, actualiza saldo y costo de reemplazo, cambia cumplimiento y audita dentro de una sola transacción.
- `reverse_purchase_receipt`: bloquea los mismos agregados, valida existencia suficiente, genera contramovimientos, restaura el costo anterior cuando la recepción revertida sigue siendo la vigencia actual, recalcula cumplimiento y conserva el documento original.
- Claves únicas por empresa y request, más índices únicos por partida/tipo de movimiento, impiden duplicación por reintento.
- RLS y los RPC separan consulta, borradores, confirmación, reversa y visibilidad de costo; el acceso a ubicación se valida tanto al leer como al mutar.

## Criterios cubiertos

- Sólo OC aprobada; rechazadas y canceladas bloqueadas.
- Borrador sin inventario/costo; confirmación parcial y total exacta.
- Ordenada, recibida previa, pendiente y actual calculadas en servidor y visibles en UI.
- Sobreentrega, partida ajena, producto no canónico y ubicación ajena bloqueados.
- Recepción confirmada inmutable; corrección sólo por reversa autorizada y motivada.
- Ledger relacionado con recepción, OC, proveedor, producto y ubicación.
- Cumplimiento `pending`, `partially_received`, `fully_received` recalculado desde cantidades confirmadas.
- Listado/búsqueda/filtros/paginación server-side; detalle con movimientos; OC con recepciones y brecha histórica.
- No se crean facturas, CxP ni pagos.

## Pruebas ejecutadas

- Base limpia: `supabase db reset` — PASS; todas las migraciones, incluida M3C, aplicaron.
- Regresión SQL: 28/28 archivos — PASS (M1, M2, M3A, M3B y M3C).
- Prueba transaccional M3C — PASS: parcial, total, sobreentrega, partidas, costo, reversa, auditoría, permisos, RLS, aislamiento y staging.
- Concurrencia — PASS:
  - dos confirmaciones simultáneas de la misma recepción y misma clave: ambas respuestas válidas, un solo movimiento;
  - dos recepciones simultáneas por el mismo pendiente: una confirma y la otra falla; saldo final 10 y dos movimientos totales (parcial previa + complemento).
- Importación/navegación: 25/25 — PASS.
- `npm run lint` — PASS.
- `npm run build` — PASS, compilación y TypeScript.
- Evidencia histórica previa de M3B: `source_orders=84`, `source_lines=731`, `promoted_orders=84`, `promoted_lines=731`, `receipts=0`, `inventory_changes=0`, `cost_changes=0`, `payables=0`, idempotente.
- La prueba M3C toma conteos de staging antes de operar y exige que permanezcan idénticos al final; PASS.

## Pendientes

- Ninguno dentro de M3C.
- Factura, CxP y Pago se mantienen explícitamente para M3D.
