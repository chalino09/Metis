# Plan de rediseño de Inventario y estados de carga

Fecha: 7 de septiembre de 2026. Estado: implementación aplicada el 7 de septiembre de 2026; ver evidencia y límites al final.

## Objetivo y alcance

Llevar Inventario al sistema visual de Ventas y Compras con ReUI: mejorar composición, lectura, alineación, navegación y respuesta durante las cargas. El alcance incluye las cinco vistas actuales y todos los paneles, formularios, selectores, menús y confirmaciones accesibles desde ellas.

La revisión para este plan se basa en el código y en `docs/rediseño-satrapy.md`; no representa una validación visual nueva. La variante Restaurant tiene ramas propias de catálogo, importación y recetas: se deben incluir donde esas acciones aparezcan, con evidencia diferenciada.

## Contrato visual

| Uso | Color |
| --- | --- |
| Acción primaria, selección y foco | Azul `#2563EB` |
| Títulos, cifras principales y resumen de documento | Grafito `#111827` |
| Metadatos y ayudas | Pizarra `#64748B` |
| Superficies | Blanco `#FFFFFF` |
| Fondo y secciones secundarias | Gris claro `#F8FAFC` |
| Bordes | Gris `#E2E8F0` |
| Faltantes, pendientes y advertencias | Ámbar `#D97706` |
| Errores y acciones destructivas | Token de peligro existente, `#B5423C` |

El verde semántico existente puede indicar confirmación o éxito, acompañado de texto; no vuelve como color dominante de navegación. Reutilizar los tokens del rediseño para evitar nuevas paletas por módulo y herencias verdes en portales o cargas iniciales.

- Una acción primaria por contexto; acciones secundarias próximas y operaciones excepcionales en un menú identificable.
- Mantener la densidad operativa de Ventas: título, contexto breve, herramientas y tabla. Añadir resúmenes únicamente cuando exista una consulta fiable para el ámbito completo; no calcular indicadores globales con una página de resultados.
- Formularios en secciones claras. Etiquetas y controles alineados al inicio; ayudas y errores debajo, sin repartir espacio vertical entre las filas internas del campo. Revisar también etiquetas largas y controles anidados.
- Cabecera y acciones visibles en paneles, con desplazamiento del cuerpo. Tablas anchas con desplazamiento local y nombres/folios legibles.
- Botones, Input, Select/Autocomplete, Card, Tabs, ScrollArea y Empty de ReUI. Reutilizar adaptadores operativos, extraer el contenedor compartido de paneles cuando convenga y mantener los controles de fecha y cantidades con sus validaciones existentes.

## Pantallas de Inventario

| Pantalla | Cambios previstos | Interacciones incluidas |
| --- | --- | --- |
| Productos | Barra de búsqueda y filtros consistente; tabla con identidad, unidad y estados legibles; detalle agrupado en información, operación y configuración comercial/fiscal, según permisos. | Nuevo producto y asistente existente, edición, costos, comercialización, revisión de configuraciones, menús y confirmaciones. Ramas de insumos, bases, platillos, recetas e importación cuando correspondan. |
| Inventario por ubicación | Contexto de sucursal/ubicación inequívoco; existencias agrupadas por producto; cantidades alineadas y unidad visible; movimientos en un panel con contexto del producto y filtros. | Selector de ubicación, expansión por producto, búsqueda, paginación, historial y registro inicial existente. |
| Conteos físicos | Diferenciar listado, captura y revisión; fijar el contexto del conteo y ordenar diferencias y cantidades; conservar el espacio de escaneo y la navegación rápida entre partidas. | Crear/abrir conteo, filtros, escaneo, captura existente, confirmación de ceros, finalizar, aprobar ajustes y cancelar, según estado y permisos. |
| Transferencias | Composición de listado y detalle con origen, destino y estado destacados; constructor con partidas, disponibilidad y cantidades claramente relacionadas. | Crear, buscar productos del origen, selección por lote, importar partidas por SKU y acciones que avanzan o cancelan el estado existente. |
| Reabastecimiento | Separar políticas de mínimos/máximos, faltantes y seguimiento; tabla de sugerencias con contexto de ubicación; selección y resumen de lote visibles. | Configurar políticas, búsqueda, importación por SKU, filtros de seguimiento y creación de solicitud de compra desde la selección. |

No convertir procesos de volumen en captura registro por registro. Conservar búsqueda y paginación en servidor, selecciones entre páginas y operaciones transaccionales/auditadas. El alta individual y las correcciones puntuales existentes se mantienen como excepciones; cualquier flujo manual nuevo requeriría primero justificar volumen e impacto.

## Pantallas y estados de carga

