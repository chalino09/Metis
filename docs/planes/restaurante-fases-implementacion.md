# Satrapy Restaurante · fases de implementación

## Propósito

Poner Satrapy Restaurante en operación sin crear un segundo núcleo de productos,
inventario, ventas, pagos o contabilidad. Restaurante será una experiencia
especializada sobre las identidades y operaciones canónicas de Satrapy.

La prioridad inicial es controlar correctamente recetas, costos e inventario. La
facturación fiscal y el cobro integrado se incorporarán después mediante
adaptadores, de forma que también puedan ser utilizados por la experiencia
completa de Satrapy.

## Principios permanentes

- Los platillos, ingredientes y preparaciones usan productos canónicos de Satrapy.
- No se crea un inventario, venta, pago o costo paralelo para Restaurante.
- La pertenencia comercial y la disponibilidad operativa permanecen separadas:
  un faltante puede bloquear una venta, pero no retira automáticamente el
  platillo del surtido.
- Las operaciones de volumen deben ser server-side, transaccionales, paginadas,
  idempotentes y auditadas.
- Una modificación de receta o costo nunca altera ventas históricas.
- No se codifican recetas, unidades, ubicaciones, terminales o reglas particulares
  de una empresa en funcionalidades reutilizables.
- Alpha permanece únicamente en la frontera de importación.
- No se solicita nuevamente información que Satrapy ya conserva.

## Volumen operativo esperado

Para el primer restaurante se espera un catálogo de decenas o cientos de
platillos y cientos o pocos miles de componentes de receta. Los mismos
ingredientes pueden participar en muchos platillos y varias ventas pueden
confirmarse simultáneamente.

La captura individual es adecuada para altas y correcciones puntuales. Para una
carga inicial extensa deberá utilizarse una importación por lote; no se diseñará
como una secuencia de llamadas o capturas por cada renglón.

---

## Fase 1 · Operación culinaria, costos e inventario

### Objetivo

Permitir que el restaurante defina cómo se prepara cada platillo, conozca su
costo vigente y descuente automáticamente los ingredientes correctos al confirmar
una venta.

### Alcance

#### Unidades y conversiones

- Unidades base de masa: miligramo, gramo y kilogramo.
- Unidades base de volumen: mililitro y litro.
- Unidad de conteo: pieza.
- Unidades de compra configurables, por ejemplo caja, bolsa, paquete, botella o
  lata.
- Conversión auditable de la unidad de compra a la unidad base del ingrediente.
- Rechazo de conversiones dimensionalmente incompatibles.

Ejemplos:

- `1 kg = 1,000 g`.
- `1 l = 1,000 ml`.
- `1 caja = 24 piezas`.
- `1 bolsa = 2,000 g`.

No se incorporará conversión entre masa y volumen mediante densidad hasta que
exista un caso de negocio comprobado.

#### Recetas versionadas

- Receta por platillo o preparación canónica.
- Rendimiento total y número de porciones.
- Componentes expresados en unidades cotidianas y almacenados en cantidades
  normalizadas.
- Borrador, validación y activación.
- Versiones con vigencia; una receta activa utilizada no se modifica de forma
  destructiva.
- Detección de ciclos entre preparaciones.
- Duplicación de recetas para acelerar altas similares.

#### Preparaciones, rendimientos y mermas

- Preparaciones intermedias como salsa, caldo, masa, aderezo o arroz preparado.
- Consumo de una preparación desde uno o varios platillos.
- Rendimiento utilizable de cada preparación.
- Merma porcentual explícita, sin inferencias automáticas.
- Lenguaje de interfaz basado en cantidad comprada, cantidad utilizable y merma.

#### Costeo automático

- Costo por componente.
- Costo de preparaciones intermedias.
- Costo total por receta y costo por porción.
- Comparación con precio de venta y margen estimado.
- Diagnóstico de ingredientes sin costo o conversión válida.
- Trazabilidad hacia la versión de receta y los costos fuente.
- Costo reconocido congelado en cada partida vendida.

