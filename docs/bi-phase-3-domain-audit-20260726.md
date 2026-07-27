# BI de Satrapy · Auditoría de dominio para Fase 3

Fecha: 2026-07-26

## Decisión arquitectónica

El Explorador usa el mismo permiso `view_bi`, los UUID canónicos, `can_access_location`,
la moneda base aprobada, los filtros paginados y el drill-down de las fases 1 y 2.
No crea un almacén paralelo ni descarga hechos al navegador. El catálogo, la validación
de compatibilidad, las agregaciones, comparaciones, orden y paginación viven en RPC.

## Fuentes comprobadas

| Módulo | Fuente canónica comprobada | Métricas publicables |
| --- | --- | --- |
| Ventas | `sales`, `sale_items`, cancelaciones | ventas netas, tickets |
| Margen | venta sin snapshot de costo reconocido | ninguna; margen bruto bloqueado |
| Caja | `cash_movements` → `cash_sessions` | flujo neto de caja |
| CxC | documentos, aplicaciones, cobros y reversiones | cobranza, saldo al corte |
| CxP | facturas, notas, aplicaciones y pagos | pagos, saldo al corte |
| Compras | facturas y partidas confirmadas ligadas a recepción | compras devengadas, cantidad recibida facturada |
| Inventario | `inventory_ledger`, costos vigentes aprobados | existencia, valor al corte |
| Bancos | transacciones promovidas | flujo bancario neto |
| Contabilidad | pólizas y líneas contabilizadas | débitos contabilizados |
| Nómina | periodos y líneas, sin moneda | corridas aprobadas (conteo); importes bloqueados |

## Incompatibilidades encontradas

- Compartir una fecha no prueba compatibilidad. Movimientos diarios no se mezclan con
  posiciones al corte ni con periodos de nómina.
- Tickets no se agrupan por producto o categoría: un ticket con varias partidas
  aparecería en varios grupos y la suma dejaría de reconciliar.
- Cobranza se agrupa por cliente. No se reparte entre productos ni ubicaciones cuando
  una aplicación cubre documentos de más de una operación.
- CxC se atribuye a cliente y a la ubicación única de su venta origen, pero no se
  distribuye entre productos.
- CxP se atribuye a proveedor. Una factura puede cubrir varias recepciones y no se
  reparte a ubicación/producto para representar el saldo.
- Pagos a proveedor no se atribuyen a ubicación o producto.
- Bancos sólo se agrupa por cuenta financiera. Una fecha o una conciliación candidata
  no autoriza atribuir el movimiento a ubicación, cliente, proveedor o producto.
- Compras devengadas se agregan desde partidas de factura confirmada. La ubicación se
  obtiene de la recepción única de cada partida, evitando cruzar el encabezado con
  todas sus recepciones.
- Inventario es una posición: se reconstruye con el ledger al corte y no se suma entre
  días como si fuera movimiento.
- Porcentajes, saldos y existencias no usan agregación aditiva temporal.
- Margen bruto histórico continúa bloqueado: `sale_items` no conserva el costo
  reconocido por partida y fecha.
- Nómina monetaria continúa bloqueada: la corrida no conserva moneda canónica.
- Contabilidad disponible sólo representa débitos de pólizas contabilizadas; no se
  presenta como ingreso, gasto o utilidad porque el catálogo actual no prueba esa
  clasificación transversal.

## Contrato de comparación

- Flujos: periodo diario o mensual, con periodo anterior de igual duración.
- Posiciones: corte actual contra el último día del periodo anterior.
- Una consulta admite hasta cuatro métricas.
- Varias métricas requieren la misma familia de granularidad, una dimensión común y
  la misma unidad. Dispersión requiere exactamente dos métricas numéricas.
- Línea y área sólo se habilitan para periodo; barras para cualquier dimensión
  categórica compatible; dispersión para dos métricas con grupos comunes.
- La gráfica recibe como máximo 120 agregados; la tabla se pagina a 100 filas como
  máximo por solicitud.