Hay tres puntos compartidos que requieren coordinación: `LoadingScreen`, `RouteModuleLoading` y `DataState`/`DataRefreshStatus`. La base será reutilizable en Satrapy; la primera migración completa será Inventario, con revisión de regresión en Ventas y Compras.

| Momento | Presentación y comportamiento |
| --- | --- |
| Inicio y cambio de empresa | Estructura de navegación y contenido con la paleta actual, bloques de espera del tamaño aproximado del destino y un mensaje breve. En cambio de empresa, retirar inmediatamente datos de la anterior. |
| Apertura de módulo | Conservar navegación y contexto ya resueltos; usar una estructura de espera de tabla, formulario o detalle según la vista, en lugar de una pantalla vacía con un spinner genérico. |
| Primera consulta | Encabezados y estructura estable; filas provisionales neutrales, sin cifras o estados ficticios. Mostrar “Cargando productos…” o el mensaje específico del contexto. |
| Búsqueda, filtro, paginación o actualización | Mantener datos previos sólo si pertenecen al mismo ámbito autorizado, indicando “Actualizando…”. No presentar datos anteriores como resultado definitivo del filtro nuevo; bloquear acciones que dependan de resultados aún sin resolver y conservar la selección cuando el contrato existente lo permita. |
| Apertura de detalle | Abrir el panel con título/contexto conocido y estructura de espera interna; no mostrar fugazmente el documento anterior. El cierre debe seguir disponible cuando sea seguro. |
| Guardado o transición operativa | Estado de carga en el botón que disparó la acción, sin cambio de anchura; impedir envíos duplicados y conservar formulario/errores. No bloquear toda la aplicación innecesariamente. |
| Operación larga | Mostrar fases o cantidades únicamente si el proceso proporciona progreso real. Si no lo hay, indicador indeterminado y explicación breve; nunca porcentajes inventados. Ofrecer cancelación sólo si está soportada. |
| Vacío, error o carga demorada | Vacío distinguido de error y falta de permiso; acciones pertinentes como limpiar filtros o reintentar. No dejar un error convertido en carga infinita ni reintentar escrituras automáticamente. |

Especificación visual: bloques de espera en grises neutrales, sin resplandores ni animaciones dominantes; alturas estables que correspondan al contenido. `aria-busy` en la región que carga, un aviso accesible por operación y bloques decorativos fuera del árbol accesible. Respetar movimiento reducido. No añadir retrasos artificiales para hacer visible una animación.

## Orden de ejecución

1. **Inventario de interacciones y base compartida.** Mapear cada botón a su panel/acción y cada estado de carga; centralizar tokens y reglas de alineación, incluidos portales. Definir componentes de espera para lista, detalle y formulario. Separar las vistas de Inventario de `SatrapyApp.tsx` sólo donde facilite una migración acotada, sin reescribir lógica.
2. **Productos y existencias.** Aplicar composición completa a listado, alta/edición, configuración comercial y movimientos. Integrar y probar los estados de carga desde esta fase.
3. **Conteos y transferencias.** Rediseñar los espacios de trabajo y todas sus acciones secundarias y confirmaciones; conservar flujos de teclado y volumen.
4. **Reabastecimiento.** Rediseñar políticas, faltantes y selección; revisar continuidad visual hacia las solicitudes de Compras.
5. **Cargas compartidas y cierre.** Completar entrada/cambio de módulo/empresa, revisar regresiones en Ventas y Compras y cerrar la matriz de interacciones y estados.

## Criterios para darlo por terminado

- Cada pantalla se valida con sus paneles y botones; un listado recoloreado no cuenta como módulo finalizado.
- Verificación autenticada en escritorio, mínimo 1180 × 700 CSS y otro ancho amplio (por ejemplo 1600 × 1000). No validar tablet/móvil salvo solicitud expresa.
- Medir parejas de etiquetas y controles con/sin ayuda, ayuda multilínea y errores; revisar alturas de controles, bordes, acciones inferiores y calendarios sin recortes.
- Probar carga inicial, actualización con datos, respuestas lentas, cambio rápido de filtros/ubicación, vacío y error. No debe reaparecer un resultado obsoleto ni mezclarse información de empresas.
- Revisar foco, Escape, vuelta al disparador, selección por teclado, desplazamiento y movimiento reducido.
- Matriz de evidencia por pantalla/acción/estado: probada, revisada en código o pendiente por falta de datos/permisos. Las transiciones que alteren existencias se prueban con datos controlados; abrir su confirmación no equivale a validar su ejecución.
- TypeScript, lint, build y pruebas existentes pertinentes de inventario: agrupación, búsqueda por ubicación, conteos, transferencias y reabastecimiento. Añadir pruebas sólo donde haya nuevo comportamiento que lo justifique.
- Revisar el resultado servido por localhost después del build y registrar cualquier estado sin cobertura; no declarar validación total si queda alguna rama pendiente.

