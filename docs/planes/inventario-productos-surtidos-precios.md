# Plan de simplificación: productos, surtidos y precios

Actualizado: 21 de agosto de 2026.

## Completado

- Alta individual de productos en un solo formulario comercial, sin pasos artificiales.
- Resumen previo de precio final, impuesto, lista y sucursales; cuando existe una sola lista, la asignación automática se informa sin agregar otro selector.
- El catálogo separa configuración comercial de disponibilidad: muestra `Configurado · Sin existencia` cuando una mercancía todavía no tiene stock.
- Al terminar el alta de mercancía se ofrece `Crear solicitud de compra`, con el producto preseleccionado en Abastecimiento.
- Edición de productos más clara y compacta.
- Indicadores de pasos pendientes para dejar un producto listo para venta.
- Simplificación de Productos por sucursal para cambios manuales y masivos auditados.
- Reorganización de Ventas y caja en Oferta por sucursal, Caja y cobro y Documentos.
- Pantalla amplia para Productos por sucursal, Listas y precios y Descuentos por volumen.
- Regreso simple desde las pantallas amplias hacia las opciones de Ventas y caja.
- Listas y precios simplificado en tres tareas: listas, precios de productos y asignación a sucursales.
- Captura manual por precio final con cálculo automático de base e IVA.
- Alta de listas con código y auditoría resueltos automáticamente; las opciones poco frecuentes quedan en avanzado.
- Ruta visible hacia la importación masiva para actualizaciones de alto volumen.
- Tipografía y jerarquía uniformes en Listas, Precios de productos y Asignación a sucursales; el selector de lista conserva una etiqueta secundaria clara.
- Verificación visual de Listas y precios en `localhost:3002` a 1440×900 y 1180×700, sin saltos ni cortes al cambiar de pestaña.
- Se corrigieron los 8 fallos globales detectados en Contabilidad, Bancos, BI y contratos del catálogo de productos.
- Build, lint y la suite completa de 392 pruebas pasan sin fallos.
- Descuentos por volumen aclarado como política empresarial para todas las sucursales, con prioridad explícita frente a precios escalonados y descuentos especiales.
- La configuración de descuentos valida tres rangos consecutivos y porcentajes crecientes antes de guardar; los cambios locales quedan identificados como pendientes de aplicar.
- Las recepciones de órdenes originadas en Abastecimiento heredan el almacén de la solicitud; la interfaz lo muestra bloqueado y el servidor impide recibir en otra ubicación. Las órdenes manuales conservan la selección libre.

## Pendiente

1. Realizar una revisión visual final de los formularios de inventario y configuración restantes.
2. Completar el recorrido operativo posterior al alta: solicitud de compra → recepción → existencia → venta.
3. Validar permisos del flujo de compras con dos cuentas reales:
   - cuenta encargada con perfiles **Almacén** + **Aprobación de compras**: debe poder aprobar la compra y crear la orden;
   - cuenta con **Almacén** sin **Aprobación de compras**: debe poder operar recepciones, pero no aprobar ni crear la orden.
   La prueba debe ejecutarse en escritorio autenticado y sin dejar compras de prueba pendientes.

## Estado para producción

- Listas y precios: cerrado funcional y visualmente para este alcance; no requiere SQL adicional.
- La rama conserva cambios sin commit; los 8 fallos globales ya están resueltos.
- El alta individual fue validada en la sesión autenticada a 1440×900 CSS, sin errores de consola; no se creó información adicional durante la prueba visual.
- Antes de producción: completar la revisión visual restante, el recorrido operativo desde solicitud de compra hasta venta y la prueba de permisos anterior; después hacer commit, push y smoke test en el entorno productivo.

## Criterios permanentes

- La captura manual es únicamente para pocos registros y correcciones puntuales.
- Las operaciones masivas deben ser server-side, transaccionales, paginadas y auditadas.
- El surtido define dónde se ofrece un producto; no modifica precios, existencias ni readiness.
- La importación masiva debe conservarse para catálogos y actualizaciones de gran volumen.
