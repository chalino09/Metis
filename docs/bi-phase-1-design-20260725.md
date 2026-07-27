# BI de Satrapy · contrato inicial y plan incremental

Fecha de revisión: 2026-07-25

## Evidencia del dominio existente

BI se construye sobre identidades y operaciones canónicas ya presentes:

- Ventas: `sales`, `sale_items`, `sale_payments` y `sale_cancellations`.
- CxC: `customer_receivables`, `receivable_payments` y sus aplicaciones/reversiones.
- Compras y CxP: `supplier_invoices`, `accounts_payable`, `supplier_payments` y aplicaciones.
- Inventario: `inventory_balances`, `inventory_ledger`, `products`, `product_costs` y la matriz contable aprobada.
- Caja: `cash_sessions`, `cash_movements` y reversiones.
- Bancos: `bank_transactions`, `bank_reconciliations` y estados bancarios promovidos.
- Contabilidad: `accounting_journal_entries`, `accounting_journal_lines`, catálogo y periodos.
- Nómina: `payroll_periods` y `payroll_period_lines`.
- Dimensiones canónicas: `companies`, `locations`, `products`, `customers` y `suppliers`.

Alpha no participa en consultas de BI. Sólo alimenta las fronteras de importación existentes.

## KPIs iniciales

Todos los importes se presentan por moneda canónica. La primera fase no convierte monedas.

| KPI | Naturaleza | Fórmula | Fuente canónica | Granularidad | Limitaciones actuales |
| --- | --- | --- | --- | --- | --- |
| Ventas netas devengadas | Devengada | Σ (`subtotal_amount` − `discount_amount`) de ventas completadas no canceladas | `sales`, `sale_cancellations` | Día, ubicación, cliente; producto mediante partidas | Excluye impuestos. Una venta se reconoce al completarse, no al cobrarse. |
| Tickets completados | Operativa | Conteo de ventas completadas no canceladas | `sales`, `sale_cancellations` | Día, ubicación, cliente | No equivale a facturas fiscales. |
| Ticket promedio | Operativa/devengada | Ventas netas devengadas ÷ tickets completados | `sales`, `sale_cancellations` | Día y ubicación | Nulo cuando no hay tickets. El filtro producto convierte el cálculo a ventas que contienen el producto, no al importe exclusivo de la partida. |
| Cobranza efectiva | Efectiva | Σ aplicaciones vigentes de cobros recibidos en el periodo | `receivable_payments`, `receivable_payment_applications`, reversiones | Día y cliente | Sólo cobros confirmados en Satrapy. La ubicación se deriva de la venta que originó la cuenta por cobrar. |
| Pagos efectivos a proveedores | Efectiva | Σ pagos confirmados no revertidos | `supplier_payments` | Día y proveedor | No representa gasto devengado; la ubicación sólo puede derivarse de las recepciones/facturas y puede ser múltiple. |
| Flujo bancario neto | Efectiva | Σ créditos bancarios − Σ débitos bancarios | `bank_transactions` | Día y cuenta financiera | No se atribuye a ubicación, producto, cliente o proveedor sin conciliación comprobada. |
| Saldo de CxC al corte | Devengada/posición | Σ saldo original menos aplicaciones vigentes hasta el corte | `customer_receivables`, aplicaciones y reversiones | Cliente y fecha de corte | La Fase 1 usa el saldo operativo vigente para “hoy”; los cortes históricos requieren reconstrucción por aplicaciones. |
| CxC vencida | Devengada/posición | Σ saldo pendiente con `due_date` anterior al corte | `customer_receivables` | Cliente y fecha de vencimiento | Mismo límite histórico del saldo de CxC. |
| Saldo de CxP al corte | Devengada/posición | Σ saldo pendiente de documentos no revertidos | `accounts_payable`, `supplier_invoices` | Proveedor y fecha de corte | La Fase 1 usa saldo operativo vigente; el corte histórico se incorporará con reconstrucción. |
| CxP vencida | Devengada/posición | Σ saldo pendiente con `due_date` anterior al corte | `accounts_payable` | Proveedor y fecha de vencimiento | Mismo límite histórico del saldo de CxP. |
| Inventario disponible | Operativa | Σ `quantity_on_hand` | `inventory_balances` | Ubicación y producto | Es la existencia operativa actual, no un movimiento del periodo. No suma unidades heterogéneas como valor financiero. |
| Valor de inventario | Devengada/posición | Σ cantidad × costo vigente según la matriz contable aprobada | `inventory_balances`, `product_costs`, `accounting_event_rule_sets` | Ubicación y producto | Sólo es correcto si todos los saldos tienen costo vigente y una matriz aprobada; BI debe mostrar cobertura de costo. |
| Nómina aprobada | Devengada | Σ `total_pay` de periodos aprobados o pagados cuya fecha de pago cae en el periodo | `payroll_periods`, `payroll_period_lines` | Periodo de nómina | **Todavía no publicable como importe transversal:** las corridas no conservan moneda canónica. Además es nómina interna y no calcula conceptos fiscales. |
| Nómina pagada | Efectiva | Σ `total_pay` de periodos con estado `paid` y fecha de pago en el periodo | `payroll_periods`, `payroll_period_lines` | Fecha de pago | **Todavía no publicable como importe transversal:** falta moneda canónica. El estado pagado tampoco implica conciliación bancaria. |
| Cobertura de conciliación bancaria | Operativa/control | Transacciones conciliadas ÷ transacciones bancarias promovidas | `bank_transactions`, `bank_reconciliations` | Cuenta y periodo | Mide cobertura de conciliación, no exactitud contable. |

