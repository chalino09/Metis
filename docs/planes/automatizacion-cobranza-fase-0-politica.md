# Fase 0 · política operativa propuesta para cobranza

**Empresa piloto:** Teza Agricultura Sustentable

**Fecha de corte:** 2026-08-12

**Estado:** descubrimiento y diseño completados; política no aprobada y no
configurada en Satrapy

Este documento define el contrato operativo que deberá convertirse en
configuración empresarial versionada en una fase posterior. No autoriza envíos,
llamadas ni cambios en clientes, saldos, pagos o contactos.

## Proceso actual comprobable

Satrapy ofrece una bandeja paginada por cliente con saldo abierto, expediente con
contacto y documentos, y registro manual de abonos con aplicación FIFO e
idempotencia. El saldo proviene de `customer_receivables`; los contactos, de
`customer_contacts`; los cobros registrados, de `receivable_payments`.

Los datos importados incluyen vendedor para casi todos los clientes consultados,
pero no asignan encargado de pagos. Un vendedor importado no se considerará
automáticamente responsable de cobranza. Teza debe designar un responsable del
piloto y un responsable de escalamiento antes de operar.

Volumen operativo esperado del piloto: hasta 25 casos por lote, una sola vez al
día durante la etapa asistida. Cada caso agrupa todos los documentos del cliente;
no se capturará ni contactará documento por documento. Con 264 clientes vencidos,
una revisión manual individual de toda la cartera no es un arranque aceptable.

## Parámetros propuestos para aprobación

| Parámetro | Valor propuesto | Motivo |
| --- | --- | --- |
| Zona horaria | `America/Mexico_City` | Contexto operativo de la empresa |
| Días permitidos | lunes a viernes | Piloto conservador |
| Horario permitido | 09:00–18:00 | Evitar contacto fuera de jornada |
| Frecuencia por cliente | máximo 1 contacto cada 72 horas | Limitar insistencia y duplicidad |
| Intentos sin respuesta | máximo 3; después revisión humana | Evitar ciclos indefinidos |
| Tamaño inicial | 25 clientes | Lote revisable antes de ampliar |
| Antigüedad mínima del piloto | más de 90 días | Segmento material: $2,311,408.56 |
| Canal inicial | preparación manual basada en teléfono; sin envío automático | Teza no tiene correos canónicos en la cartera medida |

Estos valores no deben residir únicamente en un prompt. Tras aprobación deberán
persistirse por empresa con versión, vigencia, autor, motivo y auditoría. Cambiar
un valor requerirá una nueva versión; las tareas conservarán la versión aplicada.

## Exclusiones y detenciones obligatorias

- Sin saldo abierto o con pago confirmado después de originar la gestión.
- Sin teléfono o correo canónico autorizado.
- Solicitud de no contacto.
- Disputa, identidad dudosa o desacuerdo sobre saldo/documentos.
- Pago declarado pendiente de evidencia o conciliación.
- Intervención humana activa.
- Fuera de horario, frecuencia excedida o política no vigente.

Una detención bloquea trabajo de cobranza; no modifica la pertenencia comercial
del cliente ni corrige documentos financieros.

## Matriz de riesgo inicial

| Acción | Clasificación V1 | Condición |
| --- | --- | --- |
| Consultar contexto y resumir cartera | Automática | Consulta autorizada y auditada |
| Priorizar con reglas aprobadas | Automática | Cálculo determinista server-side |
| Programar una tarea interna | Automática | Fecha, motivo, responsable y versión de política |
| Preparar borrador de contacto | Aprobable | Evidencia y saldo revalidados |
| Enviar mensaje o iniciar llamada | Aprobable | Aprobación humana previa en V1 |
| Registrar promesa declarada | Aprobable | Monto, fecha y evidencia; no equivale a pago |
| Solicitar comprobante | Aprobable | Canal autorizado y frecuencia válida |
| Marcar disputa o no contacto | Aprobable | Evidencia conservada; detiene tareas aplicables |
| Registrar un pago desde una conversación | Prohibida | Debe usar el flujo canónico de CxC |
| Cambiar saldo, vencimiento o documento | Prohibida | Autoridad financiera fuera del agente |
| Ofrecer descuento, convenio o amenaza | Prohibida | Fuera de V1 |
| Ejecutar SQL libre o borrar auditoría | Prohibida | Sin herramienta expuesta |

## Población y métricas del piloto

La consulta reproducible de Fase 0 selecciona hasta 25 clientes con saldo de más
de 90 días, teléfono canónico y mayor monto vencido. El tamaño se declara como
parámetro `pilot_size`; no está codificado en funcionalidad reutilizable. La
medición encontró 223 clientes elegibles; los primeros 25 concentran
$1,672,618.63 vencidos. Antes de
operar deben excluirse solicitudes de no contacto, disputas, pagos recientes e
intervenciones humanas cuando esas señales existan en el dominio de Fase 2.

Métricas mínimas: monto vencido incluido, clientes preparados/contactados,
respuestas, promesas declaradas, pagos confirmados por el flujo canónico, monto
recuperado, borradores editados/rechazados, contactos bloqueados por política,
duplicados, disputas, solicitudes de no contacto y tiempo de atención humana.

## Compuerta de activación pendiente

Teza deberá registrar nombre/rol y aprobación explícita antes de activar cualquier
piloto o canal, pero estas asignaciones no bloquean el desarrollo de la fundación
durable de Fase 1:

1. responsable operativo de cobranza;
2. responsable de escalamiento y excepciones;
3. autoridad que aprueba horarios, frecuencia, exclusiones, matriz de riesgo y
   población piloto.

Mientras falte cualquiera de estas definiciones, la empresa estará `no
configurada`: no se aplicarán valores permisivos por defecto y no podrán generarse
ni reclamarse tareas operativas, enviarse mensajes o iniciarse llamadas. La
aprobación autoriza la política; no modifica saldos, clientes, contactos o pagos.
