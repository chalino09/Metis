# Rediseño Satrapy

Actualizado: 7 de septiembre de 2026.

## Estado

- **Ventas:** rediseño visual completado y verificado para escritorio y tablet.
- **Compras:** rediseño extendido a proveedores, solicitudes, cotizaciones/órdenes, recepciones, facturas, CxP y pagos, incluidos paneles y confirmaciones.
- **Inventario:** rediseño ReUI aplicado a sus cinco vistas, paneles y estados de carga. Evidencia y límites en `docs/planes/rediseno-inventario-y-cargas.md`.
- **Resto de Satrapy:** pendiente de rediseño por módulo.

Este documento es la referencia visual para las siguientes fases. Cada módulo se actualizará sin alterar su lógica de negocio, datos ni permisos.

## Alcance de Ventas completado

Rediseño visual del módulo Ventas con componentes ReUI y patrones shadcn, sin cambiar la lógica operativa existente. Se conservan ventas, Supabase, RPCs, permisos, sesiones de caja, descuentos, promociones, inventario, validaciones, estados y flujos funcionales.

El alcance incluye:

- Punto de venta: búsqueda de productos, catálogo, carrito, cantidades, cliente, descuentos, promociones, medios de pago, efectivo, cambio, estados de caja, ventas en espera, diálogos, estados vacíos y carga.
- Ventas: historial, cotizaciones, pedidos, preparación, cobranza, promociones y configuraciones relacionadas.
- Clientes: búsqueda, tabla, alta, detalle, pestañas, crédito y cobranza mediante controles ReUI.

## Sistema visual para Satrapy

- Azul `#2563EB`: acciones primarias, selección y foco.
- Grafito `#111827`: jerarquía, títulos y controles secundarios.
- Gris pizarra `#64748B`: metadatos y acciones auxiliares.
- Ámbar suave `#D97706`: sólo advertencias, poco inventario y estados pendientes.
- Blanco y gris muy claro: superficies, tarjetas y formularios.

La paleta evita saturar la interfaz: el azul se reserva para acciones, selección y foco; el ámbar sólo comunica atención; las superficies permanecen neutrales.

## Componentes ReUI incorporados en Ventas

Se reutilizan botones, inputs, labels, tabs, cards, alerts, autocomplete, compact selects, number fields, scroll areas, badges, empty states, dialogs y drawers. Los wrappers mantienen las APIs existentes de Ventas para que el comportamiento de negocio permanezca intacto.

El POS usa un grid transaccional de ancho completo en escritorio y tablet. Catálogo y carrito comparten el espacio disponible; el carrito conserva el resumen y cobro visibles y permite desplazar sus partidas con rueda, trackpad o teclado cuando la lista crece.

## Próximas fases

Aplicar el mismo contrato visual, con componentes ReUI antes que controles manuales, al resto de los módulos de Satrapy. Cada fase deberá incluir revisión funcional, validación de permisos, comprobación responsive de escritorio/tablet y verificación de lint/build antes de producción.

## Verificación de Ventas

- Lint: PASS.
- `git diff --check`: PASS.
- Verificación autenticada de escritorio: POS medido a 1422 × 800 CSS; catálogo y carrito ocupan el grid completo sin espacio residual.
- Interacción del carrito: desplazamiento con rueda/trackpad y foco de teclado en su viewport ReUI.
- La lógica de negocio y las llamadas Supabase/RPC no fueron reemplazadas por datos estáticos.


## Compras — rediseño ampliado (5 de septiembre de 2026)

- Navegación y selector de empresa alineados con Ventas; azul, grafito y superficies neutrales.
- Proveedores: botones, campos, búsqueda y filtros usan componentes ReUI mediante adaptadores operativos reutilizables. Tabla, selección y estados visuales alineados con la paleta.
- Paneles y confirmaciones compartidos con Dialog de Radix y Button, Card, Tabs y ScrollArea de ReUI. Cabecera fija, contenido desplazable, cierre accesible y restauración del foco.
- Detalles de documentos: resumen destacado, metadatos compactos y pestañas para partidas, comparativos, expediente, movimientos e historial. Las acciones conservan sus condiciones de permisos y estado.
- Formularios agrupados por origen, identificación y condiciones; controles operativos ReUI, conservando el control de fechas y sus validaciones. Calendarios consideran el área visible de sus contenedores; acciones inferiores permanecen visibles en formularios largos.
- Se conservan RPCs, permisos, validaciones, paginación, búsqueda server-side y selección por lote. No se añadieron flujos de captura ni se modificaron registros durante la revisión visual.

### Comprobación de Compras

Sesión autenticada en escritorio de 1600 × 1000 CSS. No se usó vista tablet/móvil.

| Área | Interacciones comprobadas |
| --- | --- |
| Proveedores | Listado, búsqueda sin resultados, filtro de inactivos, edición existente y cierre con Escape. |
| Solicitudes | Detalle REQ-2026-000004, partidas, comparativo, selección/órdenes; nueva solicitud, búsqueda de destino y calendario; descartada. |
| Cotizaciones y órdenes | OC-2026-000009, partidas, recepciones, historial, apertura/cierre de cancelar orden, PDF descargado y formulario de nueva cotización. |
| Recepciones | REC-2026-000006, partidas, movimientos, apertura/cierre de anulación; nueva recepción y calendario completo. |
| Facturas | Detalle PR-PRUEBA-FECHA-VALIDA-20260725 y sus tres pestañas; nueva factura contra recepción y gasto/servicio, secciones agrupadas y botones inferiores visibles. |
| CxP/propuestas | Selección y deselección de QA-0001, apertura/cierre de nueva propuesta; detalle 01BBDB4E e historial. |
| Pagos | Pago PRUEBA-CENTAVOS-ABR-20260802, aplicaciones, comprobantes e historial; apertura/cierre de reversa, foco de regreso. Agenda en mes, semana y tabla. |

Límites: no se ejecutaron confirmaciones que alteran datos, cargas de comprobantes ni impresión física. Los estados no disponibles en esta empresa (por ejemplo solicitudes pendientes de adjudicar), y la variante de restaurante, se revisaron en código y compilación, sin afirmar cobertura visual de esas ramas.

TypeScript, lint, build de producción y `git diff --check`: PASS. Caché de desarrollo regenerada para servir en localhost los estilos completos.
