# Plan maestro de automatización de cobranza

**Estado:** planeación

**Producto:** Satrapy

**Primera capacidad:** Cobranza asistida

**Última actualización:** 2026-08-12

## 1. Objetivo

Incorporar automatización auditable dentro del flujo actual de Cuentas por cobrar para priorizar cartera, programar seguimientos, preparar comunicaciones y registrar resultados, sin crear un CRM paralelo ni cambiar el stack de Satrapy.

La primera meta de negocio es aumentar la recuperación de la cartera vencida actualmente estimada en aproximadamente **2 MDP**, reduciendo cuentas sin seguimiento, promesas incumplidas y captura manual duplicada.

El agente prepara y coordina trabajo. Satrapy conserva la autoridad sobre clientes, documentos, saldos, pagos, promesas, permisos, aprobaciones y auditoría.

## 2. Alcance y volumen operativo

La unidad de trabajo será el **caso de cobranza por cliente**, no cada documento individual. Cada caso podrá reunir todos los documentos abiertos, pagos, promesas, contactos y conversaciones del mismo cliente.

El diseño deberá soportar la cartera completa de una empresa mediante consultas server-side, priorización y paginación. Ningún usuario deberá abrir, clasificar o programar documento por documento para iniciar la gestión. Antes del desarrollo se medirán:

- clientes con saldo abierto y vencido;
- documentos abiertos y vencidos;
- monto total y antigüedad de la cartera;
- clientes sin teléfono, correo o contacto de cobranza;
- pagos y promesas históricas disponibles;
- volumen diario esperado de mensajes, respuestas y llamadas.

El piloto no se dimensionará con una cifra inventada. Estos conteos definirán el tamaño de lote, concurrencia, límites diarios y costos máximos.

## 3. Principios permanentes

1. **Satrapy y Supabase son la fuente de verdad.** No habrá una base paralela de clientes, saldos o promesas en OpenAI o Twilio.
2. **La lógica financiera es determinista.** Saldos, vencimientos, prioridad mínima, horarios, frecuencia de contacto, descuentos y escalamiento se validan en Postgres/RPC, nunca únicamente en un prompt.
3. **La automatización no altera el dominio por inferencia.** Una respuesta del cliente puede originar una propuesta o promesa declarada, pero no un pago, descuento, convenio o corrección contable.
4. **Operación agrupada y server-side.** Los casos se generan y actualizan por lotes paginados, transaccionales, idempotentes y auditados.
5. **El agente está separado del request principal.** Next.js no espera a que el agente termine para completar una operación normal de Satrapy.
6. **Toda acción explica por qué ocurrió.** Las tareas, propuestas, contactos, reintentos y escalaciones guardan fecha, motivo, origen y resultado.
7. **Autonomía gradual.** La primera versión propone; una persona aprueba. Solo acciones de bajo riesgo podrán automatizarse después de medir resultados.
8. **Detención inmediata por evidencia operativa.** Un pago confirmado, una disputa, una solicitud de no contacto o una intervención humana detienen o redirigen las tareas pendientes aplicables.

## 4. Arquitectura objetivo

```text
Satrapy / Supabase
  ├─ CxC canónica, clientes, contactos y pagos
  ├─ reglas, permisos y aprobaciones
  ├─ casos, tareas, propuestas y auditoría
  └─ cola durable
          ↓
Worker Node.js / TypeScript
  ├─ reclama tareas con lease
  ├─ ejecuta reglas previas
  ├─ invoca OpenAI Agents SDK
  └─ llama herramientas cerradas de Satrapy
          ↓
Twilio WhatsApp / Programmable Voice
          ↓
Cliente
          ↓
Webhooks o WebSocket → cola durable → Satrapy
```

### Responsabilidades

**Satrapy/Supabase**

- Fuente de verdad y modelo multiempresa.
- Priorización determinista y elegibilidad de contacto.
- Cola durable, idempotencia, permisos, RLS y auditoría.
- Aplicación de decisiones mediante RPC transaccionales.
- Cancelación o reprogramación de trabajo ante pagos y respuestas.

**Worker de automatización**

- Proceso independiente de Next.js, pero parte del despliegue de Satrapy.
- Reclama tareas vencidas en lotes con `FOR UPDATE SKIP LOCKED`.
- Mantiene leases, intentos máximos, backoff y estados terminales.
- Nunca expone credenciales server-side al navegador.
- No conserva una copia autoritativa del dominio.

**OpenAI Agents SDK**

- Razonamiento, uso de herramientas, guardrails y trazas técnicas.
- Preparación de resúmenes, recomendaciones y borradores.
- Interpretación estructurada de respuestas del cliente.
- No sustituye la cola, las reglas del dominio ni la auditoría de Satrapy.

**Twilio**

