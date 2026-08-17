# BI Fase 5 final · contrato compartido de métricas

## Auditoría previa e inconsistencias

La auditoría de Fases 0–4 encontró un motor analítico server-side reutilizable (`bi_explorer_query`, resumen comparado, investigación, tablas y alertas), con empresa, permisos y ubicación revalidados en RPC. La inconsistencia estaba en los metadatos: `BiModule.tsx` repetía nombres, fórmulas, fuentes y compatibilidades; el catálogo no declaraba versión, semántica de cero/nulo/parcial ni límites; alertas sólo conservaban la versión de regla; exportaciones omitían versión y RPC responsable. Tampoco existía una entrada estructurada, exclusivamente de lectura, para agents.

No se modificó el Centro de migración ni se reprocesaron históricos. No se añadieron índices: los recorridos principales ya agregan y paginan en servidor, y no hubo evidencia de un patrón nuevo que justificara escritura física.

## Fuente de verdad y catálogo

`bi_get_metric_catalog(company_id)` es el catálogo humano y máquina. Amplía cada métrica existente con `metric_id`, descripción, fórmula, unidad/formato, dirección favorable, dimensiones/filtros, granularidades, comparaciones, disponibilidad, requisitos, semántica de valores, versión `1.0.0`, RPC responsable, fecha, trazabilidad y ejemplo válido. La disponibilidad continúa calculándose por empresa y permisos; no es documentación estática.

Una métrica no está terminada hasta ser reconciliable en resumen, investigación, tabla, alerta, exportación y consulta estructurada. No existen métricas exclusivas para agents.

## Flujo humano–agent

Las pantallas, vistas, tableros y exportaciones continúan consultando `bi_explorer_query` y RPC especializados. `POST /api/bi/metrics/query` valida el sobre y llama `bi_query_metric`; PostgreSQL valida otra vez y delega a `bi_explorer_query`. `GET /api/bi/metrics/catalog?company_id=…` expone el mismo catálogo gobernado.

Entrada permitida: `metric_id`, `period.from/to`, `comparison`, `granularity`, una dimensión, filtros allowlisted, orden estable, página y límite. Máximos: 366 días, una dimensión, 100 filas por página y 16 KiB HTTP. Sólo se admite `group_label_asc`; combinaciones incompatibles se rechazan. No hay parámetro SQL, código, prompt ni acceso directo a tablas.

La respuesta contiene contrato/versión, periodo y comparación efectivos, filtros, valor/serie/desglose, unidad, disponibilidad, calidad, faltantes, fuente, timestamp, traza, semántica del signo y siguiente dimensión. `causal_inference=false` separa hechos de inferencias.

## Autorización, aislamiento y observabilidad

Los endpoints requieren JWT. Los RPC `security definer` vuelven a exigir `view_bi`; el motor conserva `can_access_location` y empresa. Los mensajes HTTP de autorización se normalizan para no revelar IDs. Las respuestas usan `private, no-store` y `Vary: authorization`.

Cada consulta agent registra en `audit_log`: empresa, actor, `metric_id`, versión, tipo, periodo, granularidad, duración, filas, estado y cache miss. Los fallos guardan sólo `invalid_or_unauthorized`; nunca prompts ni payloads completos.

## Alertas, drill-down y exportaciones

`bi_alert_rules` y `bi_alerts` conservan `metric_contract_version`; la regla mantiene además su versión propia. El drawer y la investigación reciben fórmula/fuente de RPC canónico. CSV/XLSX/PDF reciben la métrica desde catálogo; CSV declara `metric_id`, versión, filtros y RPC. El drill-down se deriva de dimensiones compatibles y termina en RPC paginado.

## Rendimiento y límites conocidos

Presupuesto: catálogo < 300 ms; consulta p95 < 2 s para 90 días y < 5 s para 366 días; página ≤ 100 agregados; exportación ≤ 50,000 agregados. No hay cache compartido porque disponibilidad depende de empresa, ubicación y permisos. Exportaciones reutilizan páginas de 100 y rechazan exceso antes de descargar todo.

La consulta agent publicada soporta `none` y `previous_period`; `previous_year` queda fuera hasta tener idéntica semántica en todo el explorador. La granularidad publicada es `total`; día, semana y mes se rechazan hasta que el motor los materialice de forma uniforme para todas las superficies.

## Agregar o modificar una métrica

1. Probar el caso de negocio y elegir un RPC canónico; nunca añadir la fórmula al frontend.
2. Actualizar `bi_get_metric_catalog` y elevar `contract_version` si cambia significado, fuente, unidad o nulabilidad.
3. Declarar dimensiones, filtros, granularidad, comparación, disponibilidad y semántica cero/nulo/parcial.
4. Validar RLS, empresa, ubicación, fechas, cardinalidad, página estable y rango largo.
5. Probar paridad en resumen, investigación, tabla, alerta, exportación y endpoint estructurado; si una superficie no aplica, declararlo y rechazarla.
6. Ejecutar lint, tipos, pruebas TypeScript/SQL y build; validar con sesión autenticada en escritorio ≥ 1180 × 700 CSS.
