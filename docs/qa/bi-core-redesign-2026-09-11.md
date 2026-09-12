# BI del núcleo — rediseño y operación

## Entrega

BI adopta el mismo shell ReUI, azul de acción, superficies neutrales y controles de Ventas/Compras. Conserva Resumen, Alertas, Análisis, Vistas/reportes, Metas/presupuestos y Red. El shell nuevo se habilita sólo para la experiencia del núcleo.

El resumen prioriza ventas, margen, cartera e inventario; muestra calidad/cobertura y admite la semana anterior completa (lunes a domingo). El nuevo Resultados por área ofrece:

- Rentabilidad por sucursal: ventas, margen, gastos contabilizados atribuidos, contribución y cobertura de costo. Consulta paginada; no presenta la contribución como utilidad neta completa.
- Inventario y compras: valuación actual, faltantes conforme políticas, seguimiento de reposición, existencias registradas y dependencia de proveedores. Las cantidades conservan su unidad y ubicación.
- Cartera: pendiente/vencida al corte, investigación por cliente y acceso a CxC.

`GET /api/bi/operations` compone RPC existentes con el JWT del usuario. No requiere migraciones, recapturas, service role ni permisos nuevos. Los bloques secundarios conservan sus permisos y reportan indisponibilidad individualmente. Las consultas tienen páginas y límites acotados.

## Semántica y correcciones

- Inventario/reabastecimiento corresponden al momento de consulta; cartera y rentabilidad al periodo seleccionado. El corte UTC de la fuente no se confunde con el día local de presentación.
- El periodo anual utiliza comparaciones agregadas disponibles; no dibuja una serie histórica inexistente como ceros. Su investigación conserva el periodo completo.
- Cero real, ausencia y parcialidad se distinguen. Las métricas no disponibles no revelan importes.
- Cambiar filtros descarta respuestas de consultas anteriores. Los filtros de producto, cliente o proveedor conservan el análisis compatible y piden quitar sólo esos filtros para consultar el resumen transversal.
- Búsqueda con teclado, estados de carga/error y paneles con foco/Escape. Los enlaces de navegación reaccionan al contexto aplicado sin conservar la consulta anterior.

## Alcance pendiente

Esta entrega reúne operaciones existentes y mejora BI. No crea los dominios de producción agrícola/flota ni métricas aún sin fuente: rotación formal, mermas reales integrales, atribución por vendedor, calidad/puntualidad de proveedores y forecast estadístico. Tampoco asigna gastos compartidos automáticamente. Restaurante queda fuera del alcance funcional.

## Validación

- 80 pruebas BI de TypeScript: PASS.
- TypeScript y ESLint de archivos intervenidos: PASS.
- Compilación de producción: PASS.
- Solicitud HTTP sin sesión a la nueva API: 401.
- Sesión autenticada en empresa QA del núcleo; escritorio medido 1600 × 1000 CSS, sin desbordamiento de la página. Se revisan filtros, tarjetas, tablas, paneles, rentabilidad, inventario, cartera y navegación BI.
- La comprobación utiliza operaciones de lectura. No se confirman compras, cobros, ajustes ni cambios de datos para validar la interfaz.

### Recorridos comprobados

- Semana anterior: 31/8/2026–6/9/2026; comparación anual: 31/8/2025–6/9/2025 con barras agregadas.
- Búsqueda sin coincidencias, selección de producto con flechas/Enter y retiro de filtros de detalle conservando fechas.
- Rentabilidad → desglose → documentos de venta → historial de Ventas; cartera → clientes → Escape con devolución del foco.
- Existencias por ubicación/unidad y reposición pendiente de recibir, sin recapturar información.
- Carga de Alertas, Análisis, Vistas/reportes, Metas/presupuestos y Red conservando el contexto en sus enlaces.
- Exportación CSV: el clic completó `POST /api/bi/export` con HTTP 200 y sin error de interfaz. La herramienta no recibió el evento de descarga; no se afirma validado el archivo guardado.

## Ajustes finales solicitados

- Selectores compartidos de opciones fijas, sin edición ni borrado del texto; incluye cambio de empresa. Navegación con flechas, Enter y Escape verificada.
- Tarjetas con bordes neutros uniformes y filas seleccionadas sin franjas decorativas azules.
- Validación previa a publicación: lint completo, compilación y 80 pruebas BI aprobadas.