- Transporte de WhatsApp y telefonía.
- Entrega mensajes, plantillas, respuestas y eventos técnicos.
- ConversationRelay aporta STT/TTS y comunicación de voz por WebSocket.
- No decide prioridades, acuerdos, descuentos o estados financieros.

## 5. Modelo funcional propuesto

Los nombres definitivos se validarán antes de migrar, pero el dominio requiere estos conceptos:

### Caso de cobranza

Un caso activo por empresa y cliente mientras exista saldo gestionable. Conserva responsable, prioridad, próxima acción, estado operativo y fechas relevantes. El saldo se consulta desde CxC; no se duplica como fuente autoritativa.

Estados iniciales candidatos:

- `pendiente`: existe saldo gestionable sin acción activa;
- `gestionando`: hay trabajo o conversación en curso;
- `promesa_activa`: existe una promesa vigente;
- `esperando_comprobante`: el cliente declaró pago y falta evidencia o conciliación;
- `requiere_humano`: disputa, negociación o excepción fuera de reglas;
- `cerrado`: sin saldo gestionable o cierre explícito con motivo.

Estos estados pertenecen al caso de cobranza, no a cada `customer_receivable`.

### Tarea durable

Debe incluir, como mínimo:

- empresa y caso;
- tipo de tarea;
- fecha de ejecución y motivo obligatorio;
- prioridad y canal;
- intentos, lease y backoff;
- clave de idempotencia;
- ejecución asociada, resultado y timestamps.

Solo podrá existir una tarea pendiente equivalente por caso, tipo y propósito verificable.

### Ejecución y acción

Cada corrida registra inicio, término, modelo, consumo, error y resultado. Cada herramienta invocada registra argumentos seguros, validación aplicada y efecto producido. Datos sensibles innecesarios no deben entrar a trazas de proveedores.

### Propuesta y aprobación

Una propuesta conserva:

- acción sugerida;
- contenido o parámetros estructurados;
- evidencia utilizada;
- motivo y riesgo;
- estado `pendiente`, `aprobada`, `rechazada`, `expirada` o `aplicada`;
- persona decisora, fecha y motivo de decisión.

La aprobación no ejecuta SQL desde el agente: llama una RPC de dominio que revalida permisos, vigencia, saldo y concurrencia.

### Conversación

El hilo se liga al caso, cliente, contacto y canal. Los mensajes conservan identidad externa, dirección, estado de entrega, timestamps y referencias al proveedor. Los adjuntos o comprobantes deben seguir una política explícita de almacenamiento y retención.

## 6. Herramientas permitidas al agente

La primera versión expondrá funciones pequeñas, tipadas y validadas. Ejemplos:

- `consultar_contexto_cobranza(caso_id)`;
- `crear_propuesta_contacto(caso_id, canal, contenido, motivo)`;
- `registrar_promesa_declarada(caso_id, monto, fecha, evidencia)`;
- `programar_seguimiento(caso_id, fecha, motivo)`;
- `solicitar_comprobante(caso_id, motivo)`;
- `marcar_disputa(caso_id, motivo, evidencia)`;
- `escalar_humano(caso_id, motivo, prioridad)`;
- `cerrar_gestion_sin_contacto(caso_id, motivo)`.

No se expondrán herramientas para:

- registrar pagos sin el flujo canónico de CxC;
- modificar importes o vencimientos de documentos;
- aprobar descuentos o convenios;
- cambiar límites de crédito;
- suspender clientes;
- borrar auditoría o conversaciones;
- ejecutar SQL libre.

## 7. Reglas deterministas mínimas

Antes de contactar o ejecutar una herramienta, Satrapy revalidará:

- saldo abierto y condición de vencimiento;
- empresa y permisos del actor técnico;
- existencia de un contacto y canal autorizado;
- zona horaria, horario y días permitidos;
- frecuencia máxima por cliente y canal;
- ausencia de pago reciente no conciliado;
- ausencia de disputa, exclusión o solicitud de no contacto;
- vigencia de la propuesta y del saldo que la originó;
- límites de monto y acciones que obligan escalamiento humano.

Los valores concretos de horarios, frecuencias y umbrales serán configuración empresarial versionada, no constantes particulares en componentes reutilizables.

## 8. Plan por fases

### Fase 0 — Descubrimiento y política operativa

**Estado verificado el 2026-08-12:** completada en descubrimiento y diseño. La
aprobación operativa es una compuerta de activación del piloto, no un bloqueo para
desarrollar la Fase 1.

**Trabajo**

- Medir cartera real y calidad de contactos.
- Documentar el proceso actual de cobranza y responsables.
- Definir horarios, frecuencia, exclusiones y escalamiento.
- Clasificar acciones por riesgo: automática, aprobable o prohibida.
- Definir métricas y población del piloto.

**Criterio de salida de descubrimiento y diseño**

