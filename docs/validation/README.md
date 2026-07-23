# Validación reproducible de Módulos 1, 2 y 3A–3D

Ejecutar desde la raíz:

```bash
npm run test:sql
```

Para validar únicamente M3D sin ejecutar promociones configuradas contra fuentes Alpha del entorno:

```bash
bash scripts/run-m3d-local-validation.sh
```

Este runner es estrictamente local: reconstruye la base local, prueba M3D, concurrencia, importaciones frontend, lint y build, y termina con un reset limpio.

El comando inicia el proyecto local `satrapy-validation`, reconstruye PostgreSQL desde todas las migraciones y el seed de validación, y ejecuta:

- regresiones SQL y contratos de instalación;
- matriz RLS/RBAC y aislamiento por empresa/sucursal;
- staging, conciliación e idempotencia de importaciones;
- POS, CxC, abonos, inventario, tickets y cierre/arqueo;
- contención concurrente de la última existencia;
- dos reintentos concurrentes con la misma idempotency key;
- confirmación concurrente e idempotente de facturas de proveedor sin duplicar cantidades ni CxP;
- perfil de los archivos Alpha reales configurados en `ALPHA_ERP_IMPORT_DIR`;
- staging/promoción/reintento transaccional de un `cata_prd` real, con rollback final.
- perfil real de Proveedores/Compras/CxP (`cata_prv`, `rpcon2`, `lfchvenc`, `pag_det`) sin crear operaciones históricas.
- reset final del entorno local para retirar todos los fixtures de prueba.

Cada corrida crea `docs/validation/evidence/<timestamp UTC>/` con versiones del entorno, hashes SHA-256 de migraciones y pruebas, log individual por caso y `summary.txt`. Las corridas fallidas se conservan como historial diagnóstico.

La validación real no asigna impuestos ni mapeos comerciales por inferencia. Si falta la fuente fiscal separada o las asignaciones de moneda/lista, `summary.txt` registra el bloqueo y el GO permanece cerrado.
