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

**Estado: validación de interfaz completada.** La base transaccional y el flujo
principal están implementados, incluida la vista de Preparaciones en Supabase.
Sólo queda destrabar la ejecución integral de evidencia SQL en la base local.

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

#### Pendiente de validación final

1. Crear una preparación real, activar su receta y usarla desde un platillo como
   prueba operativa de aceptación. No requiere SQL adicional.
2. Resolver la colisión preexistente entre
   `202608120002_bi_executive_decision_summary.sql` y
   `202608120002_collection_automation_foundation.sql` en el entorno local de
   validación. Esa colisión detiene `supabase db reset --local` antes de que las
   pruebas culinarias puedan ejecutarse; no es causada por Restaurante ni debe
   corregirse renombrando una migración ya aplicada en Supabase.

La operación ya puede usar Fase 1. Al recuperar el reset local se podrá registrar
la evidencia automática final de concurrencia sin deuda funcional de Restaurante.

---

## Fase 2 · Solicitud de factura desde el ticket

### Objetivo

Capturar y dar seguimiento a las solicitudes de factura de los comensales, aun
antes de integrar un proveedor de timbrado.

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

1. Completar la Fase 1 y probarla con operación real controlada.
2. Implementar la Fase 2 para no perder solicitudes mientras se selecciona el
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