- Volumen medido y política operativa especificada con estado de aprobación
  explícito; si no está aprobada, queda como compuerta obligatoria de activación.
- Ningún umbral crítico queda únicamente en texto de prompt.
- Población piloto identificable mediante consulta reproducible.

#### Evidencia de ejecución de Fase 0

- Se añadió la consulta de solo lectura
  [`automatizacion-cobranza-fase-0.sql`](./automatizacion-cobranza-fase-0.sql),
  con fecha de corte explícita. Agrupa por empresa y cliente; mide clientes y
  documentos abiertos/vencidos, montos, vencimiento más antiguo, faltantes de
  teléfono/correo y pagos históricos de los últimos 90 días. No copia datos de
  Alpha ni crea entidades de automatización.
- La consulta se ejecutó el 2026-08-12 contra la base local
  `supabase_db_satrapy-validation`, que estaba saludable. Resultado real: **0
  empresas y 0 filas medibles**. Por tanto, este entorno no demuestra el volumen
  aproximado de 2 MDP ni permite dimensionar lotes, concurrencia, límites diarios
  o costos.
- La medición se ejecutó además, exclusivamente con lecturas paginadas, contra la
  empresa canónica `Teza Agricultura Sustentable`: **264 clientes**, **822
  documentos** y **$3,237,363.44** abiertos y vencidos. El vencimiento abierto
  más antiguo es 2025-06-30. La antigüedad se concentra en **$380,512.00** de
  31–60 días, **$545,442.88** de 61–90 días y **$2,311,408.56** de más de 90 días.
  Hay 1 cliente vencido sin teléfono, 264 sin correo y 1 sin ningún canal. El
  historial canónico disponible contiene 2 pagos por $2.00 en los últimos 90
  días, insuficiente para inferir comportamiento histórico.
- La inspección del esquema confirmó como fuentes canónicas
  `customer_receivables`, `customer_contacts` y `receivable_payments`. No existe
  una tabla canónica de promesas de cobranza; no se creó una porque su proceso y
  reglas aún no están aprobados.
- El flujo actual comprobable en el repositorio es una bandeja paginada por
  cliente mediante `list_receivable_customers`, expediente con contacto y
  documentos abiertos, y registro manual de abonos con aplicación FIFO e
  idempotencia. Los responsables operativos fuera del sistema no pueden inferirse
  del código.
- Se documentó la
  [`política operativa propuesta`](./automatizacion-cobranza-fase-0-politica.md),
  incluyendo proceso observable, volumen manual advertido, parámetros que deben
  ser configuración versionada, exclusiones, detenciones, matriz de riesgo y
  métricas. No se aplicó ningún parámetro a datos ni se habilitaron contactos.
- La consulta reproducible identifica un piloto propuesto de 25 clientes con más
  de 90 días, teléfono canónico y orden determinista por monto vencido. El tamaño
  es un parámetro explícito sujeto a aprobación, no una regla de producto. La
  ejecución encontró **223 clientes elegibles**; los primeros 25 representan
  **$1,672,618.63** vencidos.

**Criterio de salida:** cumplido para descubrimiento y diseño. El volumen está
medido, los parámetros críticos están especificados fuera de prompts y la
población piloto es reproducible. La política permanece `no aprobada`: responsable
operativo, responsable de escalamiento, horario, frecuencia y autorización del
piloto podrán definirse después, pero serán obligatorios antes de generar trabajo
operativo o habilitar canales. Ningún dato de Teza fue modificado.

**Compuerta de activación:** mientras la política empresarial esté incompleta o
no aprobada, Satrapy debe mostrar el estado `no configurado`; no debe sustituir
datos faltantes con valores permisivos, generar tareas operativas, reclamar
tareas, enviar mensajes ni iniciar llamadas. Los valores descritos en la política
de Fase 0 son propuestas de diseño, no configuración vigente.

### Fase 1 — Fundación durable de automatización

**Estado verificado el 2026-08-12:** implementación completada, migración aplicada
al entorno conectado y frontend autenticado validado en escritorio. El código de
Fases 0–1 quedó consolidado para producción en `a5cead5`. No se inició la Fase 2
ni se modificaron saldos, clientes, contactos o pagos de Teza.

**Backend**

- Crear casos, tareas, ejecuciones, acciones y propuestas.
- Crear configuración empresarial versionada con estado explícito `no
  configurado`, validación de completitud, vigencia, autor, motivo y auditoría.
- Impedir server-side la generación y reclamación de tareas operativas mientras
  la configuración esté incompleta, vencida o no aprobada.
- Implementar RPC de reclamación por lote con lease y `SKIP LOCKED`.
- Implementar intentos máximos, backoff, idempotencia y cancelación.
- Incorporar permisos, RLS y auditoría transaccional.
- Crear worker Node.js/TypeScript separado.

**Frontend**

