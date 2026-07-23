# GO/NO-GO final — bloqueos de datos de Módulos 1 y 2

Fecha de ejecución: 2026-07-15  
Corte Alpha: 2026-07-07/08  
Dictamen: **GO para iniciar el Módulo 3**

El GO cubre la compuerta de datos pendiente. No se reabrió ni modificó la arquitectura previamente validada. Las diferencias remanentes están identificadas, conciliadas y fuera de la operación POS por reglas existentes de readiness o por cuarentena de importación; no queda un P0/P1 abierto.

## Cierres realizados

- Fuente fiscal separada: importados 1,502 productos desde `3.1 PRODUCTOS.xls`; 482 con IVA 16% y 1,020 con IVA 0%. La fuente fiscal se aplicó antes del catálogo base para conservar impuestos y restaurar después los atributos canónicos del producto.
- Listas de precios: aprobados los mapeos `ALPHA_LIST_1 → primera` (predeterminada), `ALPHA_LIST_2 → segunda`, `ALPHA_LIST_3 → tercera` y `ALPHA_LIST_4 → top`.
- Moneda: aprobado `PESOS → MXN` para precios y costos.
- Precios: conciliadas 2,251 filas válidas. Los faltantes no se inventaron y permanecen fuera de readiness.
- Costos: conciliados 1,665 costos reales. Los cinco faltantes corresponden a activos o servicios sin inventario operativo.
- Inventario: confirmadas 2,238 filas operativas. Las 2 unidades legacy de `HO38808` en CUAPA quedaron en cuarentena porque el producto está marcado como eliminado.

## Readiness recalculado con datos reales

| Resultado | Cantidad |
|---|---:|
| Productos del catálogo | 1,670 |
| Ready | 1,501 |
| Pendientes/bloqueados | 169 |
| Sin configuración fiscal | 168 |
| Sin precio vendible | 6 |
| Sin costo | 5 |

Los 169 pendientes son 168 productos sin registro fiscal y `HO38808`, que sí tiene fiscalidad pero está inactivo/eliminado. Los faltantes de precio y costo son subconjuntos de productos ya excluidos de la operación; no aumentan el total bloqueado.

## Jornada end-to-end

La jornada se ejecutó dentro de una transacción contra el esquema migrado y se revirtió al terminar para no contaminar el entorno de validación.

| Control | Evidencia |
|---|---|
| Apertura | MXN 100.00 |
| Producto real | `MS63533` |
| Venta de contado | MXN 360.00 |
| Efectivo recibido / cambio | MXN 400.00 / MXN 40.00 |
| Inventario | disminución exacta de 1 unidad |
| Ticket canónico | uno, folio `0000000001` |
| Cierre y arqueo | MXN 460.00 esperado y contado |
| Diferencia | MXN 0.00 |

También pasaron las 15 pruebas automatizadas de importación/frontend, lint y build de producción.

## Diferencias pendientes no bloqueantes

- 168 productos sin fuente fiscal: 122 productos terminados, 39 servicios, 2 activos y 5 eliminados. De los 122 terminados, 65 tienen existencia. Todos continúan bloqueados por readiness hasta que la fuente fiscal entregue su configuración.
- 47 productos no tienen ninguna fila de precio: 39 servicios, 2 activos y 6 productos terminados (`SEM000A3` a `SEM000A8`). Sólo `SEM000A3` tiene existencia; los seis están además bloqueados por falta fiscal.
- Cinco registros no tienen costo: `AF-01`, `CPU_01`, `GTO GEN_27`, `GTOS GEN_ 22` y `GTOS GEN_23`. Son activos/servicios sin impacto en inventario vendible.
- `HO38808`: 2 unidades legacy en CUAPA, producto eliminado. La cantidad se conserva como diferencia conciliable y no fue incorporada al inventario operativo.

Estas diferencias deben mantenerse en seguimiento de calidad de datos y no deben habilitarse manualmente. Una nueva entrega fiscal o comercial debe volver a ejecutar `npm run test:go-data` antes de incorporar esos SKU al surtido operativo.

## Evidencia versionada

- Resumen del dictamen: `docs/validation/evidence/20260715T183714Z-go-data/summary.txt`
- Ejecución SQL y jornada real: `docs/validation/evidence/20260715T183714Z-go-data/real-data-go.log`
- Pruebas: `docs/validation/evidence/20260715T183714Z-go-data/frontend-tests.log`
- Lint y build: `docs/validation/evidence/20260715T183714Z-go-data/lint.log` y `build.log`
- Hashes de entradas reales: `docs/validation/evidence/20260715T183714Z-go-data/source-sha256.txt`
- Mapeos aprobados: `config/alpha-commercial-mappings-20260708.json`

## Decisión

**GO.** Los bloqueos de datos P0/P1 quedaron cerrados mediante importación fiscal separada, mapeos comerciales aprobados, conciliación explícita y exclusión segura de diferencias. La jornada real confirmó el flujo completo de apertura, venta, inventario, ticket, cierre y arqueo sin diferencia monetaria.
