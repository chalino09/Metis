# Retest UAT — cierre de P0 de POS y CxC

Fecha: 2026-07-15  
Entorno: UAT remota, misma sesión de usuario y caja  
Resultado: **PASS en ambos flujos**

## Correcciones acotadas

La migración `202607150010_close_uat_pos_and_receivable_p0.sql` hizo únicamente dos cambios:

1. Agregó `extensions` al `search_path` de `complete_sale`, para resolver `pgcrypto.digest` al crear el ticket canónico.
2. Persistió el mapeo comercial ya aprobado `ALPHA_LIST_1 → primera`, `PESOS → MXN` como lista predeterminada de la empresa, dando autoridad de moneda a los documentos migrados de CxC.

El despliegue en seco indicó que sólo se aplicaría `202607150010`; después se aplicó esa única migración en UAT.

## Venta POS de MXN 15

- Producto: `RI23545`, ABRAZADERA LEGION ECO N°8 (13-23 MM) 1/2".
- Cantidad: 1 PZA.
- Subtotal: MXN 12.93.
- IVA: MXN 2.07.
- Total y efectivo recibido: MXN 15.00.
- Resultado: venta confirmada y carrito vacío.
- Ticket canónico: `0000000001`, una sola partida y total MXN 15.00.
- Historial posterior: exactamente 1 venta por MXN 15.00.

La confirmación se activó dos veces de forma controlada. El resultado fue una sola venta y un solo ticket, comprobando la protección idempotente en el flujo real.

## Inventario

La venta confirmó una salida transaccional de 1 unidad para `RI23545`. La suite SQL `202607130004_pos_sales_transaction` valida en la misma función atómica la disminución del balance, la venta y el ticket; `concurrency_sales` confirma que los reintentos no duplican la salida.

La pantalla “Inventario por ubicación” muestra la fotografía importada del 7 de julio (`inventory_snapshot_items`), no el balance transaccional posterior. Por ello conserva 18 PZA en CUAPA como valor del archivo fuente; no se utilizó esa fotografía como prueba del saldo posterior.

## Abono de MXN 1

- Cliente: INVERNADERO ZOYATITLA ( 1 ), código `851`.
- Referencia: `PRUEBA CODEX 2026-07-15`.
- Forma de pago: efectivo.
- Saldo del cliente: MXN 232,363.60 → MXN 232,362.60.
- Saldo total de CxC: MXN 3,237,365.44 → MXN 3,237,364.44.
- Aplicación FIFO: documento `71`, MXN 6,980.00 → MXN 6,979.00.
- Recibo canónico: `RCB-0000000001`, total MXN 1.00.

La confirmación también se activó dos veces de forma controlada. Persistieron un solo abono, una sola aplicación FIFO, un solo movimiento de caja y un solo recibo.

## Caja

- Venta de contado: MXN 15.00.
- Movimiento `receivable_payment`: MXN 1.00.
- Efectivo esperado: MXN 16.00.
- El historial del turno muestra exactamente esos dos movimientos.

## Verificación técnica

- Reconstrucción local con todas las migraciones: PASS.
- Prueba específica `202607150010_uat_p0_closure`: PASS.
- Suite SQL/RLS/transaccional/concurrencia: 22 PASS, 0 FAIL.
- Pruebas frontend: 15 PASS, incluyendo reutilización de clave mientras la huella de operación no cambia.
- Lint: PASS.
- Build de producción: PASS.

## Dictamen

**PASS POS y PASS abono. GO de la compuerta P0 para Módulo 3.** Los dos errores observados en UAT quedaron corregidos y no reaparecieron al repetir exactamente los importes y la sesión solicitados.