- Mostrar estado técnico de tareas y errores solo a roles autorizados.
- Añadir bandejas básicas: pendientes, programadas, completadas y fallidas.

**Criterio de salida**

- Una empresa sin política completa y aprobada no puede generar ni reclamar
  tareas operativas; tampoco recibe valores permisivos por defecto.
- Dos workers no reclaman la misma tarea.
- Una caída libera la tarea al expirar el lease.
- Un reintento no duplica acciones.
- El flujo funciona sin OpenAI ni Twilio.

#### Evidencia de ejecución de Fase 1

- La migración `202608120003_collection_automation_foundation.sql` crea permisos
  separados de consulta/gestión, políticas empresariales versionadas, casos,
  tareas, ejecuciones, acciones y propuestas con RLS por empresa. No genera casos
  desde CxC ni duplica saldos.
- La configuración inicia efectivamente como `not_configured`. Las RPC auditadas
  crean borradores y aprueban versiones completas; el servidor bloquea encolado y
  reclamación cuando la política está incompleta, vencida o no aprobada. No hay
  valores operativos permisivos por defecto.
- La cola reclama lotes de 1–100 tareas con `FOR UPDATE SKIP LOCKED`, lease de
  15–900 segundos, recuperación de leases vencidos, máximo de intentos, backoff
  exponencial acotado, estados terminales e idempotencia por empresa y ejecución.
- `scripts/collection-worker.ts` es un proceso Node.js/TypeScript separado. En
  esta fase solo admite `internal_healthcheck`; no importa ni invoca OpenAI,
  Twilio, correo o WhatsApp.
- La bandeja interna `CxC → Gestiones` usa RPC paginada y muestra
  pendientes, programadas/en proceso, completadas, fallidas y canceladas. Solo
  `super_admin` y `direccion_admin` reciben los permisos; estados dinámicos usan
  regiones anunciables y controles nativos.
- La prueba transaccional local
  `202608120001_collection_automation_foundation.sql` comprobó: empresa sin
  política bloqueada; encolado idempotente; primer worker reclama una tarea;
  segundo worker obtiene cero; el lease expirado permite reclamarla; la
  finalización produce una sola acción. La prueba terminó con `DO` y `ROLLBACK`.
- Verificaciones ejecutadas: 282 pruebas TypeScript aprobadas, ESLint aprobado,
  build de producción aprobado y `git diff --check` sin errores.
- La validación autenticada comprobó la navegación interna de CxC en escritorio:
  `Cartera | Gestiones`. La ruta dejó de aparecer como sección independiente de
  Ventas, conserva autorización para Superadmin/Administrador y presenta
  `Gestiones de cobranza`. Se corrigió un defecto que excluía la ruta interna del
  conjunto autorizado al ocultarla del menú principal.

**Criterio de salida técnico:** cumplido. Los cuatro comportamientos durables se
demostraron sin OpenAI ni Twilio. La publicación conserva la empresa en estado
`No configurado`: no habilita generación/reclamación de tareas, mensajes,
llamadas ni otros canales.

#### Publicación de Fases 0–1

- Alcance: diagnóstico reproducible, política propuesta, fundación durable,
  worker determinista y vista interna `Gestiones` dentro de CxC.
- Validación previa: 282 pruebas generales (incluidas 5 específicas), prueba SQL
  transaccional, ESLint, build de producción y `git diff --check` aprobados.
- Publicación: implementación funcional consolidada en el commit `a5cead5` de
  `main`; este apartado documental registra la evidencia de su liberación a
  `origin/main`.
- Base de datos: la migración de Fase 1 fue ejecutada por el usuario en el
  Supabase conectado; se verificaron por lectura los permisos
  `view_collection_automation` y `manage_collection_automation` y sus asignaciones
  a Superadmin/Administrador.
- Seguridad operativa: política no aprobada y empresa `No configurada`; el
  despliegue no autoriza trabajo de cobranza real.

### Fase 2 — Cobranza operativa sin IA

**Estado de cierre de implementación el 2026-08-13:** completada en la rama
`codex/cobranza-fase-2`, validada contra la base local desechable y comprobada
en la empresa QA conectada. Las migraciones de Fase 2 y el parche de lectura
(`202608120003`, `202608130005` y `202608130006`) ya fueron aplicados al QA;
el usuario confirmó su ejecución posterior en el Supabase de producción. No se
configuró ni aprobó automáticamente la política operativa de ninguna empresa.

**Backend**

- Generar casos agrupados por cliente desde CxC.
- Calcular prioridad con reglas deterministas.
- Registrar responsables, próximas acciones, promesas y disputas.
- Detener tareas al confirmar pagos o cierres.
- Generar seguimientos por lote, nunca documento por documento.

**Frontend**

