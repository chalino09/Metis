# BI Fase 4 — diseño y decisiones

Fecha: 2026-07-26

## Infraestructura reutilizada

- El catálogo y la matriz de compatibilidad continúan siendo `bi_get_metric_catalog`.
- Toda validación y ejecución pasa por `bi_explorer_query`; no existe un segundo agregador.
- Las vistas y widgets almacenan únicamente definición y configuración. Los resultados se vuelven a consultar desde fuentes canónicas.
- Los filtros de empresa, ubicación y entidades conservan los UUID canónicos de Satrapy.
- CSV, XLSX y PDF se construyen en el servidor a partir de páginas del Explorador, no de filas cargadas en React.

## Persistencia

- `bi_saved_views`: identidad, propietario, nombre, descripción, visibilidad y versión vigente.
- `bi_saved_view_versions`: definición inmutable por versión.
- `bi_dashboards`: identidad, revisión optimista y filtros predeterminados.
- `bi_dashboard_widgets`: referencia a una vista, tipo, layout y modo de filtros.
- `bi_export_jobs`: usuario canónico, empresa, destino, formato, snapshot validado, estado, filas y bytes.

Las mutaciones se exponen sólo mediante RPC `security definer`, con permisos explícitos, bloqueo optimista y auditoría. El guardado completo del layout es una única operación transaccional.

## Permisos

- `view_bi_dashboards`
- `manage_own_bi_views`
- `share_bi_views`
- `manage_bi_dashboards`
- `export_bi_reports`

Una vista privada sólo es visible para su propietario. Una vista compartida requiere permiso de compartir y puede usarse en tableros de la misma empresa. Las políticas RLS y las RPC vuelven a comprobar empresa y permisos; una exportación no amplía el acceso.

## Ejecución y volumen

- Máximo 12 widgets por tablero.
- Una actualización de tablero usa un snapshot coordinado con estado independiente por widget.
- Tablas de widgets: 25 agregados por consulta; gráficas/KPI: 12.
- Catálogos de vistas: páginas de hasta 100.
- Exportaciones: páginas server-side de 100 agregados y máximo explícito de 50,000 agregados por archivo.
- El layout usa revisión optimista para evitar que dos sesiones se sobrescriban silenciosamente.

## Limitaciones reales

- La generación de archivos es síncrona en esta fase; el límite de 50,000 agregados evita peticiones sin control. Una cola de trabajos sería necesaria para archivos mayores.
- El PDF ejecutivo representa hasta 12 barras por sección; el XLSX y CSV conservan todas las filas permitidas.
- Los widgets sólo pueden referenciar vistas compartidas. Esto evita que un tablero empresarial filtre datos a través de una vista privada.
- “Filtros propios” conserva el periodo y filtros guardados en la vista; “filtros globales” reemplaza periodo y ubicación al consultar.
- Las vistas compartidas son de sólo lectura para otros usuarios. Deben duplicarse para modificarlas.
- No se persisten resultados, cachés analíticos ni copias de métricas.

## Pendientes exclusivos de Fase 5

- Force-Directed Graph y red de dependencias.
- Envíos programados por correo.
- Alertas automáticas.
- Constructor controlado de fórmulas (sin fórmulas libres en esta fase).
