import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration=readFileSync("supabase/migrations/202608200010_manual_product_sale_setup.sql","utf8");
const catalog=readFileSync("app/components/ProductCatalogView.tsx","utf8");
const wizard=readFileSync("app/components/ProductCreationWizard.tsx","utf8");
const procurement=readFileSync("app/components/ProcurementModule.tsx","utf8");

test("el alta manual confirma producto, precio y sucursales en una transacción",()=>{
  assert.match(migration,/create_product_sale_setup/);
  assert.match(migration,/save_product_price/);
  assert.match(migration,/set_product_sales_assortments/);
  assert.match(migration,/product\.sale_setup_created/);
  assert.match(migration,/p_final_price\s*\/\s*\(1\+v_tax_rate\)/);
});

test("el alta manual concentra los datos comerciales en una sola captura",()=>{
  assert.match(wizard,/Datos del producto/);
  assert.match(wizard,/Venta y disponibilidad/);
  assert.match(wizard,/product-creation-wizard__layout/);
  assert.doesNotMatch(wizard,/product-creation-wizard__steps/);
  assert.match(wizard,/Crear producto para venta/);
  assert.match(catalog,/ProductCreationWizard/);
});

test("la lista presenta un solo estado de preparación comercial",()=>{
  assert.match(catalog,/Estado de venta/);
  assert.match(catalog,/offered_location_count/);
  assert.match(catalog,/Precio final<\/th><th>Sucursales<\/th><th>Estado de venta/);
  assert.match(catalog,/Configurado/);
  assert.match(catalog,/Sin existencia/);
  assert.match(catalog,/inventory_balances/);
  assert.match(catalog,/quantity_on_hand/);
});

test("el alta explica la configuración automática antes de confirmar",()=>{
  assert.match(wizard,/Precio guardado en/);
  assert.match(wizard,/Antes de crear/);
  assert.match(wizard,/Precio final/);
  assert.match(wizard,/Impuesto/);
  assert.match(wizard,/Lista/);
  assert.match(wizard,/Sucursales/);
});

test("un producto nuevo sin existencia enlaza una solicitud de compra preseleccionada",()=>{
  assert.match(wizard,/Crear solicitud de compra/);
  assert.match(wizard,/producto_nuevo=/);
  assert.match(wizard,/Sin existencia/);
  assert.match(procurement,/searchParams\.get\("producto_nuevo"\)/);
  assert.match(procurement,/preselectedProductId/);
});

test("la edición conserva el formulario completo con una jerarquía más clara",()=>{
  assert.match(catalog,/product-catalog__edit-summary/);
  assert.match(catalog,/Completa lo necesario para vender/);
  assert.match(catalog,/Revisar venta e impuestos/);
  assert.match(catalog,/product-catalog__form--editing/);
});