#### Consumo transaccional al vender

Al confirmar una venta, Satrapy deberá:

1. Resolver la receta vigente.
2. Expandir las preparaciones intermedias.
3. Agrupar el consumo total por ingrediente.
4. Bloquear saldos en un orden estable.
5. Validar la existencia completa.
6. Descontar ingredientes en la ubicación de la venta.
7. Registrar movimientos y costos reconocidos.
8. Confirmar venta, pago, ticket y consumo en una sola transacción.

Si cualquier validación falla, no se confirma parcialmente la venta, el pago, el
ticket ni el inventario. Los reintentos no pueden duplicar consumos y la
concurrencia no puede producir existencias negativas.

Los productos canónicos sin receta deben conservar su comportamiento actual para
no romper la experiencia completa de Satrapy.

#### Cancelaciones y devoluciones

- La cancelación completa revierte exactamente los consumos originales, sin
  recalcular con la receta vigente.
- La venta y sus movimientos originales permanecen inmutables y auditables.
- Una devolución de comida preparada no reintegra automáticamente ingredientes a
  existencia.
- La política definitiva de devoluciones parciales se documentará antes de
  implementarla y requerirá evidencia de que algo vuelve a ser utilizable.

#### Experiencia de usuario

El flujo principal será:

1. Abrir un platillo.
2. Elegir **Agregar receta**.
3. Indicar cuántas porciones prepara.
4. Buscar un ingrediente por nombre.
5. Capturar cantidad y unidad cotidiana.
6. Revisar costo por componente, costo por porción y margen.
7. Guardar como borrador o activar.

La interfaz debe ofrecer búsqueda rápida, ingredientes frecuentes, recetas
duplicables, mensajes accionables, prevención de doble envío, navegación por
teclado y una sola acción principal claramente visible.

### Readiness de Restaurante

La venta puede bloquearse por:

- falta de receta activa;
- receta sin rendimiento;
- unidad incompatible;
- conversión de compra faltante;
- ingrediente sin costo;
- ciclo entre preparaciones;
- existencia insuficiente.

El bloqueo explica qué debe corregirse y no modifica automáticamente el surtido.

### Criterios de salida

- Una receta simple y una preparación anidada calculan el costo correcto.
- Rendimiento y merma afectan correctamente consumo y costo.
- Una venta descuenta todos sus ingredientes de forma atómica.
- Dos ventas concurrentes no generan inventario negativo.
- Un reintento idempotente no duplica movimientos.
- El costo y la receta históricos permanecen estables después de cambios futuros.
- La cancelación revierte exactamente los movimientos originales.
- La experiencia `core` continúa operando sin receta.
- Las pantallas se validan en sesión autenticada y escritorio de al menos
  1180 × 700 CSS.

### Estado de implementación · 17 de agosto de 2026

**Estado: cerrada.** La base transaccional, el flujo principal y la validación de
interfaz están implementados, incluida la vista de Preparaciones.

#### Implementado

- Modelo culinario sobre `products` canónicos, sin un catálogo o inventario
  paralelo para Restaurante.
- Unidades normalizadas, conversiones de compra auditables y rechazo de
  dimensiones incompatibles.
- Recetas versionadas con borrador, activación, rendimiento, porciones, merma,
  componentes y detección de ciclos.
- Guardado completo de receta mediante una RPC transaccional e idempotente.
- Búsqueda server-side y paginada de insumos y preparaciones, además de carga
  inicial por lote de hasta 500 recetas.
- Costeo por componente, receta y porción; margen estimado y diagnóstico de
  costos o conversiones faltantes.
- Consumo culinario atómico al vender, costos fuente congelados, reversión exacta
  al cancelar e invariantes para impedir inventario negativo.
- Readiness culinario separado del surtido comercial y compatibilidad con
  productos `core` sin receta.
