# BI de Satrapy · contrato visual de Fase 0

Fase 0 consolida la presentación del BI sobre los tokens y primitives actuales. No crea un tema, una paleta ni una librería paralela: los aliases `--bi-*` siempre remiten a los roles globales de Satrapy (`--surface`, `--line`, `--accent`, `--success`, `--warning` y `--danger`).

## Jerarquía y densidad

- La alerta operativa usa `AttentionItem`: icono, texto y tono redundante. Rojo significa error o riesgo crítico; ámbar significa atención o dato parcial; verde significa resultado favorable confirmado. Ninguno se usa como decoración.
- El KPI principal puede usar `MetricCard featured`; los KPI normales son superficies blancas con borde. La Fase 0 no decide todavía qué KPI protagoniza cada pantalla.
- Los números cambiantes usan dígitos tabulares. `MetricDelta` separa dirección (`up`, `down`, `flat`) de significado (`success`, `danger`, `warning`, `accent`, `neutral`) para evitar asumir que toda subida es positiva.
- La densidad de tabla BI parte de filas de 38 px y padding de 8 × 11 px. El scroll horizontal pertenece al contenedor; la paginación y las consultas continúan siendo server-side.
- Los radios se limitan a los radios compartidos de 8–10 px. Las cards normales no tienen sombra permanente. Las sombras elevadas quedan reservadas para drawers, menús, tooltips y diálogos.
- El verde Satrapy es el único acento dominante. Las series adicionales existentes se conservan por compatibilidad, pero Fase 1 deberá reducirlas cuando migre cada gráfica.

## Componentes

Todos viven en `app/components/ui/bi.tsx` y consumen `app/components/ui/primitives.tsx` o `app/components/ui/data.tsx`.

### `MetricCard`

Contenedor de KPI con `label`, `value`, `description`, `delta`, acciones separadas y variantes `selected`, `unavailable` y `featured`. `onSelect` sólo debe existir cuando el KPI cambia el contexto visual; la acción de detalle se entrega por `footerAction` para evitar botones anidados.

### `MetricDelta`

Presenta dirección con icono y valor tabular. `direction` describe el cambio; `tone` describe su consecuencia de negocio. Siempre debe incluir texto o valor además del color.

### `AttentionItem`

Fila compacta para una condición operativa. Acepta `title`, `description`, `tone` y una acción opcional. No sustituye alertas reales: Fase 0 sólo establece su contrato visual.

### `BiFilterBar`

Superficie estructural de filtros. `pending` comunica cambios sin aplicar con borde ámbar y debe acompañarse de texto de estado. Los controles siguen siendo `Input`, `Select` y `Button`; no carga catálogos ni cambia la estrategia server-side.

### `AnalyticsTable`

Especializa el `Table` compartido con densidad BI, números tabulares mediante `number-cell` y caption accesible. No implementa ordenamiento, virtualización ni paginación cliente.

### `BiDrawer`

Especializa el `Drawer` Radix existente para detalle y drilldown. Conserva trampa y restauración de foco, cierre con Escape, scroll contenido y footer estable. El drilldown ejecutivo ya lo utiliza.

### `ChartContainer`

Define encabezado, descripción, acción, leyenda y cuerpo de una gráfica sin acoplarse a una librería. Las gráficas SVG actuales ya pueden usarlo; Recharts sólo se añadirá cuando exista un caso funcional de migración.

### `BiState`

Unifica `loading`, `empty`, `error` y `partial`. Loading y actualizaciones no urgentes usan `role=status`; error usa `role=alert`. Cada estado mantiene icono, título y texto; loading ofrece skeleton sin convertirlo en el único anuncio.

## Referencias estudiadas

- shadcn/ui: composición abierta de Card, Table, Sheet, Skeleton y Chart sobre tokens semánticos.
- Tremor y `template-dashboard-oss`: composición compacta de dashboards, separación entre primitives y bloques de análisis, y layouts orientados a datos.
- Recharts: contenedor responsivo y capa de accesibilidad para una migración futura. No se agregó como dependencia.

## Pendiente para Fase 1

- Definir la alerta operativa y el KPI protagonista a partir de casos reales del resumen.
- Migrar gráficas una por una al contrato de `ChartContainer` y revisar sus series secundarias.
- Aplicar `AnalyticsTable` al resto de tablas BI cuando cada flujo sea intervenido.
- Validar contenido real largo, estados parciales por fuente y jerarquía completa del resumen, sin cambiar definiciones métricas.
