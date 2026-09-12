# Contrato de BI operativo

`GET /api/bi/operations` compone lecturas server-side existentes con el JWT del usuario. Parámetros obligatorios: `company_id`, `date_from`, `date_to`. Parámetros opcionales: `location_id`, `page` y `page_size` (máximo 50).

La respuesta está versionada como `satrapy.bi.operations@1.0.0` y contiene:

- `period`: periodo solicitado y periodo anterior comparable.
- `locations.items`: ventas netas, tickets y margen bruto por sucursal. Cada margen conserva `gross_margin_quality` y su razón cuando el costo reconocido está incompleto. `profitability` incluye la respuesta de `get_location_profitability` sólo para la primera página acotada (`profitability_page_size`, máximo 10; por defecto 5), respetando `view_location_profitability`.
- `inventory`: `positions` muestra existencias exactas por producto/ubicación en una página server-side; `value` es el valor monetario publicado por el resumen canónico. `replenishment` lista faltantes derivados de políticas mínimas/máximas.
- `receivables`: CxC y vencido reconstruidos al `date_to` a partir de documentos, aplicaciones y reversas que puede observar el RPC canónico.
- `supplier_signals.items`: importe de compras observado o comprometido en la red de dependencias; el contrato no lo llama deterioro de proveedor. `truncated` informa el límite server-side.
- `quality`, `trace`: disponibilidad de cada fuente, cobertura parcial y RPCs usados.

El inventario declara por separado `valuation_as_of` y `replenishment_as_of`, ambos como el instante actual de consulta (`current_at_query_time`), y no se interpreta como inventario histórico. Cuando el `date_to` solicitado no coincide con el día UTC actual, `valuation_source_period` identifica una segunda lectura acotada al día actual; ventas, margen y CxC conservan el periodo solicitado. `positions` mantiene las cantidades por producto y unidad; no se suman cantidades entre productos con unidades distintas. La CxC se reconstruye al `date_to`. El endpoint rechaza filtros de producto, cliente o proveedor porque no son comparables con este alcance. Si el usuario no tiene el permiso específico de un RPC compuesto, ese bloque devuelve `available: false` con una razón normalizada; el endpoint sólo falla completo cuando `bi_get_executive_summary_compared` no está disponible para el periodo principal, porque es la base común de BI.

Fuentes: `bi_get_executive_summary_compared`, `bi_get_operational_table`, `get_location_profitability`, `search_inventory_balances`, `list_inventory_replenishment_work_queue` y `bi_dependency_network_query`. No usa service role ni lecturas directas de tablas desde la ruta.