- Extender la vista actual de Cuentas por cobrar.
- Resumen: saldo abierto, vencido, promesas y monto recuperado.
- Bandeja priorizada por cliente con filtros y paginación server-side.
- Expediente con documentos, pagos, contacto, promesas y cronología.
- Acciones manuales: registrar promesa, programar, escalar y cerrar con motivo.

**Criterio de salida**

- La cartera completa puede gestionarse desde una bandeja agrupada.
- Los saldos continúan proviniendo exclusivamente de CxC.
- Toda próxima acción tiene fecha, motivo y responsable.

#### Evidencia de implementación de Fase 2

- La migración `202608120005_collection_operations.sql` extiende el caso por
  cliente con responsable, próxima acción, prioridad determinista y cierre; añade
  promesas auditadas sin duplicar saldos de CxC.
- La configuración ya es administrable desde `Gestiones`: se captura una
  política explícita (horario, frecuencia, límites y responsables), se guarda
  como borrador y se aprueba con motivo. Sin esa aprobación, la sincronización y
  las acciones operativas permanecen bloqueadas tanto en interfaz como en RPC.
- `collection_sync_cases` procesa hasta 500 clientes por lote y devuelve un
  cursor reanudable. Crea un único caso por empresa y cliente, actualiza
  prioridades y cierra casos sin saldo; la interfaz encadena los lotes hasta
  terminar la cartera sin recorrer documentos manualmente.
- `collection_generate_followups` genera tareas internas vencidas por lote e
  idempotencia. El worker solo admite trabajo determinista
  `internal_healthcheck` e `internal_follow_up`; no integra IA ni canales.
- Un trigger sobre la liquidación del último documento cierra el caso, cumple la
  promesa activa y cancela tareas pendientes. El registro canónico del pago sigue
  perteneciendo exclusivamente a CxC.
- Las RPC manuales registran seguimiento, promesa, escalamiento y cierre con
  permisos, revalidación, responsable y motivo. El expediente reúne documentos,
  pagos, contacto, promesas, bloqueos y cronología. Disputa y solicitud de no
  contacto son bloqueos explícitos y auditados que cancelan las tareas hasta su
  resolución; una promesa vencida pasa a incumplida y un pago confirmado por CxC
  puede cumplirla automáticamente.
- El monto recuperado se calcula con pagos confirmados desde la apertura del
  caso y la respuesta publica expresamente esa base de cálculo.
- `202608130008_collection_case_read_repairs.sql` corrige la lectura del folio
  desde `canonical_tickets` (en lugar de una columna inexistente en `sales`) y
  conserva el saldo abierto desde los documentos canónicos de CxC. La interfaz
  separa saldo abierto de vencido y muestra un reintento accesible si falla la
  consulta del expediente.
- La vista autenticada `CxC → Gestiones` ofrece resumen, filtros server-side,
  paginación por cliente, expediente y acciones manuales. Se validó a 1280 × 800
  CSS sin desbordamiento horizontal. En QA se registró una promesa de prueba de
  $2.32 para el 20/08/2026 y apareció en el resumen, el expediente y la
  cronología con estado `En gestión`.
- La reconstrucción completa de la base local aplicó todas las migraciones. Las
  tres pruebas transaccionales (fundación, operación y cierre) terminaron con
  `DO` y `ROLLBACK`, incluyendo una cartera de 501 clientes para comprobar el
  cursor; ESLint y el build de producción aprobaron.

**Criterio de salida técnico:** cumplido en código, base local, QA conectado y
Supabase de producción. Las migraciones `202608120003`, `202608130005` y
`202608130006` fueron ejecutadas en producción por el usuario el 2026-08-13.
La activación operativa por empresa permanece separada: un responsable debe
configurar y aprobar explícitamente su política real antes de generar trabajo.

### Fase 3 — Agente asistido y aprobaciones

**Estado técnico el 2026-08-16:** Fase 3 cerrada al 100% en
`codex/cobranza-fase-3`, con la migración final aplicada al Supabase conectado y
QA autenticado completado. La entrega incorpora
Agents SDK, salida estructurada, herramienta de contexto canónico de solo lectura,
guardrail por caso, trazas sin contenido sensible, consumo y costo estimado,
generación por lotes, aprobación revalidada, aplicación explícita sin envío,
historial contextual y minimización de datos en navegador.

**Backend/worker**

- Integrar OpenAI Agents SDK en TypeScript.
- Definir herramientas cerradas con Zod y guardrails por herramienta.
- Generar resumen, recomendación y borrador estructurado.
- Guardar evidencia, propuesta, trazas mínimas y costo.
- Incorporar aprobación humana revalidada por RPC.

**Frontend**

- Bandeja `Esperando aprobación`.
- Panel de propuesta con evidencia y motivo.
- Acciones: editar, aprobar, reprogramar y rechazar con motivo.
- Historial legible de lo consultado, propuesto, aprobado y aplicado.
- Conversación contextual dentro del expediente del cliente.