- Catálogo de Restaurante dividido visualmente en **Platillos** e **Insumos**, aun
  cuando ambos conservan la identidad canónica de producto.
- Alta de platillos sin existencia propia y alta de insumos con control de
  inventario, unidad de compra, conversión y costo.
- Editor de recetas con creación guiada del primer insumo, búsqueda, cantidades,
  unidades, borrador, duplicación de la versión activa, activación, costo y
  margen.
- Vista de **Preparaciones**: registra bases intermedias, como salsas o caldos,
  sin convertirlas en productos vendibles ni inventario paralelo; su receta se
  expande hacia los insumos al vender un platillo.
- Rediseño compartido del alta y edición para `core`, Platillos e Insumos: drawer
  amplio de hasta 1240 px, distribución en dos columnas, secciones de información,
  inventario/compra e impuestos/venta, categoría fiscal secundaria y acciones
  persistentes.
- Prueba funcional ampliada: una preparación anidada con 20 % de merma consume y
  costea 125 g para dos platillos, conserva ese costo histórico y lo revierte al
  cancelar.
- Runner de validación ampliado con dos ventas culinarias concurrentes: una debe
  ganar y la otra fallar, sin saldo negativo ni consumos duplicados.
- Validación técnica completada con lint, TypeScript, build de producción y 18
  pruebas de contrato. La inspección visual autenticada en escritorio confirmó
  Core, Insumos y Preparaciones: foco inicial, etiquetas, dos columnas, drawer
  de 1240 px, sin desbordamiento horizontal y controles con nombres accesibles.

La colisión preexistente entre las migraciones con versión `202608120002` sigue
afectando el reset integral del entorno local, pero no constituye deuda funcional
de Restaurante ni reabre esta fase.

---

## Puerta de avance · flujo guiado de Platillos

### Decisión

**Apto para avanzar con este ajuste antes de ampliar la Fase 2.** No se creará un
proyecto, catálogo ni núcleo nuevo para Restaurante. El problema está en la
experiencia de captura: el flujo actual expone por separado producto, precio,
receta y surtido, por lo que obliga a la persona usuaria a entender la estructura
administrativa de Satrapy.

La solución será una capa de orquestación exclusiva de Restaurante sobre las
entidades y operaciones canónicas existentes. La experiencia `core` no cambiará.

### Viabilidad confirmada

La arquitectura actual ya ofrece los puntos necesarios:

- `ProductCatalogView` distingue la experiencia `restaurant` y la función
  culinaria seleccionada.
- `products` conserva la identidad canónica y `product_culinary_roles` define si
  el artículo es platillo, insumo o preparación.
- Las recetas, sus versiones, costos y activación ya cuentan con operaciones
  server-side transaccionales e idempotentes.
- Los precios continúan en listas y vigencias canónicas.
- El surtido por ubicación y el readiness operativo permanecen separados.

Por tanto, no hace falta duplicar dominio ni mover Restaurante a otra aplicación.
Sí hace falta dejar de presentar esas capacidades como módulos independientes
dentro de la tarea cotidiana de crear o editar un platillo.

### Flujo objetivo

La creación y edición de un platillo se resolverá en un solo espacio de trabajo
con cuatro pasos y continuidad de estado:

1. **Platillo:** nombre y categoría culinaria. El código de barras será opcional
   y secundario; la unidad de venta será pieza sin pedir una decisión innecesaria.
2. **Precio y venta:** precio en la lista activa correspondiente y tratamiento
   fiscal. No se expondrán como decisiones normales los flags técnicos
   `is_sellable`, `is_active` o `inventory_policy`.
3. **Receta:** rendimiento, porciones, insumos, preparaciones, merma, costo y
   margen, reutilizando el editor y las RPC culinarias existentes.
4. **Revisar y publicar:** resumen de precio, costo, margen y bloqueos de
   readiness, con una acción principal inequívoca.

