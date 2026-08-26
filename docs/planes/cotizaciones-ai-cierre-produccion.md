# Cotizaciones AI — cierre y salida a producción

Actualizado: 25 de agosto de 2026.

## Objetivo

Completar y validar el flujo:

`Mensaje → Preparación → Cotización → Aprobación → Pedido → Pago → Entrega → Venta registrada`

## Estado actual

- [x] Captura manual que simula un mensaje entrante de WhatsApp.
- [x] Detección de intención, cliente, productos y cantidades.
- [x] Revisión, cambio de producto, ajuste de cantidad y alta rápida de cliente.
- [x] Advertencia informativa de inventario insuficiente desde Preparación.
- [x] La falta de inventario no bloquea crear, aprobar ni enviar una cotización.
- [x] Cotización profesional con vista previa y descarga mediante React PDF.
- [x] Aprobación, envío, aceptación y conversión a pedido.
- [x] Bloqueo operativo del pedido cuando no existe inventario suficiente.
- [x] Registro de pago, entrega, descuento de inventario y venta en Historial.
- [x] Simulador para probar el flujo mientras Meta no proporciona el número de prueba.
- [x] Recepción real desde Cloud API con la eSIM y preparación correcta mediante IA.

## Pendiente antes de Meta

- [ ] Agregar **transferencia bancaria** como método de pago y conservar referencia, fecha y comprobante cuando aplique.
- [ ] Confirmar que al cambiar un producto durante la revisión se recalculen en servidor precio, impuestos, unidad y existencia de la nueva selección.
- [ ] Ejecutar todas las pruebas funcionales y de seguridad descritas abajo.
- [ ] Preparar variables, migraciones, respaldos, monitoreo y procedimiento de reversión para producción.

## Integración pendiente con Meta

Meta ya asignó un número de prueba y verificó el callback HTTPS de Satrapy.
El campo `messages` quedó suscrito. El simulador confirma el procesamiento interno,
pero la recepción real continuará separada en los dos recorridos siguientes.

- [x] Obtener número de prueba.
- [x] Capturar en Integraciones el WhatsApp Business Account ID, Phone Number ID, token de acceso, app secret y token de verificación del webhook.
- [x] Publicar y verificar el webhook HTTPS.
- [x] Recibir mensajes reales e implementar idempotencia mediante el identificador del mensaje de Meta.
- [ ] Enrutar cada número a su empresa y sucursal correspondientes.
- [ ] Probar primero con el número de Meta y después con los tres números de las sucursales.
- [ ] Configurar plantillas aprobadas para mensajes iniciados fuera de la ventana permitida por WhatsApp.
- [x] Registrar recepción, resultado, errores, reintentos y auditoría de cada mensaje.

El simulador se conserva para desarrollo y soporte, pero debe ocultarse o limitarse por permiso en producción.

### Laboratorio Cloud API con la eSIM

La eSIM sin operación comercial se usará como número dedicado de laboratorio.
No representa el modelo definitivo de las sucursales.

- [x] Confirmar que la eSIM recibe SMS o llamadas de verificación.
- [x] Liberar el número de cualquier cuenta anterior de WhatsApp Business.
- [x] Registrar y verificar la eSIM como número real en Meta.
- [x] Configurar el PIN de verificación en dos pasos y conservarlo fuera del repositorio en un gestor de secretos.
- [x] Actualizar en Satrapy su Phone Number ID y token de acceso permanente.
- [x] Completar la verificación necesaria para recibir webhooks reales en el laboratorio.
- [x] Enviar un mensaje desde un WhatsApp personal y confirmar su aparición en `Cotizaciones | Por preparar`.
- [ ] Repetir el mismo mensaje y confirmar idempotencia por identificador de Meta.

En Cloud API directa el número deja de operarse desde la aplicación WhatsApp
Business y se atiende mediante API. Las llamadas y los SMS de la línea celular
no se afectan. Por esta razón este recorrido sólo usará la eSIM de laboratorio.

### Coexistence para los números reales de Teza

Decisión operativa: los números reales de las sucursales no se migrarán a
Cloud API directa. Se adoptará WhatsApp Business App Coexistence para que el
personal continúe contestando en la aplicación y Satrapy detecte solicitudes de
cotización en paralelo. Las llamadas y los SMS continúan sin cambios.