**Criterio de salida**

- El agente no puede ejecutar acciones financieras sensibles.
- Toda propuesta puede explicarse y reconstruirse.
- Una propuesta vencida o basada en saldo cambiado no puede aplicarse.

#### Evidencia técnica de Fase 3

- El worker registra modelo, versión, tokens, costo estimado y `trace_id` en la
  ejecución; el trazo excluye entradas y salidas sensibles y se vacía antes de
  terminar el proceso de una sola corrida.
- La propuesta se crea idempotentemente por tarea. Aprobar y aplicar son pasos
  distintos; ambos revalidan caso, saldo, vigencia y bloqueos. Aplicar sólo deja
  el borrador listo para un canal futuro y registra expresamente
  `outbound_sent=false`.
- La bandeja no recibe modelo, prompt, evidencia técnica ni UUID internos. Se
  revocó además la lectura directa de propuestas, ejecuciones y acciones para
  `authenticated`; las lecturas operativas usan RPC con respuesta mínima.
- El expediente reconstruye propuestas, decisiones y aplicación como contexto
  asistido legible, sin convertirlo en un CRM ni inventar conversaciones de un
  canal que todavía no existe.
- La prueba SQL transaccional `202608170001_collection_assisted_agent.sql`
  comprobó telemetría, aislamiento multiempresa, cambio de saldo, aplicación
  única, historial y ausencia de privilegios directos; terminó con `DO` y
  `ROLLBACK`.
- El QA autenticado comprobó el flujo completo sobre una propuesta de prueba:
  revisión, aprobación, aplicación separada, historial contextual y ausencia
  de envío. La bandeja terminó con cero pendientes y la interfaz no mostró
  modelo, prompt, trazas ni UUID técnicos.
- Las 14 pruebas específicas aprobaron, junto con ESLint, TypeScript y build de
  producción mediante Webpack. La suite general aprobó 329 de 334 pruebas; las
  cinco fallas preexistentes pertenecen a navegación contable, Centro de
  Migración, presupuestos y CxP, fuera del alcance de cobranza.

### Fase 3.5 — Evaluaciones y control de versiones del agente

**Calidad y seguridad**

- Crear un conjunto versionado de casos reales anonimizados y casos límite de cobranza.
- Simular respuestas frecuentes: promesa, pago realizado, disputa, negativa, ambigüedad y solicitud de no contacto.
- Evaluar exactitud, evidencia utilizada, cumplimiento de reglas y selección correcta de herramientas.
- Comparar versiones de prompt, herramientas y modelo antes de promoverlas al piloto.
- Bloquear despliegues que empeoren los umbrales acordados o intenten acciones no autorizadas.

**Criterio de salida**

- Cada versión del agente tiene resultados reproducibles y trazables.
- Ninguna versión llega a clientes reales sin superar la batería mínima de evaluación.
- Los incidentes del piloto se convierten en nuevos casos de regresión.

### Fase 4 — Correo y WhatsApp con bandeja unificada

**Backend**

- Conectar un número de WhatsApp Business para el piloto.
- Conectar el buzón de cobranza autorizado mediante la API oficial del proveedor de correo.
- Gestionar plantillas y consentimiento aplicable.
- Verificar firmas de webhooks y deduplicar eventos.
- Encolar recepción, entrega, lectura, fallo y respuestas.
- Asociar conversación, contacto y caso mediante identidades canónicas.
- Normalizar correo y WhatsApp bajo una conversación del caso sin perder el mensaje original ni sus metadatos.
- Generar borradores aprobables; el envío automático queda fuera de V1 salvo reglas de bajo riesgo expresamente autorizadas.

**Frontend**

- Vista previa antes de aprobar.
- Estado enviado, entregado, leído, respondido o fallido.
- Bandeja unificada de correo y WhatsApp con filtros por canal, estado y necesidad de intervención.
- Acceso al hilo completo desde el caso.

**Criterio de salida**

- Ningún webhook modifica directamente CxC.
- Reintentos del proveedor no duplican mensajes ni acciones.
- La solicitud de no contacto detiene futuras comunicaciones aplicables.
- Una persona puede revisar el historial conjunto y responder sin reconstruir el contexto entre canales.

### Fase 5 — Estrategia escalonada

Configurar recorridos empresariales versionados, por ejemplo:

1. recordatorio cordial;
2. segundo seguimiento;
3. solicitud de fecha de pago;
4. solicitud de comprobante;
5. llamada o revisión humana;
6. escalamiento administrativo.

Cada paso tendrá condición de entrada, salida, espera, límite de intentos y acción ante respuesta. El agente puede recomendar el recorrido; Satrapy valida y ejecuta las transiciones.

**Criterio de salida**

- Ningún cliente recibe contactos duplicados por documentos distintos.
- Los recorridos se detienen por pago, disputa, exclusión o intervención humana.