### KPI bloqueado: margen bruto histórico exacto

La fórmula deseada es ventas netas sin impuestos menos costo de lo vendido reconocido para las mismas partidas. Hoy `sale_items` no conserva el costo reconocido por partida y fecha. `product_costs` conserva vigencias y permite una aproximación, pero no prueba que ese importe sea el costo efectivamente reconocido en cada venta. Por eso la primera versión no publicará “margen bruto” como KPI canónico.

Para habilitarlo se necesita una fuente ya aprobada por Contabilidad que enlace cada partida vendida con su costo reconocido, o agregar el snapshot de costo a la transacción de venta y su evento contable. Sólo entonces se habilitará la comparación margen devengado contra flujo efectivo, mostrando por separado:

- margen: ingreso devengado menos costo reconocido;
- flujo: cobros bancarios/caja menos pagos efectivos;
- puente explicativo: variación de CxC, CxP, inventario, impuestos y otros movimientos comprobados.

## Plan incremental

### Fase 1 · Base y resumen ejecutivo

- Área BI en la navegación existente con permiso `view_bi`.
- Secciones: Resumen ejecutivo, Explorador, Reportes y Red; sólo Resumen queda operativo en esta fase y las demás explican su siguiente entrega.
- Contrato de consulta server-side con filtros canónicos y límites de periodo.
- Búsqueda paginada de producto, cliente y proveedor; ubicación limitada por `can_access_location`.
- KPIs funcionales de ventas, cobranza, pagos, CxC, CxP, bancos, inventario y nómina, con disponibilidad explícita cuando una fuente o permiso no permite calcularlos.
- Comparación con periodo anterior, serie diaria y comparación entre ubicaciones.
- Drill-down paginado a operaciones origen.
- Definición, fórmula, fuente, periodo, actualización y trazabilidad visibles por KPI.
- Auditoría de consultas en `audit_log`.

### Fase 2 · Resumen Ejecutivo avanzado

- Series comparables e interactivas para las métricas publicables.
- Diferencia absoluta y porcentual contra el periodo anterior.
- Drill-down desde puntos y posiciones reconstruidas al corte.
- Estados parciales y causas de indisponibilidad por dimensión o cobertura.

### Fase 3 · Explorador transversal

- Constructor de métricas/dimensiones compatible con el catálogo anterior.
- Líneas, barras, áreas, dispersión, embudos y heatmaps con agregaciones server-side.
- Comparaciones entre módulos sólo cuando compartan dimensiones comprobadas.

### Fase 4 · Tableros y reportes

- Tableros configurables que referencien definiciones versionadas.
- Vistas guardadas por usuario, sin copiar datos fuente.
- Exportaciones paginadas/asíncronas a CSV/XLSX.
- PDF ejecutivo generado en servidor con snapshot de filtros, definiciones y hora de corte.

### Fase 5 · Red de dependencias

- Subred proveedor → producto → ubicación obtenida de órdenes/recepciones y surtido/inventario canónicos.
- Expansión bajo demanda, profundidad y tamaño acotados, y filtros heredados.
- Visualización secundaria; nunca sustituye al Resumen ejecutivo.

## Reglas técnicas de la Fase 1

- Las funciones RPC validan empresa, permiso, ubicación y rango antes de consultar.
- Ninguna consulta devuelve datasets completos: las series se acotan por días y los detalles se paginan.
- Los filtros usan UUID canónicos; el texto sólo sirve para buscar opciones paginadas.
- Las métricas efectivas, devengadas y operativas se etiquetan y no se suman entre sí.
- Una dimensión que no aplica a una fuente produce “no disponible con estos filtros”, no un cero engañoso.
- La respuesta incluye fuentes, fórmula, corte, periodo y parámetros de drill-down.
