# Archivos pendientes y arranque desde cero

Última revisión: 2026-07-20.

## Archivos controlados disponibles

- `M4A_01_catalogo_contable_prueba.xlsx`: catálogo mínimo usado para probar apertura; no alcanza para contabilización operativa.
- `M4A_02_balanza_apertura_prueba.xlsx`: balanza controlada de apertura por 100,000 MXN.
- `CAT_01_catalogo_contable_operativo_prueba.xlsx`: catálogo completo de prueba con 27 cuentas para ventas, costos, caja, inventario, compras e impuestos.

## Archivos reales que todavía deben solicitarse

1. **Catálogo contable definitivo** aprobado por el responsable contable, con cuentas afectables y jerarquía completa.
2. **Balanza más reciente** a la fecha real de corte.
3. **Fuente fiscal separada de productos**: objeto de impuesto, tasa, tasa cero o exento. Sigue siendo el bloqueo conocido `missing_separate_fiscal_source`.
4. **Saldo o estado de cuentas bancarias a la fecha de corte**, si se quiere conciliar bancos en la apertura.
5. **Auxiliar fiscal de IVA y retenciones a la fecha de corte**, si se quiere conciliar esos saldos y no sólo documentar sus cuentas.

Los auxiliares de clientes/CxC, proveedores/CxP, inventario/costos, caja, cobros y pagos ya tienen fuentes Alpha identificadas. Antes de una prueba formal deben reemplazarse por exportaciones recientes del mismo corte.

## Arranque de una empresa desde cero

La operación cotidiana no debe depender de Alpha. Una empresa nueva debe poder:

1. Crear empresa, usuarios y ubicaciones.
2. Cargar mediante plantillas estándar productos, precios, impuestos, costos y existencias iniciales.
3. Cargar su catálogo contable o elegir una plantilla base revisable.
4. Configurar cuentas de control y automatización contable.
5. Empezar a vender, comprar, cobrar y pagar normalmente.

Estado actual: el Centro de Migración permite cargas masivas y el dominio usa identidades canónicas, pero la interfaz todavía depende de importación para crear el catálogo de productos y no ofrece todas las altas unitarias necesarias para una empresa sin datos previos. Esto no impide migrar una empresa, pero sí es una brecha para un arranque completamente manual.

## Brechas de producto por cerrar

- Plantillas estándar sin terminología ni columnas exclusivas de Alpha para productos, precios, impuestos, costos, existencias y contabilidad.
- Alta y edición individual de un producto para casos excepcionales de bajo volumen; la carga masiva seguirá siendo la ruta principal.
- Alta inicial de ubicaciones y demás maestros indispensables sin exigir un archivo heredado.
- Asistente de arranque desde cero que muestre qué maestros faltan y permita comenzar sin datos históricos.

