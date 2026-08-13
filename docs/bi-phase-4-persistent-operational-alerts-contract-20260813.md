# BI Fase 4 · alertas operativas persistentes

## Volumen y frecuencia

- Esperado: 0–20 alertas abiertas y decenas o cientos de eventos históricos por empresa.
- Listado: páginas server-side de 25, límite validado de 100; no se descargan hechos al navegador.
- Evaluación: cada 30 minutos sobre los últimos 30 días, con bloqueo por empresa e idempotencia por `condition_key`.
- Latencia esperada de detección: hasta 30 minutos. Cada ejecución conserva principal, duración, periodo, estado y error.

## Reglas iniciales

1. `sales_decline`: ventas netas caen al menos 10%; crítica desde 25%, con base anterior y al menos 20 tickets.
2. `location_sales_decline`: sucursal cae al menos 15%; crítica desde 30%, con contribución absoluta mínima de 20%.
3. `gross_margin_unreliable`: ventas presentes sin margen confiable por cobertura insuficiente de costo reconocido.
4. `budget_behind_pace`: meta aprobada al menos 10 puntos porcentuales detrás del ritmo; crítica desde 25 puntos.

Son reglas deterministas versionadas, no detección estadística de anomalías. Una condición ausente en una evaluación posterior se resuelve automáticamente sólo cuando la regla lo permite. La resolución manual exige motivo.

## Seguridad y trazabilidad

- Lectura: `view_bi_alerts`; transición: `manage_bi_alerts`.
- RLS por empresa y RPCs `security definer` con validación explícita de permiso.
- El evaluador reutiliza resumen comparado, tabla operativa y seguimiento de metas canónicos.
- Cada detección, actualización, revisión y resolución queda en `bi_alert_events`; las acciones humanas también quedan en `audit_log`.

## Límites actuales

- No hay diseñador genérico de reglas, notificaciones externas, alertas predictivas ni aprendizaje automático.
- Las reglas cubren ventas, sucursal, calidad de margen y presupuesto; nuevas métricas requieren un caso operativo y contrato canónico comprobados.
- Fase 5 queda fuera de este cambio.