### Fase 6 — Llamadas piloto

**Arquitectura**

- Twilio Programmable Voice inicia o recibe la llamada.
- ConversationRelay mantiene STT/TTS y sesión de voz.
- Un servidor WebSocket persistente conecta Twilio con el agente.
- Satrapy entrega únicamente el contexto necesario y registra el resultado.

**Alcance inicial**

- Identificar claramente al asistente automatizado.
- Recordar saldo y documentos autorizados.
- Confirmar reconocimiento del adeudo.
- Solicitar una fecha declarada de pago.
- Transferir a una persona ante negociación, disputa o solicitud expresa.

**Exclusiones**

- No negociar descuentos o convenios.
- No amenazar ni comunicar consecuencias no autorizadas.
- No capturar datos de tarjeta.
- No usar clonación de voz de empleados.
- No incorporar Fish Audio en V1; primero se evaluará el TTS integrado de ConversationRelay.

**Criterio de salida**

- Piloto controlado con grabación/transcripción según política y consentimiento aplicable.
- Transferencia humana probada.
- Métricas de latencia, abandono, quejas y recuperación aceptables.

### Fase 7 — Autonomía gradual y expansión

- Autorizar automáticamente solo mensajes de bajo riesgo y plantillas aprobadas.
- Evaluar resultados por estrategia, canal y segmento.
- Añadir preparación de reuniones y seguimiento de cotizaciones sobre la misma infraestructura.
- Extender a proveedores u otras operaciones únicamente con casos de negocio comprobados.

La autonomía se habilitará por acción y empresa, con interruptor de desactivación, límites y revisión periódica.

## 9. Diseño del frontend

La capacidad vivirá dentro de **Cuentas por cobrar** durante las primeras fases. No se creará otra aplicación ni se duplicará el expediente financiero.

### Navegación inicial

- `Ventas → Cuentas por cobrar` conserva cartera, documentos y registro de abonos.
- Se agregan vistas o pestañas de `Cartera`, `Gestiones`, `Aprobaciones` e `Historial`.
- `Gestiones` incluye una bandeja unificada de correo y WhatsApp ligada al expediente de cobranza.
- Un módulo superior `Automatización` solo se justificará cuando existan varios casos reales además de cobranza.

### Bandeja de cobranza

Cada fila representa un cliente e incluye:

- saldo abierto y vencido;
- vencimiento más antiguo;
- estado del caso;
- promesa vigente o incumplida;
- último contacto y próxima acción;
- canal y responsable;
- indicador de intervención humana.

La tabla tendrá búsqueda, filtros, orden y paginación server-side. No cargará toda la cartera en el navegador.

### Expediente

- Resumen financiero proveniente de CxC.
- Contactos y canales disponibles.
- Documentos y pagos existentes.
- Promesas, disputas y comprobantes.
- Cronología conjunta de acciones humanas, agente y proveedor.
- Propuesta visible con evidencia antes de aprobar.

### Validación visual

Toda validación se realizará con sesión autenticada, en escritorio de al menos **1180 × 700 CSS**. Se verificará navegación por teclado, foco, estados de carga, permisos, errores y reintentos.

## 10. Permisos y aprobación

Permisos conceptuales a validar:

- consultar automatización de cobranza;
- gestionar casos y seguimientos;
- revisar propuestas del agente;
- aprobar comunicaciones;
- configurar políticas y canales;
- consultar auditoría técnica y costos.

Matriz inicial:

| Acción | Agente | Persona autorizada | Satrapy/RPC |
| --- | --- | --- | --- |
| Consultar contexto permitido | Solicita | — | Autoriza y filtra |
| Priorizar cartera | Recomienda | Revisa reglas | Calcula base determinista |
| Preparar mensaje | Sí | Edita/aprueba en V1 | Conserva propuesta |
| Enviar WhatsApp | Solicita | Aprueba en V1 | Revalida y despacha |
| Enviar correo | Solicita | Edita/aprueba en V1 | Revalida y despacha |
| Registrar promesa declarada | Extrae/proporciona evidencia | Revisa excepciones | Valida y registra |
| Registrar pago | No | Usa flujo actual | Ejecuta CxC canónica |
| Ofrecer descuento o convenio | No en V1 | Decide en flujo futuro | Valida límites y aprobación |
| Escalar caso | Propone | Acepta o atiende | Registra responsable y motivo |

## 11. Auditoría y observabilidad

Satrapy deberá poder responder:

- qué originó una tarea;
- qué datos consultó el agente;
- qué recomendó y con qué evidencia;
- qué herramienta intentó usar;
- qué regla permitió o bloqueó la acción;
- quién aprobó, editó o rechazó;
- qué envió Twilio y qué estado reportó;
- qué respuesta recibió el cliente;
- qué costo, latencia y resultado tuvo la ejecución.