Se podrá guardar un borrador incompleto. Publicar exigirá, como mínimo, precio
vigente, tratamiento fiscal válido y receta activa sin bloqueos. La disponibilidad
por sucursal seguirá siendo una operación comercial separada y posterior; un
bloqueo operativo no retirará automáticamente el platillo del surtido.

Editar un platillo abrirá el mismo espacio de trabajo y no una cadena de drawers
o modales desconectados. Los mensajes describirán la tarea pendiente, por ejemplo
**Agrega el precio** o **Completa la receta**, en lugar de estados internos como
**Configuración pendiente**.

### Límites del ajuste

- Sólo cambia la experiencia Restaurante.
- No se crean tablas de productos, precios, recetas o inventario paralelas.
- No se habilita el cambio de función culinaria ni la desactivación del catálogo
  como acciones cotidianas dentro del formulario.
- La corrección de registros heredados o mal clasificados será una herramienta
  administrativa auditada, no parte del alta diaria.
- La creación de categorías fiscales y listas de precios seguirá siendo una
  configuración administrativa; el flujo sólo permitirá elegir valores ya
  válidos.
- La captura guiada individual se usará para altas y correcciones puntuales. Un
  catálogo inicial de decenas o cientos de platillos deberá poder importarse por
  lote.

### Archivo seguro de insumos

Esta entrega incluirá **Archivar insumo** sólo en Restaurante. No elimina el
producto de la base ni recupera el flujo de cambio de función culinaria.

1. La persona con permiso selecciona **Archivar insumo**, indica un motivo y
   confirma la acción.
2. El servidor revisa existencias y recetas activas que lo utilizan.
3. Si existen dependencias operativas, bloquea el archivo y explica qué debe
   resolverse; no modifica recetas ni inventario automáticamente.
4. Si es seguro archivarlo, deja de aparecer en el catálogo y en nuevas recetas,
   pero conserva compras, costos, movimientos y auditoría históricos.

La acción será una RPC server-side, idempotente y auditada; usará el estado
canónico de actividad, sin crear un flag nuevo. Archivar no sirve para corregir
un platillo mal clasificado: esa corrección seguirá siendo administrativa y
auditada.

### Dependencia técnica y SQL

El rediseño y su prueba de usabilidad pueden comenzar sin una migración nueva,
componiendo las operaciones canónicas existentes y conservando explícitamente el
estado de borrador.

Para habilitar **Publicar** se requerirá una única RPC de orquestación para
Restaurante que aplique producto, función culinaria, precio y activación de receta
en una transacción idempotente. Las operaciones actuales son seguras por separado,
pero encadenarlas desde el navegador puede dejar una configuración parcial si una
llamada intermedia falla. La nueva RPC no creará entidades ni cambiará el contrato
de `core`.

La entrega también requerirá una migración para la RPC de archivo seguro de
insumos. No habrá eliminación física de productos.

### Correcciones críticas previas al flujo de Platillos

Se implementaron primero tres ajustes operativos, limitados a Restaurante:

1. El alta o edición guarda producto, función culinaria, presentación de compra
   y control de lotes en una sola transacción idempotente. Así no puede quedar un
   insumo creado pero invisible por faltar su función culinaria.
2. Las conversiones métricas conocidas se validan en servidor: una unidad igual
   equivale a `1`, `1 kg = 1,000 g` y `1 l = 1,000 ml`. Las presentaciones de
   contenido variable, como caja o saco, conservan captura explícita.
3. Restaurante muestra **Mínimos de inventario**, reutilizando las políticas
   canónicas por ubicación. El motivo del alta sigue siendo evidencia de
   auditoría y no representa el mínimo de existencia.

La migración `202608190001_restaurant_ingredient_operational_integrity.sql`
también recupera de forma auditada las altas manuales interrumpidas que sí
alcanzaron a configurar su compra y corrige sólo equivalencias métricas
demostrablemente incoherentes. No modifica el flujo seguro de archivo.

### Cierre de integridad de conversiones, recetas y archivo