- [ ] Implementar el alta de Coexistence mediante el flujo autorizado de Meta.
- [ ] Sustituir la unicidad actual por empresa/proveedor para admitir varios números de WhatsApp por empresa.
- [ ] Conservar una asignación durable y auditada entre Phone Number ID y sucursal.
- [ ] Procesar mensajes entrantes sin duplicar ecos o mensajes enviados por el personal.
- [ ] Iniciar en modo pasivo: detectar y preparar cotizaciones sin responder automáticamente.
- [ ] Incorporar una bandeja de respuesta antes de permitir automatización saliente desde Satrapy.
- [ ] Validar primero una sucursal y extender a las demás sólo después del UAT.

El webhook, la verificación de firma, la idempotencia y el procesamiento de
cotizaciones existentes se reutilizan. Cambian el onboarding, el modelo
multinumérico, el enrutamiento por sucursal y el tratamiento de eventos de
Coexistence.

## Pruebas finales obligatorias

### 1. Flujo completo

- [ ] Mensaje con cliente existente y producto con inventario suficiente.
- [ ] Mensaje con cliente desconocido y alta rápida.
- [ ] Mensaje ambiguo que requiera cambiar el producto sugerido.
- [ ] Cotización con inventario insuficiente: debe advertir, pero permitir crearla y aprobarla.
- [ ] Conversión a pedido sin inventario: debe bloquearse antes de cobrar o entregar.
- [ ] Reposición de inventario y continuación del mismo pedido.
- [ ] Pago completo, entrega y aparición de la venta en Historial.
- [ ] Cancelación o no concreción sin movimientos indebidos de inventario.

### 2. Permisos

- [ ] Un usuario de consulta no puede preparar, aprobar, cobrar ni entregar.
- [ ] Un vendedor puede operar únicamente las acciones y sucursales autorizadas.
- [ ] La aprobación y cada cambio registran usuario, fecha y evento.
- [ ] Una empresa no puede consultar clientes, cotizaciones, pedidos o integraciones de otra empresa.

### 3. Tres sucursales

- [ ] Cada número de WhatsApp se asigna a la sucursal correcta.
- [ ] Cliente, lista de precios, impuestos e inventario corresponden a esa sucursal.
- [ ] Una cotización de una sucursal no utiliza existencia de otra sin una operación explícita.
- [ ] Los tres números pueden recibir mensajes sin mezclar conversaciones o eventos.

### 4. Concurrencia e inventario

- [ ] Dos vendedores intentan crear pedidos simultáneos para la última existencia: solo uno puede reservarla.
- [ ] No existen reservas negativas ni doble descuento.
- [ ] Cancelar un pedido no pagado libera su reserva.
- [ ] Confirmar entrega descuenta una sola vez y genera un solo ticket.
- [ ] Repetir una petición por error de red no duplica pedido, pago, entrega ni venta.

### 5. Documento y pagos

- [ ] El PDF mantiene logo, datos fiscales, condiciones, colores, totales y paginación en escritorio e impresión.
- [ ] Efectivo, tarjeta y transferencia registran correctamente importe y referencia.
- [ ] No se puede registrar un pago superior o duplicado sin una regla explícita.
- [ ] La venta final concilia cotización, pedido, pagos, inventario y ticket.

### 6. Operación y producción

- [ ] Migraciones ejecutadas en orden y verificadas en una copia de producción.
- [ ] Credenciales cifradas y nunca visibles en cliente, logs o respuestas de error.
- [x] Webhooks con firma validada, persistencia previa, reclamo atómico, idempotencia y reintentos controlados implementados.
- [ ] Alertas para mensajes fallidos, inventario inconsistente y errores de conversión.
- [ ] Respaldo y procedimiento documentado de reversión.
- [ ] Prueba de aceptación en escritorio de al menos 1180 × 700 CSS.

## Criterio para publicar

Se puede publicar el flujo manual sin Meta cuando:

1. Transferencia bancaria esté terminada.
2. Las pruebas sin Meta estén aprobadas.
3. Migraciones, permisos, respaldos y monitoreo estén listos.

La recepción automática por WhatsApp se habilita después, cuando Meta entregue el número y las pruebas del webhook sean satisfactorias.