## Fuentes locales del alcance

- `docs/rediseño-satrapy.md`: paleta y precedentes de Ventas/Compras.
- `app/components/SatrapyApp.tsx`: navegación, vistas operativas de Inventario y cargas de aplicación/módulo.
- `app/components/ProductCatalogView.tsx`, `ProductCreationWizard.tsx`, `ProductCommercializationModal.tsx`: catálogo, alta y configuración.
- `app/components/ui/data.tsx`: carga, actualización, vacío, error, tablas y paginación.
- `app/components/reui/operational-controls.tsx`, `purchasing-panels.tsx` y componentes ReUI existentes: base de reutilización.
- `AGENTS.md`: restricciones de dominio, volumen y validación de escritorio.


## Implementación y comprobación — 7 de septiembre de 2026

- Las cinco vistas de Inventario usan el shell, controles operativos y paleta ReUI. Se extrajo `operational-panels.tsx`; Compras conserva sus exports como adaptadores compatibles.
- Productos: alta, edición, disponibilidad y configuraciones migradas a los controles compartidos. Identidad, compra, impuestos y costos se agrupan en secciones; el resumen de edición destaca el producto.
- Transferencias: creación en un panel dedicado desde «Nueva transferencia»; listado y detalle permanecen en el espacio de consulta. Al crear se cierra el constructor y se conserva la selección del resultado.
- Conteos: contexto, estado, progreso real y tabla en un espacio de trabajo. Reabastecimiento: seguimiento, constructor por lote y cuadros de importación integrados. Se preservan límites y RPCs.
- Cargas: componente `LoadingPlaceholder` compartido para módulos, consultas y paneles de alta/comercialización. Actualización con datos previos optativa, sin remontar el contenido, con aviso superpuesto e interacciones bloqueadas mientras carga. Sin porcentajes simulados.
- Se añadieron claves por empresa para reiniciar las vistas de Inventario al cambiar de ámbito y protección de respuestas obsoletas en listados/partidas. Productos y existencias invalidan también peticiones pendientes al resolver desde caché; errores de producto no se guardan como resultados válidos en caché.

### Evidencia

- Sesión autenticada QA R-OP, escritorio medido a 1600 × 1000 y 1311 × 889 CSS. Sin desbordamiento del documento en las vistas medidas; tablas con desplazamiento propio.
- Productos: listado, alta sin guardar, edición de Producto QA R-OP y apertura de disponibilidad. Pares de controles de información básica medidos con idéntica coordenada vertical pese a ayudas de distinta longitud.
- Existencias: expansión de Producto QA R-OP, sucursales con cero y saldo positivo, apertura del historial de movimientos.
- Conteos: listado y apertura del conteo aplicado de Sucursal QA POS 26 Remota; progreso y diferencias visibles.
- Transferencias: estado vacío, apertura de nueva transferencia y diálogo anidado de importación por SKU, sin ejecución.
- Reabastecimiento: filtros de seguimiento, configuración de ubicación por teclado, búsqueda, selección de tres productos, tabla de mínimos/máximos y apertura/cierre de importación. Sin guardar políticas.
- Continuidad: «Ver solicitud» abrió REQ-2026-000002 en Compras con sus pestañas; navegación al POS conservó su contexto sin ejecutar ventas.
- 30 pruebas existentes de Inventario y 3 pruebas renderizadas de carga/actualización/error: PASS. Se adaptaron dos archivos de pruebas a los nombres de los wrappers, conservando sus verificaciones operativas.
- TypeScript, lint, build de producción y diff-check: PASS.

### Límites de la verificación

No se crearon productos, conteos, transferencias ni políticas; tampoco se despacharon mercancías o aplicaron ajustes. Esta empresa no tiene transferencias existentes ni conteos abiertos para comprobar visualmente sus transiciones. La captura/decisión de conteos y confirmación de transferencias se revisaron en código y compilación, sin afirmar validación visual de todas sus ramas. Los escenarios de carga/actualización/error tienen pruebas renderizadas; no se simuló una red lenta en el navegador ni se verificaron todas las combinaciones de permisos.

### Alcance de publicación — 7 de septiembre de 2026

Se publica únicamente el rediseño de Compras, Inventario y las cargas compartidas. Se excluyen el nuevo editor y POS de Restaurante, sus migraciones y pruebas, los cambios de sus componentes exclusivos y la nota de configuración de Meta. Los componentes comunes conservan su uso por las variantes existentes; no se introducen RPCs ni migraciones nuevas.
