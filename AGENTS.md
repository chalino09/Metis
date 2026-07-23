# Principios permanentes de Satrapy

- No diseñar operaciones masivas como captura registro por registro.
- No solicitar manualmente información que ya fue importada.
- Separar pertenencia comercial de disponibilidad operativa: un fallo de readiness bloquea la venta, pero no modifica automáticamente el surtido.
- Preferir operaciones server-side, transaccionales, paginadas y auditadas para volúmenes operativos reales.
- No introducir entidades, estados, reglas genéricas o flags temporales sin un caso de negocio comprobado.
- No codificar nombres, ubicaciones o reglas particulares de una empresa en funcionalidades reutilizables.
- Mantener Alpha únicamente en la frontera de importación; el dominio usa identidades canónicas de Satrapy.
- Antes de implementar un flujo manual, declarar su volumen esperado, explicar su impacto y advertirlo al usuario.