La migración `202608200001_restaurant_catalog_integrity_completion.sql` cierra
los tres ajustes críticos pendientes, sólo para Restaurante:

1. **Conversiones completas.** Las unidades estándar se calculan y validan de
   forma exacta (`1 kg = 1,000 g`, `1 l = 1,000 ml`). Caja, saco, bolsa,
   paquete, botella y otras presentaciones no reciben un `1` automático: se
   exige capturar y confirmar su contenido real. El servidor detecta y lista
   equivalencias heredadas dudosas sin inventar ni modificar datos.
2. **Alta completa y recuperable.** El guardado de un insumo sigue siendo una
   operación transaccional, idempotente y auditada: producto, función culinaria,
   compra y lote se guardan juntos. La revisión paginada permite corregir pocos
   registros puntuales; para catálogos amplios corresponde una corrección por
   lote auditada.
3. **Recetas antes de archivar.** El archivo consulta las recetas activas,
   existencias y órdenes abiertas. Cuando una receta bloquea el archivo, muestra
   su nombre y versión para abrirla, duplicar la versión activa, retirar o
   reemplazar el componente y activar la corrección. Sólo entonces permite
   archivar. No elimina productos ni altera recetas históricas.

La pantalla muestra la revisión sólo en **Insumos** de Restaurante y conserva
intacta la experiencia `core`. El SQL no corrige automáticamente una botella o
caja heredada: el sistema no puede conocer de forma fiable su contenido real.

### Orden de implementación

1. Prototipar el espacio de trabajo con datos reales y sin modificar el núcleo.
2. Unificar creación y edición; integrar precio, receta y resumen de readiness.
3. Probar borrador, reanudación, publicación y errores parciales.
4. Definir e implementar el contrato transaccional de publicación.
5. Integrarlo y probar idempotencia, concurrencia y reversión ante errores.
6. Validar la experiencia autenticada en escritorio de al menos 1180 × 700 CSS.
7. Continuar el alcance fiscal restante de la Fase 2.

### Criterios de salida

- Crear un platillo no exige salir del flujo para asignar precio o receta.
- Un borrador puede reanudarse sin duplicar el producto canónico.
- Editar vuelve al mismo flujo y muestra lo ya configurado.
- La persona usuaria no necesita interpretar flags del núcleo.
- Precio, costo, margen y bloqueos aparecen juntos antes de publicar.
- Publicar no deja producto, función, precio o receta en un estado parcial
  ambiguo.
- El surtido y el readiness conservan su independencia.
- La experiencia `core` y los historiales canónicos no cambian.

---

## Fase 2 · Solicitud de factura desde el ticket

### Objetivo

Capturar y dar seguimiento a las solicitudes de factura de los comensales, aun
antes de integrar un proveedor de timbrado.

### Estado de implementación · 18 de agosto de 2026

**Estado: implementación iniciada.** Ya existe la migración transaccional, la
bandeja operativa y la primera interfaz para funciones culinarias explícitas y
solicitudes internas ligadas al ticket. El autoservicio público mediante QR queda
pendiente de aprobación operativa y no se habilitó implícitamente.

### Claridad del catálogo de Restaurante

Antes de ampliar la operación fiscal se corregirá la lectura del catálogo sólo
en la experiencia Restaurante. Los apartados **Platillos**, **Insumos** y
**Preparaciones** tendrán mayor jerarquía visual y usarán una terminología única
en navegación, tablas, formularios, filtros, diagnósticos y recetas.

La función culinaria será explícita sobre el producto canónico y no se inferirá
por la falta de una receta ni únicamente por sus flags de inventario o venta:

- **Platillo:** lo que se vende al comensal. Puede tener receta y normalmente no
  conserva inventario propio.
- **Insumo:** lo que se compra, recibe y consume para elaborar recetas. Puede
  venderse excepcionalmente cuando se habilite de forma explícita.
