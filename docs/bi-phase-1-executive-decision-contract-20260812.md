# BI — Fase 1: resumen ejecutivo orientado a decisiones

## Propósito

El resumen ejecutivo prioriza una decisión inmediata: primero muestra señales que
requieren revisión, después el indicador protagonista y sus tres métricas de
contexto, y finalmente tendencia y operación por ubicación. No modifica las
fórmulas ni las definiciones de BI existentes.

## Contrato visual

- **Señales del periodo:** hasta tres señales deterministas, derivadas de datos
  ya calculados. Rojo comunica cobros vencidos; ámbar, una caída o meta en riesgo.
  No son alertas persistentes ni reglas nuevas de negocio.
- **KPIs:** ventas netas ocupa la posición protagonista. Las tarjetas normales
  utilizan la superficie y el borde de los tokens de BI; sus cifras usan dígitos
  tabulares y alineación numérica. Las métricas restantes se revelan de forma
  progresiva en un `details` nativo.
- **Tendencia y operación:** la serie compara periodo actual contra equivalente
  anterior. El ranking de ubicaciones tiene la misma semántica y una tabla
  accesible; sus acciones abren el detalle transaccional existente.
- **Interacción:** el periodo de la serie y una ubicación se pueden investigar
  con controles nativos de teclado. La animación de gráficas queda desactivada.

## Datos y contrato de backend

`bi_get_executive_charts` mantiene su firma y payload anterior y ahora añade
`operational_rows` cuando la dimensión de ubicación es válida para el filtro
aplicado. Cada fila contiene el valor actual, el anterior, la participación y
un estado (`declining`, `stable` o `new`). El cálculo se realiza en PostgreSQL,
se limita a 12 ubicaciones y deja una entrada de auditoría
`bi.executive_operational_summary_queried`.

La migración conserva las fórmulas vigentes de ventas netas y el control de
acceso de la función previa. No crea tablas, SQL de captura ni métricas nuevas.

## Filtros disponibles

El resumen conserva periodo, comparación, ubicación, producto, cliente y
proveedor. La barra muestra los filtros activos como chips y conserva los
controles de aplicar, descartar y restablecer.

Categoría y vendedor no se muestran en esta fase: la categoría todavía no forma
parte del contrato de los RPC ejecutivos y el resumen canónico no tiene una
dimensión de vendedor. Añadirlos sin extender todas las agregaciones produciría
totales inconsistentes. Esa ampliación, junto con filtros guardados y alertas
reales, queda deliberadamente para Fase 2.

## Componentes reutilizados

- `MetricCard` y `MetricDelta` para jerarquía y comparación de KPIs.
- `AttentionItem` para señales operativas.
- `BiFilterBar`, `AnalyticsTable`, `BiDrawer`, `ChartContainer` y `BiState`
  para filtros, tablas, detalle, gráficas y estados remotos.
- Recharts se incorpora sólo para las dos visualizaciones funcionales de este
  resumen: línea temporal comparativa y ranking por ubicación.
