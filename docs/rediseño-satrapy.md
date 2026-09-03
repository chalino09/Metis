# Rediseño Satrapy

Actualizado: 3 de septiembre de 2026.

## Estado

- **Ventas:** rediseño visual completado y verificado para escritorio y tablet.
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
