# Compuerta técnica antes de mejora de UI

Fecha: 2026-07-29
Estado: **GO técnico para iniciar mejora de UI**

## Correcciones

- Se eliminó la versión duplicada de migración. Devoluciones conserva `202607280003`, arranque neutral `202607280004` y la conciliación CxC/Bancos usa `202607280005`.
- El contrato POS y su prueba de concurrencia usan la RPC pública vigente `complete_pos_sale`; la función interna `complete_sale` permanece sin ejecución directa para `authenticated`.
- Las regresiones históricas se alinearon con los contratos actuales de unidades de compra, evidencia bancaria de cobranza, pagos de nómina por forma de pago, estructura canónica de ubicaciones, inmutabilidad de presupuestos, posiciones de colaboradores y estados de OC/recepción/surtido.
- Los cobros externos aceptan evidencia financiera explícita válida en operaciones internas y siguen exigiendo cuenta receptora, moneda compatible y referencia en el flujo público.

## Evidencia reproducible

Comando:

```bash
npm run test:sql
```

Evidencia local:

`docs/validation/evidence/20260729T154836Z/summary.txt`

Resultado:

- 84 verificaciones aprobadas.
- 0 fallas.
- Instalación limpia y reset final aprobados.
- Regresiones SQL, ocho suites de concurrencia, fuentes Alpha disponibles, contratos frontend, lint y build aprobados.
- Permanece el bloqueo histórico `missing_separate_fiscal_source`; no es una falla de esta compuerta y no se infirió información fiscal.

## Smoke autenticado de escritorio

Entorno: aplicación local con sesión autenticada, viewport `1280 × 800` CSS.

- Ventas: el ticket canónico abre y ofrece la devolución auditada sin modificar el documento original. El formulario presenta cantidad disponible, condición de reintegro, motivo obligatorio y confirmación bloqueada mientras falten datos.
- Cuentas por cobrar: la ruta autenticada carga sin error. La empresa seleccionada no tenía clientes con saldo pendiente, por lo que no se creó un abono ficticio.
- Bancos: la cuenta `PRUEBA · MXN · •••• 1234` cargó cuatro movimientos, dos candidatos de cobranza —uno exacto— y las excepciones existentes. La actualización server-side terminó sin errores y conservó dos candidatos.
- Arranque neutral: en `QA R-OP · Sin importaciones`, las métricas sin fuente muestran cero con explicación o `No disponible`; no se sustituyeron fuentes faltantes con estimaciones.
- No se confirmaron devoluciones, conciliaciones ni otras operaciones persistentes durante el smoke.
- No hubo errores ni advertencias de consola en las rutas verificadas.

## Pendientes que no bloquean el trabajo visual

- Validación con estado bancario real autorizado y responsable de Tesorería.
- UAT empresarial M4D4 con responsable contable y datos operativos reales.
- Fuente fiscal separada para cerrar el recorrido Alpha de extremo a extremo.

Estos pendientes conservan sus propios dictámenes de liberación empresarial; no deben reinterpretarse como aprobados por esta compuerta técnica.
