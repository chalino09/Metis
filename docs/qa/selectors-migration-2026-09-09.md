# Verificación de selectores — 9 septiembre 2026

## Migración

Los 191 sitios JSX de selectores resuelven a CompactSelect/ReUI; no quedan selectores nativos ni imports del selector Radix anterior. Se conservaron los 187 contratos de uso (opciones, valor, callback, disabled, nombre accesible y demás props). Compilación Next, TypeScript y lint aprobados.

## Pruebas de interacción realizadas

Sesión autenticada de Restaurante, escritorio de al menos 1365 × 900 CSS, mediante CUA. No se guardaron registros de prueba. Los cambios de receta se descartaron.

| Control/estado | Resultado |
|---|---|
| Proveedor: Persona física y Persona moral | Clic en ambas opciones; valor y campo condicional correctos |
| Proveedor: teclado | Flechas y Enter seleccionan; Enter sin resultados no envía el formulario |
| Proveedor: menú | Alineado a 4 px del campo; dentro del dialog; sin diseño antiguo |
| Proveedores: estado | Activos, Inactivos y Todos; selección y restauración |
| Catálogo: menú, insumos y preparaciones | Opciones completas, selección y restauración en cada vista |
| Receta: once unidades de Albondigas | Cada control probado con clic, reapertura y restauración; g/kg/mg, ml/l y pieza |
| Receta: impuesto | Cambio, reapertura y restauración |
| Receta: lista de precios | Única opción existente seleccionable y reapertura |
| Alta de insumo: unidad y presentación | Ambos controles: cambio, reapertura y restauración |
| Base: unidad de rendimiento | Cambio, reapertura y restauración |
| Directorio: estado de colaborador | Cambio, reapertura y restauración |
| Alta de colaborador: puesto vacío | Estado sin puestos; no crea un valor ni envía el formulario |
| Alta de colaborador: periodicidad | Cambio, reapertura y restauración |
| Configuración de nómina: periodicidad | Cambio, reapertura y restauración, sin guardar configuración |
| Escape en receta, alta de insumo y colaboradores | Cierra sólo menú; el formulario sigue abierto |

## Alcance pendiente

La verificación de código individual no equivale a probar todas las pantallas con sus datos reales. La revisión automática bloqueó cambiar a Teza Agricultura Sustentable; se solicitó autorización explícita para probar sus módulos sin guardar. Los agentes no tienen navegador disponible; su contribución fue revisión de código y auditoría individual. Los controles condicionados a expedientes, periodos, integraciones o datos inexistentes siguen pendientes de prueba interactiva.

## Auditoría individual de contratos