- **Preparación:** base elaborada internamente con receta propia y reutilizable
  dentro de platillos. No se vende ni se recibe directamente.

La interfaz no utilizará **Disponible para recetas** como sustituto de una
función culinaria. En su lugar mostrará un concepto inequívoco, por ejemplo
**Función culinaria: Insumo**, y distinguirá por separado si el producto puede
usarse como componente, venderse o controlar inventario.

Un producto sin receta de platillo no se convertirá automáticamente en insumo.
Los cambios administrativos de función serán explícitos y auditados. En el alcance
actual, cada producto tendrá una sola función culinaria principal. Permitir varias
funciones requerirá primero un caso de negocio comprobado y un contrato específico;
no se habilitará mediante un flag genérico.

### Alcance

- Solicitud ligada a un ticket canónico elegible.
- Captura de RFC, razón social, régimen fiscal, código postal fiscal, uso de CFDI
  y correo.
- Reutilización de información fiscal ya registrada para evitar doble captura.
- Validaciones claras y lenguaje sencillo.
- Página de autoservicio accesible mediante QR en el ticket, si la operación lo
  aprueba.
- Bandeja paginada de solicitudes y búsqueda por folio, RFC o estado.
- Historial y auditoría de cada cambio.
- Preparación del contrato de integración que posteriormente consumirá un PAC.

### Estados necesarios

- Pendiente de revisión.
- Lista para emitir.
- Emitida.
- Rechazada con motivo.
- Cancelada.

No se mostrará una solicitud como factura emitida hasta contar con un CFDI
timbrado. La solicitud no modifica la venta ni el ticket originales.

### Criterios de salida

- Los tres apartados tienen mayor jerarquía visual únicamente en Restaurante y
  se distinguen sin depender de conocimiento técnico.
- Cada producto aparece según su función culinaria explícita; la ausencia de una
  receta no cambia automáticamente su apartado.
- La interfaz distingue función culinaria, uso como componente, control de
  inventario y disponibilidad de venta.
- Los cambios de función quedan auditados y no crean productos duplicados.
- Un cajero o cliente puede solicitar factura usando el folio del ticket.
- Satrapy evita solicitudes duplicadas y conserva idempotencia.
- Los datos fiscales existentes se reutilizan.
- La bandeja permite atender volumen real sin consultar registro por registro.
- Los estados distinguen claramente solicitud, preparación y emisión.
- La interfaz se valida en sesión autenticada y escritorio de al menos
  1180 × 700 CSS.

---

## Fase 3 · Emisión fiscal mediante PAC

### Objetivo

Emitir, entregar, cancelar y consultar CFDI de venta mediante un Proveedor
Autorizado de Certificación, conservando a Satrapy como autoridad del proceso y
la auditoría.

### Dependencias previas

- Selección del PAC.
- Documentación de su API y ambiente de pruebas.
- Costos por timbre y condiciones comerciales.
- Política segura para certificados y secretos.
- Reglas fiscales aplicables, incluida factura global.
- Definición de cancelación, sustitución y contingencia.

### Alcance

- Adaptador desacoplado del PAC seleccionado.
- Generación del documento fiscal desde la venta y solicitud canónicas.
- Timbrado con idempotencia y prevención de dobles emisiones.
- Reintentos acotados ante fallas temporales.
- Estados visibles de envío, timbrado, error y cancelación.
- Descarga y entrega de XML y PDF.
- Cancelación y sustitución auditadas.
- Conciliación entre solicitudes, CFDI emitidos y respuesta del PAC.
- Observabilidad sin exponer certificados, tokens o datos sensibles.

El PAC no se convierte en fuente paralela de clientes, ventas o saldos. Satrapy
conserva las identidades, relaciones y estados canónicos.

### Criterios de salida

- Una solicitud válida produce exactamente un CFDI timbrado.
- Los reintentos no duplican timbres.
- XML, PDF, UUID fiscal y respuesta del PAC quedan vinculados y auditados.
- Las cancelaciones y sustituciones siguen reglas explícitas.
- Una caída del PAC no altera la venta ni deja estados ambiguos.
- El adaptador puede ser utilizado posteriormente por la experiencia `core`.

