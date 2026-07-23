# M4D2 — Clasificación contable comprensible y automática

Fecha: 2026-07-23  
Dictamen exclusivo: **GO para M4D2**

La implementación y validación se realizaron únicamente en el entorno local. No se aplicó ninguna migración remota y no se inició M4D3 ni M4D4.

## Reutilización y frontera

- Se reutilizaron `accounting_accounts`, la matriz de eventos M4B, sus cuentas de control de inventario/costo y los permisos existentes.
- Se preservaron literalmente `expense_category`, `cost_center_reference` y `project_reference`.
- No se crearon catálogos duplicados de productos, cuentas, centros de costo o proyectos.
- No se añadieron cuentas por producto ni dependencias de claves Alpha.
- La única estructura nueva es el historial versionado mínimo de categorías de gasto.

## Implementación

- Catálogo seguro: nombre y código comprensibles, alta, renombre y desactivación con motivo, idempotencia y auditoría. Una cuenta utilizada no puede cambiar tipo, naturaleza, nivel o estructura, ni eliminarse.
- Categorías: código, nombre visible, cuenta de gasto activa, estado y vigencia. Cada cambio crea una versión y conserva la anterior.
- Gastos: cada línea resuelve su cuenta desde una categoría explícita vigente al confirmar. Una factura admite varias categorías; no se infiere por descripción, proveedor ni clave SAT.
- Excepciones: las líneas pendientes aparecen agrupadas y paginadas. La asignación masiva opera en servidor en lotes de hasta 5,000, con reintento idempotente y auditoría.
- Contabilización: evento, póliza y auxiliar conservan categoría, versión y cuenta. Notas de crédito y reversas reutilizan e invierten la clasificación original.
- Compatibilidad histórica: únicamente documentos ya confirmados, sin `confirm_request_id` y sin líneas conservan el rol genérico previo a M4D2. Toda confirmación RPC nueva exige clasificación.
- Inventario: continúa usando las cuentas de control y costo de venta de M4B; los productos nuevos no requieren asignación contable manual.
- Interfaz: administración de categorías y cuentas, motivo obligatorio, vigencias, estado, explicación de selección y bandeja agrupada de pendientes.

## Evidencia reproducible

Ejecutar desde la raíz:

```bash
npm run test:sql
```

Corrida definitiva: [`evidence/20260723T151921Z/summary.txt`](./evidence/20260723T151921Z/summary.txt) — **69 PASS, 0 FAIL**.

- Instalación limpia de todas las migraciones: [`migration-reset.log`](./evidence/20260723T151921Z/migration-reset.log)
- Caso M4D2: [`202607230002_m4d2_accounting_classification.log`](./evidence/20260723T151921Z/202607230002_m4d2_accounting_classification.log)
- Concurrencia y 2,000 asignaciones exactas: [`setup`](./evidence/20260723T151921Z/concurrency_accounting_classification-setup.log), [`cliente A`](./evidence/20260723T151921Z/concurrency_accounting_classification-a.log), [`cliente B`](./evidence/20260723T151921Z/concurrency_accounting_classification-b.log), [`verificación`](./evidence/20260723T151921Z/concurrency_accounting_classification-verify.log)
- Regresión completa M1–M4D1: todos los casos enumerados en el resumen están en PASS.
- RLS, permisos e aislamiento multiempresa: incluidos en el caso M4D2 y en la matriz global.
- Lint y build: [`lint`](./evidence/20260723T151921Z/frontend-lint.log), [`build`](./evidence/20260723T151921Z/frontend-build.log)
- Reset limpio final: [`final-clean-reset.log`](./evidence/20260723T151921Z/final-clean-reset.log)
- Hashes reproducibles: [`migraciones`](./evidence/20260723T151921Z/migration-sha256.txt), [`pruebas`](./evidence/20260723T151921Z/test-sha256.txt)

La corrida conserva `BLOCKED real_alpha_end_to_end missing_separate_fiscal_source`, dependencia histórica documentada desde M4A. Las verificaciones reales disponibles de catálogo, compras, proveedores y órdenes están en PASS; ese bloqueo no pertenece a M4D2 ni se usó para inferir clasificaciones.

## Dictamen

**GO exclusivo para M4D2.** La clasificación explícita, versionada, masiva y auditable cumple las pruebas funcionales, de seguridad, concurrencia y regresión con **69 PASS, 0 FAIL**.

La migración fue aplicada remotamente después de la autorización expresa del usuario. M4D3 y M4D4 permanecen sin iniciar.

## Verificación remota posterior

El 2026-07-23 el usuario autorizó aplicar M4D2. Una vista previa aislada de Supabase CLI confirmó que se ejecutaría exclusivamente `202607230002_m4d2_accounting_classification.sql`; la aplicación terminó correctamente y el historial remoto registra `202607230002`.

En la empresa `QA R-OP · Sin importaciones`:

- el catálogo cargó 21 cuentas y mostró las secciones M4D2 sin errores;
- se creó `QA-M4D2 · Prueba de clasificación M4D2`, vinculada a `6010 · Gastos y servicios`;
- se guardó una segunda versión con nombre `Prueba M4D2 finalizada`;
- la V2 quedó inactiva, vigente desde 2026-07-24, con motivo explícito;
- la interfaz confirmó ambas escrituras y mostró 0 excepciones pendientes.

La categoría permanece inactiva como evidencia auditada. No se aplicaron migraciones M4D3 ni M4D4.