Las acciones de negocio relevantes se registrarán en la misma transacción que su efecto. Las trazas de OpenAI y Twilio complementan la auditoría, pero no la sustituyen.

## 12. Seguridad, privacidad y cumplimiento

- Credenciales de OpenAI y Twilio solo en backend.
- RLS por empresa y permisos explícitos.
- Verificación de firmas y deduplicación de webhooks.
- Minimización de datos enviados a proveedores.
- Política de retención para mensajes, transcripciones, grabaciones y comprobantes.
- Identificación clara del asistente automatizado.
- Consentimiento y reglas aplicables para WhatsApp, llamadas y grabación.
- Prohibición de almacenar datos de tarjeta o secretos en prompts, trazas o callbacks.
- Revisión legal antes de llamadas salientes automatizadas a escala.

## 13. Métricas del piloto

### Negocio

- monto recuperado y porcentaje de cartera recuperada;
- días promedio hasta pago;
- promesas creadas, cumplidas e incumplidas;
- clientes contactados y tasa de respuesta;
- recuperación por canal y estrategia;
- casos resueltos sin escalamiento.

### Operación y calidad

- propuestas aprobadas sin edición, editadas y rechazadas;
- contactos duplicados o fuera de política;
- disputas y solicitudes de no contacto;
- transferencias a persona y tiempo de atención;
- errores, reintentos y tareas agotadas;
- costo por contacto y por peso recuperado;
- latencia en WhatsApp y llamadas.
- resultados de evaluaciones por versión y regresiones detectadas antes del despliegue;
- respuesta y recuperación por correo, WhatsApp y combinación de canales.

## 14. Riesgos y mitigaciones

| Riesgo | Mitigación |
| --- | --- |
| Contactar saldo ya pagado | Revalidar saldo antes de enviar y cancelar por evento de pago |
| Promesa inventada o mal interpretada | Guardar evidencia textual y solicitar revisión en casos ambiguos |
| Contacto excesivo | Límites server-side por cliente, canal y periodo |
| Duplicidad por reintentos | Idempotency keys, unicidad y webhook inbox |
| Agente ofrece condiciones no autorizadas | Herramientas cerradas y ausencia de herramienta para negociar |
| Fuga de información entre empresas | RLS, contexto por `company_id` y pruebas de aislamiento |
| Caída del worker o proveedor | Lease, backoff, intentos y estados terminales visibles |
| Daño reputacional por llamadas | Piloto pequeño, identificación automática y transferencia humana |
| Dependencia de proveedor | Contratos internos de canal; Satrapy conserva conversaciones y estado |

## 15. Exclusiones de V1

- CRM completo, leads, campañas y pipeline comercial.
- LangGraph, CrewAI, Vapi, Retell o una base vectorial.
- Otro ERP o una segunda base de cartera.
- Microservicios por cada agente o canal.
- Llamadas autónomas a toda la cartera.
- Negociación automática de descuentos o convenios.
- Registro automático de pagos a partir de mensajes o comprobantes.
- Fish Audio o clonación de voz.
- Automatización de proveedores, cotizaciones u otros módulos antes de validar cobranza.
- Portal de autoservicio para clientes y pagos.
- Gestión avanzada de disputas y deducciones.
- Predicción de fecha o probabilidad de pago y pronóstico de flujo con IA.
- Optimización automática de canal, horario o estrategia.

## 16. Orden de ejecución recomendado

1. Aprobar Fase 0 y medir la cartera real.
2. Diseñar y validar migraciones/RPC de Fase 1.
3. Entregar Fase 2 y operar cobranza sin IA.
4. Añadir propuestas del agente y aprobación humana.
5. Validar el agente con casos de evaluación y bloquear regresiones.
6. Pilotear correo y WhatsApp con una bandeja unificada y un grupo controlado.
7. Medir recuperación y ajustar reglas.
8. Pilotear llamadas solo si los canales escritos y la operación humana justifican el costo y riesgo.
9. Ampliar autonomía únicamente con evidencia del piloto.

## 17. Decisiones pendientes antes de implementar

- Volumen real y población del piloto.
- Roles responsables y matriz definitiva de permisos.
- Horarios, frecuencia y política de no contacto.
- Definición legal de consentimiento, grabación y retención.
- Número de WhatsApp y cuenta Twilio propietarios de la empresa.
- Proveedor, buzón y política de acceso para correo de cobranza.
- Política de aprobación por canal y segmento.
- Umbrales de prioridad y escalamiento.
- Infraestructura donde vivirá el worker y el WebSocket de voz.
- Presupuesto máximo de OpenAI y Twilio.

No se iniciarán integraciones externas hasta cerrar estas decisiones y demostrar que los casos, tareas y reglas funcionan de forma determinista dentro de Satrapy.
