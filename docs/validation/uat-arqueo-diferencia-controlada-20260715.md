# UAT final — Aprobación de diferencia de caja

Fecha: 2026-07-15  
Entorno UAT: aplicación local autenticada contra el proyecto Supabase de validación  
Sucursal: SUC CUAPANCINGO (`CUAPA`)  
Caja: Caja principal · CUAPA 01

## Resultado final

**PASS.** Los dos P1 quedaron corregidos y probados. No se inició el Módulo 3.

| Criterio | Resultado | Evidencia |
| --- | --- | --- |
| Respuesta idempotente | PASS | El primer llamado cerró la sesión; el reintento con la misma clave devolvió `status: closed` e `idempotent: true`, sin responder “No hay diferencia pendiente”. |
| Efecto único | PASS | La sesión quedó en `closed` y existe exactamente un evento `cash_session.variance_approved`. |
| Rol asignable | PASS | `supervisor_sucursal` recibe únicamente `approve_cash_variance` y `view_cash_reports`. |
| Supervisor de la misma sucursal | PASS | Gloria, limitada a CUAPA, aprobó la diferencia de −MXN 1.00. |
| Supervisor de otra sucursal | PASS | Rechazado por `assert_pos_access` al no tener acceso a la ubicación de la caja. |
| Mismo cajero | PASS | Rechazado: se exige un aprobador autorizado distinto. |
| Contexto de lectura limitado | PASS | El supervisor puede consultar cajas y diferencias de su ubicación con `view_cash_reports`, sin recibir `use_pos` ni permisos para vender, abrir caja o registrar movimientos. |

## UAT real persistida

- Sesión: `07150000-0000-4000-8000-000000000030`.
- Cajero y solicitante: `josemilio780@gmail.com`.
- Aprobadora: `gloriavazquezhuerta@gmail.com`.
- Rol: `supervisor_sucursal`.
- Alcance explícito: CUAPA / SUC CUAPANCINGO.
- Esperado: MXN 19.00.
- Contado: MXN 18.00.
- Diferencia: −MXN 1.00.
- Resultado: `closed`.
- `closed_at`: `2026-07-15 19:57:53.660208+00`.
- Clave persistida: `57faf10f-c40a-48f9-b4c0-aab095d512e1`.
- Aprobaciones auditadas: `1`.
- Clave auditada: `57faf10f-c40a-48f9-b4c0-aab095d512e1`.

Respuesta observada al repetir exactamente la aprobación con la misma clave:

```json
{
  "status": "closed",
  "idempotent": true,
  "cash_session_id": "07150000-0000-4000-8000-000000000030",
  "variance_amount": -1
}
```

## Controles de seguridad

La función valida, en este orden, que el actor sea diferente del cajero/solicitante,
que tenga la capacidad `approve_cash_variance` en la empresa y que
`assert_pos_access` autorice la ubicación. El rol limitado no hereda permisos
operativos de POS.

Los escenarios negativos se ejecutaron tanto en el entorno remoto con cambios
transaccionales revertidos como en la regresión SQL versionada:

1. Supervisor limitado a otra sucursal: rechazo esperado.
2. Mismo cajero: rechazo esperado.
3. Reintento con la misma clave por el mismo aprobador: mismo cierre, sin segundo efecto.
4. Reutilización de la clave para otra sesión: rechazo esperado.

## Evidencia versionada

- Migración de contrato e idempotencia: `supabase/migrations/202607150011_cash_variance_approval_idempotency.sql`.
- Migración de contexto de lectura limitado: `supabase/migrations/202607150012_cash_supervisor_context.sql`.
- Prueba SQL: `supabase/tests/202607150011_cash_variance_approval_idempotency.sql`.
- Evidencia automatizada final: `docs/validation/evidence/20260715T195902Z`.
- Resumen automatizado: 23 PASS, 0 FAIL, incluido `concurrency_sales`, RLS, idempotencia, frontend lint y build.

## Diferencias pendientes

Ninguna para estos dos P1. La migración `202607150012` no reabre la arquitectura:
solo separa el acceso de lectura de supervisión (`view_cash_reports`) del permiso
operativo (`use_pos`).

## GO/NO-GO de esta UAT

**PASS / GO para dar por cerrados los dos P1.** Esta conclusión se limita a la
remediación solicitada; no constituye inicio ni autorización para comenzar el
Módulo 3.
