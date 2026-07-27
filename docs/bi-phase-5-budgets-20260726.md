# BI Fase 5 · Metas y presupuestos

## Auditoría de fuentes canónicas

- **Ventas:** `sales` y `sale_items`; la venta neta usa `sale_items.taxable_amount` y excluye ventas presentes en `sale_cancellations`.
- **Devoluciones:** el dominio actual sólo conserva cancelación completa de venta. No existe un documento canónico de devolución parcial de cliente; Fase 5 no inventa uno.
- **Margen:** el catálogo BI de Fase 3 ya define margen como venta neta menos costo reconocido de la partida vendida, pero lo mantiene no disponible porque la partida no congela dicho costo. Fase 5 permite presupuestar margen, pero no publica cumplimiento, diferencia ni proyección real hasta cerrar esa brecha.
- **Unidades:** `sale_items.quantity`, siempre dentro de producto/categoría comparables.
- **Categorías:** `product_categories.id` y `products.category_id`; la importación usa `product_categories.external_code`.
- **Ubicaciones:** `locations.id`; la importación usa `locations.external_code` y las consultas aplican `can_access_location`.
- **Colaboradores:** `collaborators.id`; la importación usa `collaborators.code`.
- **Atribución comercial previa:** `sales.cashier_id` representa al cajero, no al responsable comercial. No había relación usuario–colaborador ni responsable–venta.

## Vínculo mínimo de atribución

Se agregaron `collaborator_user_links` y `sale_responsibilities`. Ambos requieren identidad canónica, motivo y actor, y generan auditoría. No hay backfill ni inferencia por nombre, notas, puesto o identificadores Alpha. Las metas por responsable sólo reconocen ventas atribuidas explícitamente.

## Alcances disponibles

- Empresa.
- Ubicación.
- Responsable comercial.
- Categoría.
- Ubicación + categoría.
- Responsable + categoría.

Las distribuciones admitidas son únicamente empresa → ubicación y ubicación → categoría o responsable. Un presupuesto independiente y sus distribuciones se presentan por separado; los indicadores del Explorador sólo agregan presupuestos independientes para evitar doble conteo.

## Métricas

- Venta neta: presupuesto, resultado, cumplimiento, diferencia y proyección.
- Unidades vendidas: presupuesto, resultado, cumplimiento, diferencia y proyección.
- Margen: presupuesto disponible; resultado, cumplimiento, diferencia y proyección bloqueados por la limitación canónica documentada.

Los contratos se anexan a `bi_get_metric_catalog`; `bi_explorer_query` delega las métricas existentes al motor de Fase 4 y sólo enruta los códigos presupuestales a la extensión. Vistas guardadas, widgets, tableros y exportaciones continúan llamando el mismo RPC.

## Operación y seguridad

- Versiones borrador, aprobada y sustituida; las aprobadas no aceptan mutación destructiva.
- Motivo obligatorio en alta/modificación, aprobación, sustitución, atribución e importación.
- Detección de solapamientos antes de aprobar.
- Staging CSV/XLSX de hasta 50,000 filas, vista previa paginada y promoción transaccional/idempotente.
- RPC y RLS aplican empresa, ubicación, responsable propio y permiso de consulta de equipo.
- Selectores y listados paginados; el navegador no descarga hechos de ventas.

## Pendientes reales

- Documento canónico de devolución parcial de cliente, antes de descontar devoluciones distintas de cancelación total.
- Costo reconocido e inmutable por partida vendida y fecha, antes de habilitar margen real.
- Captura operativa del responsable comercial en el flujo que origina la venta; Fase 5 aporta el vínculo explícito y auditado, pero no reclasifica históricos.
- Force-Directed Graph y red de dependencias permanecen fuera de alcance.
- Pronósticos con IA, presupuesto contable, flujo de efectivo, gastos, CAPEX, fórmulas libres y envíos programados permanecen fuera de alcance.

## Validación

- Pruebas fuente: `tests/bi-phase5-budgets.test.ts`.
- Pruebas PostgreSQL transaccionales/RLS: `supabase/tests/202607260004_bi_phase5_budgets.sql`.
- La prueba SQL cubre versión/aprobación/sustitución, jerarquía, doble conteo, staging/idempotencia, venta real, atribución, RLS de Ingeniero de Campo e integración con Explorador.
