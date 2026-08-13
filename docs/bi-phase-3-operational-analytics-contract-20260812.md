# BI — Fase 3: tablas analíticas operativas

## Auditoría de Fases 0–2

- La base visual de Fase 0 ya aporta tokens BI, `AnalyticsTable`, estados remotos y el drawer Radix. Fase 3 amplía esos componentes locales; no agrega una librería de tablas ni un sistema visual paralelo.
- El resumen de Fase 1 conserva periodo, comparación equivalente, ubicación, producto, cliente, proveedor y alcance empresarial. La tabla recibe ese contexto aplicado y no repite los controles globales.
- El drawer de Fase 2 ya conserva `BiInvestigationContext`, contribuciones, breadcrumbs y registros paginados. La acción **Revisar** construye el mismo contexto y continúa por sucursal → categoría → producto → registros.
- `bi_explorer_query` es la capa canónica para fórmulas, permisos, alcance, moneda, granularidad y agregación. `bi_get_operational_table` reutiliza su resultado materializado y sólo añade búsqueda, prioridad, ranking y página sobre agregados.
- El exportador existente ya genera archivos en servidor, registra jobs y limita el volumen. Fase 3 añade el target auditable `operational_table` y conserva exactamente dimensión, búsqueda, orden y filtros.

## Dimensiones y métricas publicadas

| Dimensión | Métricas | Motivo |
| --- | --- | --- |
| Sucursal | Ventas netas, margen bruto, tickets | Son aditivas por ubicación y tienen recorrido comprobado al drawer. |
| Categoría | Ventas netas, margen bruto | Se agregan desde partidas con categoría canónica, sin multiplicar encabezados. |
| Producto | Ventas netas, margen bruto | Se agregan desde partidas canónicas y llegan a registros de respaldo. |
| Vendedor | No publicada | Una venta no conserva una relación canónica y única con vendedor. Cajero o responsable no sustituyen esa identidad. |

Margen sólo aparece cuando existe permiso `view_costs`. Un agregado con partidas sin costo reconocido se devuelve como dato parcial, sin estimación. Tickets no aparece por categoría o producto porque un ticket multiproducto dejaría de reconciliar.

## Volumen y paginación

| Tabla | Volumen operativo esperado por empresa | Estrategia |
| --- | --- | --- |
| Sucursales | 1–500 agregados | Offset server-side, 25 filas por página, máximo 100 por solicitud. |
| Categorías | 10–2,000 agregados | Offset server-side, búsqueda server-side y páginas de 25. |
| Productos | 1,000–50,000 agregados | Búsqueda server-side con debounce de 320 ms y páginas de 25. |

El navegador nunca descarga transacciones ni renderiza miles de filas. La exportación recorre páginas de 100 agregados en servidor y rechaza más de 50,000 filas. No se añadió virtualización porque la página de 25 resuelve el volumen visible.

## Orden y semántica

- Atención inicia con la variación más negativa.
- Oportunidad ordena por contribución positiva.
- Participación ordena por porcentaje del total.
- Los encabezados permiten ordenar en servidor mediante una allowlist: entidad, actual, anterior, variación absoluta, variación porcentual, participación y contribución.
- Ranking corresponde al orden activo después de la búsqueda.
- Valor anterior cero devuelve `previous_zero`: se muestra “Base anterior en cero” y nunca se calcula un porcentaje infinito.
- Margen incompleto devuelve `partial`; valores faltantes no se convierten en cero. Mejora, deterioro, neutro, parcial y no disponible se comunican con texto además de tono.

## Consistencia y trazabilidad

Resumen, gráficas, drawer y tablas usan las mismas métricas del catálogo y las mismas fórmulas de `bi_explorer_query`. La tabla devuelve actual, anterior, variación, participación y contribución calculadas en PostgreSQL. Cada consulta registra `bi.operational_table_queried`; cada exportación registra `bi.operational_export_requested` y termina por el flujo existente `bi_finish_export`.

No se añadieron índices: la consulta reutiliza los índices de hechos y dimensiones ya usados y optimizados por el Explorador y los históricos. La prueba representativa cubre 120 productos, 12 categorías, 3 sucursales, periodos corto y largo, búsqueda, orden, tope de página, parcialidad y exportación.

## Límites para Fase 4

- No hay vendedor hasta definir una atribución única, canónica y auditada.
- “Sin categoría” permanece visible, pero no continúa a producto porque no existe una categoría canónica que heredar; no se abre evidencia con un contexto más amplio e incorrecto.
- No se crean alertas persistentes, acciones masivas, pivots, edición, chat ni reglas automáticas.
- La exportación operativa ofrece CSV en la interfaz; el backend y el formateador también admiten XLSX. PDF permanece reservado a reportes y tableros porque no reproduce con fidelidad tablas operativas grandes.