---

## Fase 4 · Integración con terminal bancaria

### Objetivo

Permitir que Satrapy envíe el importe a una terminal o procesador compatible,
reciba el resultado y concilie el cobro sin captura duplicada.

Restaurante será el primer consumidor, pero la integración pertenecerá al dominio
canónico de pagos y podrá utilizarse en la experiencia completa.

### Operación provisional

Hasta contar con integración real, el restaurante puede registrar una forma de
pago externa llamada, por ejemplo, **Tarjeta**, junto con la referencia o
autorización de la terminal. Este registro no significa que Satrapy haya
procesado la tarjeta.

La interfaz debe distinguir:

- **Tarjeta registrada:** cobro realizado en una terminal externa.
- **Tarjeta procesada:** cobro confirmado mediante integración directa.

### Dependencias previas

- Identificación del banco, adquirente o procesador utilizado.
- Confirmación de que ofrece API, SDK o protocolo de integración soportado.
- Volumen de transacciones y costo de integración.
- Modelo de terminal por sucursal y caja.
- Reglas de propina, devolución, cancelación y conciliación.
- Requisitos de seguridad y certificación; Satrapy no almacenará datos sensibles
  de tarjeta.

### Alcance

- Adaptador desacoplado del proveedor.
- Asociación explícita entre terminal, ubicación y caja.
- Envío del importe desde el POS.
- Resultado aprobado, rechazado, cancelado o indeterminado.
- Idempotencia y consulta de estado después de una pérdida de conexión.
- Registro de autorización y referencia no sensible.
- Confirmación de la venta únicamente con un resultado resoluble.
- Devoluciones y cancelaciones compatibles con el pago original.
- Conciliación entre venta, pago, terminal y depósito cuando el proveedor lo
  permita.
- Auditoría y observabilidad sin números completos de tarjeta, CVV o secretos.

### Criterios de salida

- Un cobro aprobado se vincula una sola vez con la venta.
- Un rechazo no confirma venta ni inventario.
- Una desconexión no provoca cobro o venta duplicados.
- Un resultado indeterminado se resuelve consultando al proveedor antes de
  reintentar.
- Las devoluciones siguen el medio de pago original.
- La integración puede ser reutilizada por la experiencia `core`.

---

## Orden recomendado de ejecución

1. Mantener cerrada la base funcional de la Fase 1 y ejecutar la puerta de avance
   del flujo guiado de Platillos.
2. Completar la Fase 2 para no perder solicitudes mientras se selecciona el
   PAC.
3. Seleccionar e integrar el PAC en la Fase 3.
4. Evaluar proveedor, volumen y viabilidad antes de ejecutar la Fase 4.

Las fases 3 y 4 pueden investigarse en paralelo después de estabilizar la Fase 1,
pero no deben retrasar la salida inicial del restaurante si éste puede operar con
facturación asistida y una terminal externa registrada correctamente.

## Alcance expresamente excluido de esta ruta inicial

- Predicción automática de merma o demanda.
- Conversión entre masa y volumen por densidad.
- Optimización automática de recetas.
- Sustitución automática de ingredientes.
- Retiro automático de platillos del surtido por faltantes.
- Almacenamiento de números completos de tarjeta o CVV.
- Declarar una factura como emitida sin timbre fiscal.
- Codificar reglas particulares de un PAC, banco, terminal o restaurante dentro
  del núcleo reutilizable.

## Resultado esperado

Al finalizar las cuatro fases, Satrapy Restaurante podrá conocer el costo y margen
de cada platillo, consumir ingredientes de forma transaccional, atender solicitudes
de factura, emitir CFDI y procesar pagos integrados, conservando un solo núcleo
canónico y auditable para Restaurante y Satrapy completo.