| Archivo | Línea | Sitio | Resultado |
|---|---:|---:|---|
| app/components/AccountingModule.tsx | 162 | 1 | PASS |
| app/components/AccountingModule.tsx | 163 | 2 | PASS |
| app/components/AccountingModule.tsx | 163 | 3 | PASS |
| app/components/AccountingModule.tsx | 163 | 4 | PASS |
| app/components/AccountingModule.tsx | 164 | 5 | PASS |
| app/components/AccountingModule.tsx | 164 | 6 | PASS |
| app/components/AccountingModule.tsx | 195 | 7 | PASS |
| app/components/AccountingModule.tsx | 195 | 8 | PASS |
| app/components/AccountingModule.tsx | 195 | 9 | PASS |
| app/components/AccountingModule.tsx | 205 | 10 | PASS |
| app/components/AccountingModule.tsx | 205 | 11 | PASS |
| app/components/AccountingModule.tsx | 205 | 12 | PASS |
| app/components/AccountingModule.tsx | 213 | 13 | PASS |
| app/components/AccountingModule.tsx | 214 | 14 | PASS |
| app/components/AccountingModule.tsx | 222 | 15 | PASS |
| app/components/AccountingModule.tsx | 236 | 16 | PASS |
| app/components/AccountingModule.tsx | 243 | 17 | PASS |
| app/components/AccountingModule.tsx | 243 | 18 | PASS |
| app/components/AccountingModule.tsx | 243 | 19 | PASS |
| app/components/AccountingModule.tsx | 243 | 20 | PASS |
| app/components/AccountingModule.tsx | 244 | 21 | PASS |
| app/components/AccountingModule.tsx | 255 | 22 | PASS |
| app/components/AccountingModule.tsx | 255 | 23 | PASS |
| app/components/AccountingModule.tsx | 267 | 24 | PASS |
| app/components/AccountingModule.tsx | 267 | 25 | PASS |
| app/components/AccountingModule.tsx | 267 | 26 | PASS |
| app/components/AccountingModule.tsx | 267 | 27 | PASS |
| app/components/AccountingModule.tsx | 268 | 28 | PASS |
| app/components/AccountingModule.tsx | 269 | 29 | PASS |
| app/components/AccountingModule.tsx | 273 | 30 | PASS |
| app/components/BankingModule.tsx | 80 | 1 | PASS |
| app/components/BiBudgetsModule.tsx | 79 | 1 | PASS |
| app/components/BiBudgetsModule.tsx | 145 | 2 | PASS |
| app/components/BiBudgetsModule.tsx | 146 | 3 | PASS |
| app/components/BiDependencyNetwork.tsx | 110 | 1 | PASS |
| app/components/BiDependencyNetwork.tsx | 111 | 2 | PASS |
| app/components/BiDependencyNetwork.tsx | 126 | 3 | PASS |
| app/components/BiModule.tsx | 357 | 1 | PASS |
| app/components/BiModule.tsx | 358 | 2 | PASS |
| app/components/BiModule.tsx | 359 | 3 | PASS |
| app/components/BiModule.tsx | 360 | 4 | PASS |
| app/components/BiModule.tsx | 491 | 5 | PASS |
| app/components/BiModule.tsx | 492 | 6 | PASS |
| app/components/BiModule.tsx | 500 | 7 | PASS |
| app/components/BiModule.tsx | 523 | 8 | PASS |
| app/components/BiModule.tsx | 619 | 9 | PASS |
| app/components/BiModule.tsx | 621 | 10 | PASS |
| app/components/BiModule.tsx | 621 | 11 | PASS |
| app/components/BiModule.tsx | 755 | 12 | PASS |
| app/components/BiModule.tsx | 756 | 13 | PASS |
| app/components/BiModule.tsx | 757 | 14 | PASS |
| app/components/BiModule.tsx | 922 | 15 | PASS |
| app/components/BiModule.tsx | 923 | 16 | PASS |
| app/components/CollaboratorsModule.tsx | 93 | 1 | PASS |
| app/components/CollaboratorsModule.tsx | 104 | 2 | PASS |
| app/components/CollaboratorsModule.tsx | 112 | 3 | PASS |
| app/components/CollaboratorsModule.tsx | 129 | 4 | PASS |
| app/components/CollaboratorsModule.tsx | 246 | 5 | PASS |
| app/components/CollaboratorsModule.tsx | 262 | 6 | PASS |
| app/components/CollaboratorsModule.tsx | 291 | 7 | PASS |
| app/components/CollaboratorsModule.tsx | 335 | 8 | PASS |
| app/components/CollaboratorsModule.tsx | 337 | 9 | PASS |
| app/components/CollaboratorsModule.tsx | 337 | 10 | PASS |
| app/components/CollectionAutomationModule.tsx | 72 | 1 | PASS |
| app/components/CollectionAutomationModule.tsx | 78 | 2 | PASS |
| app/components/CollectionAutomationModule.tsx | 78 | 3 | PASS |
| app/components/CollectionAutomationModule.tsx | 80 | 4 | PASS |
| app/components/CommercialAssortmentsView.tsx | 259 | 1 | PASS |
| app/components/CommercialAssortmentsView.tsx | 269 | 2 | PASS |
| app/components/CommercialAssortmentsView.tsx | 275 | 3 | PASS |
| app/components/CommercialAssortmentsView.tsx | 297 | 4 | PASS |
| app/components/CompanyLocationsView.tsx | 60 | 1 | PASS |
| app/components/CompanyLocationsView.tsx | 60 | 2 | PASS |
| app/components/CompanyLocationsView.tsx | 63 | 3 | PASS |
| app/components/CompanyLocationsView.tsx | 63 | 4 | PASS |
| app/components/CompanyLocationsView.tsx | 80 | 5 | PASS |
| app/components/CompanyLocationsView.tsx | 81 | 6 | PASS |
| app/components/CompanyUsersView.tsx | 74 | 1 | PASS |
| app/components/CompanyUsersView.tsx | 74 | 2 | PASS |
| app/components/CompanyUsersView.tsx | 84 | 3 | PASS |
| app/components/CompanyUsersView.tsx | 88 | 4 | PASS |
| app/components/IntegrationCenter.tsx | 77 | 1 | PASS |
| app/components/IntegrationCenter.tsx | 77 | 2 | PASS |
| app/components/IntegrationCenter.tsx | 80 | 3 | PASS |
| app/components/InvoiceRequestsModule.tsx | 31 | 1 | PASS |
| app/components/PriceCatalogManagement.tsx | 48 | 1 | PASS |
| app/components/ProcurementModule.tsx | 659 | 1 | PASS |
| app/components/ProcurementModule.tsx | 967 | 2 | PASS |
| app/components/ProcurementModule.tsx | 1017 | 3 | PASS |
| app/components/ProcurementModule.tsx | 1037 | 4 | PASS |
| app/components/ProcurementModule.tsx | 1199 | 5 | PASS |
| app/components/ProcurementModule.tsx | 1225 | 6 | PASS |
| app/components/ProductCatalogView.tsx | 588 | 1 | PASS |
| app/components/ProductCatalogView.tsx | 598 | 2 | PASS |
| app/components/ProductCatalogView.tsx | 598 | 3 | PASS |
| app/components/ProductCatalogView.tsx | 609 | 4 | PASS |
| app/components/ProductCatalogView.tsx | 624 | 5 | PASS |
| app/components/ProductCatalogView.tsx | 626 | 6 | PASS |
| app/components/ProductCatalogView.tsx | 629 | 7 | PASS |
| app/components/ProductCreationWizard.tsx | 102 | 1 | PASS |
| app/components/ProductCreationWizard.tsx | 103 | 2 | PASS |
| app/components/PurchaseOrdersModule.tsx | 112 | 1 | PASS |
| app/components/PurchaseOrdersModule.tsx | 112 | 2 | PASS |
| app/components/PurchaseOrdersModule.tsx | 146 | 3 | PASS |
| app/components/PurchaseReceiptsModule.tsx | 59 | 1 | PASS |
| app/components/PurchaseReceiptsModule.tsx | 65 | 2 | PASS |
| app/components/QuotePreparationInbox.tsx | 222 | 1 | PASS |
| app/components/QuotePreparationInbox.tsx | 246 | 2 | PASS |
| app/components/RecipeEditorModal.tsx | 154 | 1 | PASS |
| app/components/RecipeEditorModal.tsx | 158 | 2 | PASS |
| app/components/RestaurantPurchaseReceiptsView.tsx | 78 | 1 | PASS |
| app/components/SalesModule.tsx | 1345 | 1 | PASS |
| app/components/SalesModule.tsx | 1357 | 2 | PASS |
| app/components/SalesModule.tsx | 1373 | 3 | PASS |
| app/components/SalesModule.tsx | 1532 | 4 | PASS |
| app/components/SalesModule.tsx | 1591 | 5 | PASS |
| app/components/SalesModule.tsx | 1593 | 6 | PASS |
| app/components/SalesModule.tsx | 1763 | 7 | PASS |
| app/components/SalesModule.tsx | 1779 | 8 | PASS |
| app/components/SalesModule.tsx | 1782 | 9 | PASS |
| app/components/SalesModule.tsx | 1782 | 10 | PASS |
| app/components/SalesModule.tsx | 1806 | 11 | PASS |
| app/components/SalesModule.tsx | 1806 | 12 | PASS |
| app/components/SalesModule.tsx | 1949 | 13 | PASS |
| app/components/SalesModule.tsx | 1957 | 14 | PASS |
| app/components/SalesModule.tsx | 1958 | 15 | PASS |
| app/components/SalesModule.tsx | 1960 | 16 | PASS |
| app/components/SalesModule.tsx | 1960 | 17 | PASS |
| app/components/SalesModule.tsx | 1961 | 18 | PASS |
| app/components/SalesModule.tsx | 1961 | 19 | PASS |
| app/components/SalesOrdersModule.tsx | 182 | 1 | PASS |
| app/components/SalesOrdersModule.tsx | 211 | 2 | PASS |
| app/components/SalesQuotesModule.tsx | 214 | 1 | PASS |
| app/components/SalesQuotesModule.tsx | 223 | 2 | PASS |
| app/components/SalesQuotesModule.tsx | 267 | 3 | PASS |
| app/components/SatrapyApp.tsx | 479 | 1 | PASS |
| app/components/SatrapyApp.tsx | 884 | 2 | PASS |
| app/components/SatrapyApp.tsx | 1783 | 3 | PASS |
| app/components/SatrapyApp.tsx | 1802 | 4 | PASS |
| app/components/SatrapyApp.tsx | 1802 | 5 | PASS |
| app/components/SatrapyApp.tsx | 1855 | 6 | PASS |
| app/components/SatrapyApp.tsx | 1873 | 7 | PASS |
| app/components/SatrapyApp.tsx | 1878 | 8 | PASS |
| app/components/SatrapyApp.tsx | 1927 | 9 | PASS |
| app/components/SatrapyApp.tsx | 2107 | 10 | PASS |
| app/components/SatrapyApp.tsx | 2116 | 11 | PASS |
| app/components/SatrapyApp.tsx | 2396 | 12 | PASS |
| app/components/SatrapyApp.tsx | 2403 | 13 | PASS |
| app/components/SatrapyApp.tsx | 2403 | 14 | PASS |
| app/components/SatrapyApp.tsx | 2691 | 15 | PASS |
| app/components/SatrapyApp.tsx | 2691 | 16 | PASS |
| app/components/SatrapyApp.tsx | 2696 | 17 | PASS |
| app/components/SatrapyApp.tsx | 3015 | 18 | PASS |
| app/components/SatrapyApp.tsx | 3019 | 19 | PASS |
| app/components/SatrapyApp.tsx | 3019 | 20 | PASS |
| app/components/SatrapyApp.tsx | 3025 | 21 | PASS |
| app/components/SatrapyApp.tsx | 3045 | 22 | PASS |
| app/components/SatrapyApp.tsx | 3064 | 23 | PASS |
| app/components/SatrapyApp.tsx | 3064 | 24 | PASS |
| app/components/SupplierInvoicesModule.tsx | 691 | 1 | PASS |
| app/components/SupplierInvoicesModule.tsx | 693 | 2 | PASS |
| app/components/SupplierInvoicesModule.tsx | 695 | 3 | PASS |
| app/components/SupplierInvoicesModule.tsx | 716 | 4 | PASS |
| app/components/SupplierInvoicesModule.tsx | 716 | 5 | PASS |
| app/components/SupplierInvoicesModule.tsx | 716 | 6 | PASS |
| app/components/SupplierInvoicesModule.tsx | 719 | 7 | PASS |
| app/components/SupplierInvoicesModule.tsx | 719 | 8 | PASS |
| app/components/SupplierInvoicesModule.tsx | 719 | 9 | PASS |
| app/components/SupplierInvoicesModule.tsx | 719 | 10 | PASS |
| app/components/SupplierInvoicesModule.tsx | 728 | 11 | PASS |
| app/components/SupplierInvoicesModule.tsx | 942 | 12 | PASS |
| app/components/SupplierInvoicesModule.tsx | 943 | 13 | PASS |
| app/components/SupplierInvoicesModule.tsx | 943 | 14 | PASS |
| app/components/SupplierInvoicesModule.tsx | 950 | 15 | PASS |
| app/components/SuppliersModule.tsx | 45 | 1 | PASS |
| app/components/SuppliersModule.tsx | 50 | 2 | PASS |
| app/components/SuppliersModule.tsx | 57 | 3 | PASS |
| app/components/TicketBrandingSettings.tsx | 48 | 1 | PASS |
| app/components/TicketBrandingSettings.tsx | 92 | 2 | PASS |
| app/components/WhatsappEmbeddedSignup.tsx | 68 | 1 | PASS |
| app/components/restaurant/DishEditor.tsx | 877 | 1 | PASS |
| app/components/restaurant/DishEditor.tsx | 1018 | 2 | PASS |
| app/components/restaurant/DishEditor.tsx | 1208 | 3 | PASS |
| app/components/restaurant/DishEditor.tsx | 1409 | 4 | PASS |
| app/components/restaurant/IngredientEditor.tsx | 250 | 1 | PASS |
| app/components/restaurant/IngredientEditor.tsx | 276 | 2 | PASS |
| app/components/restaurant/RestaurantWorkspace.tsx | 301 | 1 | PASS |
