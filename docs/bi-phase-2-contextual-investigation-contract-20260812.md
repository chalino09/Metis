# BI — Fase 2: explicación de cambios e investigación contextual

## Contrato de contexto

`BiInvestigationContext` conserva la métrica, periodo, comparación equivalente,
filtros heredados, dimensión activa, ruta seleccionada y nivel. Es un contrato
de UI serializable preparado para consumidores posteriores; esta fase no expone
una API conversacional ni infiere acciones automáticas.

Cada paso incorpora el filtro seleccionado al mismo contexto. La ruta comprobada
para ventas netas es: **Ventas → sucursal → categoría → producto → registros**.
Los breadcrumbs permiten volver a cualquier nivel sin perder el resumen detrás
del drawer.

## Datos, compatibilidad y semántica

El RPC `bi_get_metric_investigation` reutiliza `bi_explorer_query` como capa
semántica: por ello hereda sus fórmulas, autorización de empresa, alcance de
ubicación, validación de dimensión y agregación server-side. La excepción es el
paso categoría → producto de ventas netas, que conserva la misma fórmula de
partidas (`sale_items.taxable_amount`) y valida la categoría canónica.

Dimensiones disponibles por métrica se derivan del catálogo canónico:

- Ventas netas: ubicación, categoría, producto y cliente; la ruta contextual
  prioriza ubicación → categoría → producto.
- Tickets: ubicación y cliente.
- Margen bruto: ubicación, categoría y producto, sólo con costo reconocido.
- Cobranza: cliente. Pagos a proveedor y CxP: proveedor.
- CxC: ubicación y cliente. Inventario: ubicación, categoría y producto.

Vendedor no se presenta porque no hay una relación canónica y única de ventas a
vendedor en el contrato actual. No se reemplaza con cajero, responsable u otro
atributo que alteraría el significado de la métrica.

## Contribuciones

Para cada grupo, el servidor devuelve actual, anterior, variación absoluta,
variación porcentual cuando el anterior no es cero, participación actual y
contribución. La contribución es `variación del grupo ÷ variación total`.
Cuando el total o grupo anterior es cero se devuelve `null`, nunca una división
inventada. Los grupos se ordenan por impacto absoluto; el RPC devuelve la suma
de todos, la suma de la página visible y la diferencia restante para permitir
reconciliación.

Los estados `improved`, `deteriorated` y `stable` describen el signo y la
materialidad del movimiento. La interfaz los llama factores descriptivos y
declara que no prueban causalidad.

## Evidencia y seguridad

Los factores y sus gráficas se calculan en PostgreSQL. La tabla de factores y
los registros de respaldo se paginan en servidor; el navegador nunca descarga
la colección completa de transacciones. Los registros reutilizan
`bi_get_drilldown_v2`, incluidos sus controles de permiso, alcance y rutas de
origen. Las consultas de investigación quedan auditadas como
`bi.metric_investigation_queried`.
