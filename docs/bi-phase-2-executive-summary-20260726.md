# BI de Satrapy · Fase 2: Resumen Ejecutivo avanzado

Fecha: 2026-07-26

## Alcance entregado

La Fase 2 amplía el Resumen ejecutivo; no activa el Explorador libre, tableros, vistas guardadas, exportaciones ni la red de dependencias.

- Comparaciones server-side alineadas contra un periodo anterior de la misma duración.
- Seis superficies visuales: ventas, margen, flujo bancario, CxC, CxP e inventario.
- Drill-down paginado desde KPI, barra o punto de serie.
- Persistencia de periodo y ubicación en la URL durante la navegación interna de BI.
- Tooltips con fórmula, fuente, periodo y actualización.
- Estados separados de carga, error total, vacío, parcial y métrica no disponible.

## Fórmulas y fuentes

| Visualización | Naturaleza | Fórmula | Fuente canónica | Limitación |
| --- | --- | --- | --- | --- |
| Ventas devengadas | Devengada | Σ subtotal − descuentos; con producto usa el importe gravable de sus partidas | `sales`, `sale_items`, `sale_cancellations` | Excluye impuestos y ventas canceladas. |
| Margen bruto | Devengada | Ventas netas − costo reconocido de las partidas vendidas | Pendiente de fuente probatoria | **No disponible:** `sale_items` no conserva costo reconocido por partida y fecha. |
| Flujo bancario neto | Efectiva | Σ créditos − Σ débitos | `bank_transactions` | No se atribuye a ubicación/producto/cliente/proveedor sin conciliación comprobada. No combina caja con bancos. |
| CxC al corte | Devengada/posición | Documento original − aplicaciones efectivas, considerando reversiones y cancelaciones hasta el corte | `customer_receivables`, aplicaciones, pagos y reversiones | La ubicación se deriva de la venta origen. Proveedor no aplica. |
| CxP al corte | Devengada/posición | Factura en moneda base − notas de crédito − pagos efectivos hasta el corte | `canonical_accounting_auxiliaries`; con proveedor, documentos y aplicaciones fechadas | Ubicación, producto y cliente no se atribuyen sin relación única. |
| Inventario valorizado | Operativa/posición | Σ movimientos hasta el corte × costo aprobado vigente al corte | `inventory_ledger`, `product_costs`, matriz contable aprobada | Si algún saldo carece de costo actual o comparable, la métrica completa queda no disponible. |

## Comparación

Para cada KPI con base comparable:

- diferencia absoluta = valor actual − valor anterior;
- variación porcentual = diferencia absoluta ÷ valor absoluto anterior × 100;
- si el valor anterior es cero, la diferencia absoluta se muestra y el porcentaje se declara sin base;
- si no existe reconstrucción o cobertura suficiente, no se sustituye con cero.

El periodo anterior termina un día antes del periodo actual y conserva exactamente la misma cantidad de días.

## Seguridad y volumen

- Las RPC requieren sesión y `view_bi`.
- Empresa y UUID de dimensiones se validan server-side.
- Toda ubicación pasa por `can_access_location`.
- Series limitadas a 366 días.
- Los detalles aceptan como máximo 100 filas por página.
- Las consultas quedan auditadas en `audit_log`.
- El navegador sólo recibe agregados y páginas de detalle.

## Limitaciones reales

- Margen bruto histórico permanece bloqueado.
- Nómina sigue sin moneda canónica en la corrida.
- Flujo bancario no equivale a utilidad ni integra automáticamente movimientos de caja.
- Un filtro no atribuible vuelve la métrica no disponible; no produce un cero engañoso.
- La extensión visual muestra estado parcial mientras la migración de Fase 2 no haya sido aplicada a la base.

## Pendiente para Fase 3

- Explorador transversal libre con combinaciones compatibles.
- Tableros configurables y vistas guardadas.
- Exportaciones XLSX/CSV/PDF.
- Force-Directed Graph y expansión de subredes.
