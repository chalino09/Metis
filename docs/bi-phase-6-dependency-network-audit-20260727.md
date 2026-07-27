# BI Fase 6 · Auditoría de relaciones de la red

## Relaciones habilitadas

| Conexión | Evidencia canónica | Periodo | Importe/cantidad |
| --- | --- | --- | --- |
| Proveedor → producto | Recepción confirmada; respaldo no acumulable: orden aprobada, adjudicación aprobada o cotización recibida | Fecha propia de la etapa dentro del filtro | Se usa una sola etapa por par. La recepción confirmada tiene precedencia. |
| Producto → categoría | `products.category_id → product_categories.id` | Clasificación vigente al consultar | Sin importe. No se usa `alpha_class`, nombres ni texto libre. |
| Producto → ubicación (surtido) | `sales_assortment_items` + surtido activo + asignación con vigencia | Intersección de vigencias con el periodo | Sin importe; expresa pertenencia comercial. |
| Producto → ubicación (disponibilidad) | `inventory_balances` + `product_pos_readiness_detail` | Corte actual, identificado como tal | Existencia actual; readiness se muestra por separado. |

Cotizaciones, adjudicaciones, órdenes y recepciones son etapas del mismo ciclo. Sus importes
no se suman entre sí. Ventas sólo alimentan tamaño de nodos de producto/ubicación; no prueban
qué proveedor abasteció un producto. Inventario tampoco crea una relación proveedor-producto.

## Fórmulas y codificación

- Concentración = importe del proveedor para el producto ÷ importe total comprobado del producto
  dentro del alcance filtrado. Alto: ≥ 80%; medio: ≥ 50% y < 80%; bajo: < 50%.
- Proveedor único es concentración de 100% dentro del periodo y alcance consultados, no una
  predicción de riesgo.
- Disponibilidad: `blocked_readiness` si readiness canónico impide vender; `available` si readiness
  permite vender y hay existencia; `out_of_stock` si readiness permite vender y la existencia es 0.
- El surtido y la disponibilidad son aristas distintas. Readiness nunca elimina la pertenencia.
- La posición y cercanía del force layout no expresan causalidad.

## Seguridad, límites y determinismo

La empresa, `view_bi`, `view_bi_dependency_network`, acceso de ubicación y `can_access_location`
se validan antes y dentro de cada consulta. Expansión requiere permiso separado. La respuesta
admite como máximo 200 nodos, 400 aristas y dos niveles; la UI solicita inicialmente 120/240.
Los empates se ordenan por tipo e identidades canónicas, por lo que filtros iguales producen el
mismo conjunto. Drill-down es paginado (máximo 100 filas por página). No hay caché compartida
ni tabla de resultados: las vistas guardan sólo JSON de configuración.

## Relaciones descartadas

- Nombres de proveedor o producto presentes en descripciones libres.
- `alpha_class`, `product_group`, referencias externas Alpha y staging como relación de dominio.
- Ventas → proveedor, porque la venta no conserva procedencia/lote del abastecimiento.
- Inventario → proveedor sin recepción canónica enlazada.
- Cercanía visual, correlaciones, recomendaciones por IA y puntuaciones opacas de riesgo.
- Categoría ausente: no se crea un nodo “inferido” ni una clasificación genérica.

Los índices de líneas por empresa/producto y documento se incorporan para los joins acotados.
Su beneficio debe confirmarse con `EXPLAIN (ANALYZE, BUFFERS)` sobre datos representativos antes
de añadir índices adicionales.
