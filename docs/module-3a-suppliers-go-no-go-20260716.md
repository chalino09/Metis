# Cierre Módulo 3A — Proveedores

Fecha: 2026-07-16  
Decisión: **GO**

## Volumen, riesgos y aceptación

El corte real contiene 119 proveedores. La carga completa conserva además 84 OC/731 partidas, 62 documentos CxP y 2,220 evidencias de pago, con 0 errores y 336 alertas. El flujo es masivo: no existe captura registro por registro; sólo una bandeja para excepciones de identidad.

Riesgos controlados:

- duplicidad por RFC, código o nombre normalizado;
- RFC genérico/inválido tratado como evidencia, no como identidad fiscal canónica;
- reintentos y ejecuciones concurrentes;
- modificación sin permiso o sin auditoría;
- lectura o vinculación cruzada entre empresas;
- creación accidental de OC, recepciones, CxP o pagos.

Criterios aceptados:

- maestro canónico sin campos de identidad Alpha;
- búsqueda, filtros y paginación server-side;
- promoción transaccional, idempotente y auditada;
- conflicto explícito, sin duplicados silenciosos;
- alta y edición con RBAC, control de concurrencia optimista y auditoría antes/después;
- resultado visible en Compras → Proveedores y Auditoría de importaciones;
- cero operaciones creadas de etapas posteriores;
- pruebas SQL, importación, permisos, aislamiento, lint, build y corte real aprobadas.

## Evidencia

- Suite completa: `docs/validation/evidence/20260716T153311Z/summary.txt` — 33 PASS, 0 FAIL.
- El marcador `real_alpha_end_to_end missing_separate_fiscal_source` pertenece al readiness fiscal de Productos y no afecta ni bloquea 3A.
- SQL 3A: `docs/validation/evidence/20260716T153311Z/202607160001_supplier_master.log` y `202607160002_supplier_detail_repair.log`.
- Perfil real: `docs/validation/evidence/20260716T153311Z/real-alpha-purchasing-profile.log`.
- Promoción real corregida, ejecutada con `npm run validate:alpha-suppliers` dentro de `BEGIN/ROLLBACK`:
  - fuente: 119;
  - promovidos automáticamente: 117;
  - excepciones por RFC duplicado: 2;
  - conciliación: 117 + 2 = 119;
  - OC creadas: 0;
  - CxP creadas: 0;
  - pagos creados: 0;
  - segundo intento: idempotente.
- Pruebas frontend posteriores: 23/23; lint sin incidencias; build de producción aprobado.

## Corrección de detalle fiscal

El formato real de `cata_prv` deja una fila en blanco entre el encabezado del proveedor y su detalle. Se corrigió el parser y se agregó `202607160002_repair_alpha_supplier_details.sql` para reparar el lote ya promovido sin reimportarlo.

- 119 proveedores en la fuente.
- 64 filas reportan algún RFC.
- 55 no reportan RFC.
- 42 filas tienen RFC canónico único y pueden actualizarse automáticamente.
- 18 usan RFC genérico, 2 tienen formato no válido y 2 comparten el mismo RFC; no se aplican silenciosamente al maestro.
- El filtro/columna “Importado o manual” se eliminó del catálogo porque no representa una clasificación comercial del proveedor.

## Alta maestra y teléfonos

`202607160003_supplier_master_intake.sql` elimina la captura de código: Satrapy genera una clave `SUP-…` en el servidor. El formulario se organiza en identidad fiscal, contacto, domicilio y clasificación; la acción visible es “Guardar proveedor” y la auditoría permanece automática.

Los teléfonos mexicanos de 10 dígitos se guardan en formato E.164 (`+52…`), la extensión se conserva por separado y `0000` se descarta como marcador vacío. Los teléfonos locales de 7 u 8 dígitos quedan marcados como “Sin lada”; Satrapy no infiere una lada inexistente.

## Permisos y aislamiento

`view_suppliers`, `manage_suppliers` y `promote_suppliers` se conceden únicamente a Super Admin y Dirección/Admin General. Las RPC comprueban empresa y permiso; las tablas canónicas no tienen DML directo para `authenticated`. La prueba SQL confirma rechazo sin membresía y evita candidatos/vínculos de otra empresa.

## Pendientes fuera de 3A

- Aplicar la migración `202607160001_supplier_master.sql` en el entorno objetivo y ejecutar la promoción desde la app con un usuario autorizado. La validación real de cierre usó rollback deliberadamente.
- La comprobación visual automatizada local no pudo abrir el servidor ya existente desde el navegador integrado; compilación, rutas y componentes sí quedaron validados por Next/TypeScript. Conviene hacer el smoke UAT autenticado al desplegar la migración.
- OC y Aprobación pertenecen a 3B. Recepción, inventario/costo, factura, CxP y pago continúan fuera de alcance.
