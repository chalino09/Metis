# Cierre Módulo 3B — Órdenes de compra y Aprobación

Fecha: 2026-07-16  
Decisión: **GO**

## Volumen y estrategia

El alcance real es 84 órdenes de compra y 731 partidas. Las 84 OC reportan aprobación `Aceptada`. La promoción es server-side, transaccional por páginas de hasta 100 OC, idempotente y auditada; no existe captura registro por registro. Las identidades Alpha permanecen en staging y referencias externas, nunca en la cabecera o partidas canónicas.

Cada OC requiere proveedor canónico, moneda ISO, al menos una partida válida y producto canónico resoluble para la promoción histórica. Los casos no resolubles pasan a `purchase_order_import_exceptions` sin crear una OC parcial. El folio canónico se genera en servidor y es único por empresa.

## Criterios aceptados

- entidad canónica de OC y partidas con aislamiento por empresa;
- flujo Borrador → Pendiente de aprobación → Aprobada o Rechazada;
- cancelación separada, sólo por permiso, con motivo, actor y fecha;
- proveedor y partidas inmutables después del envío/aprobación; una aprobada sólo puede cancelarse;
- subtotales, descuentos sucesivos de partida, descuento general y total calculados server-side;
- catálogo con búsqueda, filtros, estado, origen y paginación server-side;
- detalle con partidas e historial de envío, aprobación, rechazo y cancelación;
- permisos separados para consultar, crear, editar, enviar, aprobar, rechazar, cancelar y promover;
- promoción histórica paginada, idempotente y auditada;
- cero recepciones, movimientos/cambios de inventario, costos, facturas, CxP o pagos.

## Auditoría de M3A y resolución real

M3A conservaba dos excepciones por RFC duplicado que sí participan en siete OC:

- clave Alpha 36, `SOLUCIONES EN NUTRIENTES DE VALOR AGREGADO`: 6 OC;
- clave Alpha 37, `SOLUCIONES EN NUTRIENTES DE VALOR AGREGADO DÓLAR`: 1 OC.

Ambas filas tienen el mismo RFC y proveedor legal; “DÓLAR” distingue una cuenta fuente, no una identidad canónica distinta. La auditoría encontró que la segunda excepción no refrescaba candidatos después de resolver la primera. `202607160007_supplier_exception_candidate_refresh.sql` corrige la bandeja y permite vincular explícitamente por RFC/identidad vigente dentro de la misma empresa, con motivo y auditoría. No hay resolución automática ni proveedor duplicado.

La validación real crea una sola identidad canónica para la primera clave y vincula la segunda a esa misma identidad mediante el procedimiento auditado de M3A. Resultado de 3B:

- fuente: 84 OC / 731 partidas;
- promovidas: 84 OC / 731 partidas;
- excepciones de OC: 0;
- estado canónico: 84 aprobadas;
- origen: 84 `imported_historical`;
- referencias externas: 84, sin claves Alpha en el dominio;
- segundo intento: `already_promoted`, sin duplicados.

Las 731 partidas también se contrastaron contra `cata_prd` real; todos sus SKU resolvieron a producto canónico en la validación.

## Permisos

| Acción | Permiso |
| --- | --- |
| Consultar | `view_purchase_orders` |
| Crear | `create_purchase_orders` |
| Editar | `edit_purchase_orders` |
| Enviar | `submit_purchase_orders` |
| Aprobar | `approve_purchase_orders` |
| Rechazar | `reject_purchase_orders` |
| Cancelar | `cancel_purchase_orders` |
| Promover staging | `promote_purchase_orders` |

Super Admin y Dirección/Admin General reciben estos permisos. Los roles operativos no los reciben sin una regla de negocio comprobada. No se introdujeron montos ni niveles de aprobación inventados.

## Evidencia

- Suite final completa: `docs/validation/evidence/20260716T161842Z/summary.txt` — 35 PASS, 0 FAIL.
- SQL 3B: `202607160006_purchase_orders_and_approval.log`.
- Promoción real: `real-alpha-purchase-order-promotion.log`.
- Pruebas frontend: 24/24.
- Lint y build de producción: aprobados.
- Regresiones M1, M2 y M3A, RLS, permisos, transacciones, concurrencia e importaciones: aprobadas.
- La marca histórica `missing_separate_fiscal_source` corresponde al readiness fiscal de Productos y no afecta el dominio ni la promoción de 3B.

### Revalidación final posterior a los ajustes de interfaz

- SQL transaccional M3B: PASS; creación y edición de borrador, envío, aprobación, rechazo, cancelación, bloqueo de cambios, totales server-side, auditoría, permisos, RLS e idempotencia. La prueba terminó en `ROLLBACK`.
- Alpha real: 84/84 OC y 731/731 partidas promovibles, 0 excepciones, 84 aprobadas, segundo intento idempotente.
- No afectación Alpha: inventario 0, costos 0, recepciones 0 y CxP 0.
- Regresiones seleccionadas: RLS base, venta transaccional, seguridad de POS, maestro de proveedores y reparación de proveedores — 5/5 PASS.
- Frontend e importación: 24/24 PASS; lint, TypeScript y build de producción aprobados.
- Smoke UI: catálogo con 84 resultados, búsqueda de proveedor canónico, monedas MXN/USD, calendario propio y captura de partidas verificados. La prueba visual se cerró sin guardar una OC ficticia.
- UAT autenticado dentro de la app: `OC-2026-000085`, referencia `UAT-M3B-20260716`, dos partidas, subtotal `$260.00`, descuento `$20.00` y total server-side `$240.00`. Se creó como borrador, se editó, se envió, se aprobó y se canceló. El catálogo la muestra como `Cancelada` y el historial conserva actor, fecha y motivo de las tres decisiones. La OC está marcada `PRUEBA CONTROLADA — NO SURTIR` y no se elimina para preservar la auditoría.

## No afectación y límites

La prueba toma conteos antes/después y confirma:

- inventario: 0 cambios;
- costos: 0 cambios;
- recepciones: 0 creadas;
- CxP/facturas: 0 creadas;
- pagos: 0 creados.

No se implementó recepción, inventario/costo, factura, CxP ni pago. Esos flujos continúan fuera de 3B; Recepción corresponde a M3C.

## Pendientes

No quedan pendientes funcionales para cerrar M3B en el entorno validado. En cualquier entorno adicional todavía se deben aplicar las dos migraciones, resolver de forma auditada cualquier excepción de proveedor y ejecutar la promoción desde Auditoría de importaciones antes de declarar su propio GO.

La promoción de cierre se ejecutó dentro de `BEGIN/ROLLBACK` para demostrar conteos e idempotencia sin alterar el entorno durante la validación.
