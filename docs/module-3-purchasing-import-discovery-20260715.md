# Descubrimiento de importación — Módulo 3

Fecha de corte Alpha: 2026-07-08

## Flujo confirmado

`Proveedor → Orden de compra → Aprobación → Recepción → Inventario/costo → Factura → CxP → Pago`

Los Excel confirman directamente proveedor, orden, aprobación, documentos abiertos de CxP y evidencia de pagos. La recepción permanece en el centro del flujo operativo nuevo, pero no puede reconstruirse históricamente con la entrega actual.

`rep_mov` contiene movimientos de inventario con producto, ubicación, tipo, fecha y costo, pero no una llave inequívoca de orden de compra, proveedor y recepción. Por lo tanto, Satrapy no crea recepciones históricas ni las vincula por inferencia.

## Fuentes verificadas

| Fuente | Uso de staging | Volumen real |
| --- | --- | ---: |
| `cata_prv` | Proveedores y acreedores | 119 |
| `rpcon2` | Órdenes de compra | 84 |
| `rpcon2` | Partidas de orden | 731 |
| `lfchvenc` | Documentos abiertos de CxP | 62 |
| `pag_det` | Aplicaciones históricas de pago, solo evidencia | 2,220 |

Saldo neto abierto reportado por `lfchvenc`: MXN 9,999,955.47. Pagos históricos reportados por `pag_det`: MXN 28,161,765.19.

Las 84 órdenes están aprobadas en Alpha: 71 por surtir, 3 parciales y 10 surtidas. Todas están expresadas en PESOS.

## Diferencias conservadas

- 333 aplicaciones de pago identifican al proveedor solo por nombre y no tienen una identidad Alpha canónica resoluble de forma única. Permanecen como evidencia y no generan pagos.
- Dos documentos presentan saldo acreedor: proveedor 43, folio 35, por MXN -6,266.65; proveedor 44, folio 37, por MXN -4,651.31. Se conservan hasta confirmar si son créditos o anticipos.
- No existe una fuente de recepción vinculable a OC. Esta diferencia bloquea únicamente la reconstrucción histórica de recepciones, no el staging de las demás fuentes.

## Integración de staging implementada

- Detección automática de `cata_prv`, `rpcon2`, `lfchvenc` y `pag_det` en el Centro de Migración.
- Agrupación por fecha de corte y hash de contenido.
- Parser XLS/XLSX con validación cruzada de proveedores, órdenes, partidas, moneda, CxP y pagos.
- Persistencia server-side por bloques de 400 filas.
- Staging aislado por empresa con RLS, idempotencia de paquete y auditoría.
- Listado paginado de paquetes y resumen en la interfaz.
- Contrato explícito `operational_import_ready=false`: el staging no crea recepciones, inventario, CxP ni pagos.

La promoción del maestro de proveedores se implementó posteriormente en 3A. Sólo `cata_prv` puede promoverse a identidad canónica; las otras tres fuentes permanecen como evidencia para 3B y módulos posteriores.

## Volumen y flujo manual

La carga prevista es masiva: 3,216 registros normalizados en el corte actual. No debe capturarse registro por registro.

Las 333 identidades de pago no resueltas tampoco deben convertirse en una bandeja de captura manual sin medir primero recurrencia, criticidad y SLA. Para la migración actual quedan como evidencia; cualquier flujo de resolución deberá ser agrupado por proveedor normalizado y operado por lote.
