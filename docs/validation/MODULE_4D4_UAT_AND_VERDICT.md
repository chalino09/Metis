# M4D4 — Estados financieros, cierre y UAT contable

## Auditoría previa

- M4D1: `docs/validation/MODULE_4D1_GO.md` — GO; conserva `canonical_accounting_auxiliaries`, `list_accounting_report` y la exportación server-side paginada.
- M4D2: `docs/validation/MODULE_4D2_GO.md` — GO; reutiliza catálogo, naturaleza, clasificación y pólizas.
- M4D3: `docs/validation/MODULE_4D3_GO.md` — GO; reutiliza `location_id`, caja/custodia y trazabilidad origen → evento → póliza → partida.

## Entregado localmente

- `202607230004_m4d4_financial_statements_close_uat.sql` crea **un único** cierre canónico sobre `accounting_periods`: vista previa hash, checks persistidos, preparación, aprobación segregada, confirmación atómica e idempotente y reapertura excepcional segregada. `202607230005_m4d4_close_reopen_revision.sql` conserva cada cierre como evidencia y habilita una nueva corrida después de una reapertura.
- `list_financial_report` ofrece consolidado empresarial oficial y vista administrativa por ubicación o `Sin asignar`; la respuesta identifica explícitamente su alcance. Los totales son de todo el resultado y el máximo de página es 200.
- Se reutilizan mayor, auxiliares, balanza, resultados, balance, flujo y las rutas de exportación XLSX/PDF de M4D1. La ruta de exportación itera páginas en servidor, con límite de 50,000 renglones.
- Los checks bloqueantes cubren controles de CxC/CxP/inventario/caja/bancos/IVA/retenciones configurados, debe=haber, bancos pendientes, eventos pendientes, pólizas borrador y ajustes sin decisión. El balance general existente valida Activo = Pasivo + Capital, incluyendo el resultado del ejercicio.
- No se crearon libro, importador, dimensiones, cuentas, sucursales ni módulos posteriores.

## Evidencia reproducible

Ejecutar:

```bash
npm run test:sql
npm run lint
npm run build
```

Evidencia local: `docs/validation/evidence/20260723T183703Z/summary.txt`.

- 72 pruebas/regresiones PASS y 0 FAIL.
- Incluye el volumen existente de 10,000 partidas (`202607210003_m4d_report_volume`), RLS, paginación, exportación, concurrencia e idempotencia.
- M4D4 específico: consolidado, filtro por ubicación, `Sin asignar`, hash, segregación preparador/aprobador/reaperturador, bloqueo de diferencias, cierre/reintento y RLS.
- Permanece el bloqueo histórico conocido `real_alpha_end_to_end missing_separate_fiscal_source`; no es una falla de M4D4 ni se reinterpreta información Alpha.

## UAT empresarial pendiente

No se ejecutó UAT con responsable contable ni datos operativos reales en este entorno. Antes de liberar, el responsable debe documentar una muestra completa documento origen → evento → póliza → partida → estado, contrastar una ubicación, `Sin asignar` y el consolidado, validar IVA efectivo y ensayar preparar/aprobar/cerrar/reabrir un periodo controlado.

## Dictamen

**NO-GO empresarial de M4D4, únicamente por UAT real pendiente.**

El dictamen técnico local es GO condicionado: la migración quedó validada localmente y **no se aplicó ninguna migración remota**. No iniciar módulos posteriores hasta completar y firmar el UAT, y autorizar expresamente cualquier despliegue remoto.
