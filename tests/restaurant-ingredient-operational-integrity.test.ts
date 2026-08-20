import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql=readFileSync("supabase/migrations/202608190001_restaurant_ingredient_operational_integrity.sql","utf8");
const catalog=readFileSync("app/components/ProductCatalogView.tsx","utf8");
const experience=readFileSync("app/lib/product-experience.ts","utf8");

test("el alta de Restaurante guarda producto, rol, compra y lote en una transacción",()=>{
  assert.match(sql,/create or replace function public\.save_restaurant_catalog_item/);
  assert.match(sql,/public\.save_product\(/);
  assert.match(sql,/public\.set_product_purchase_unit\(/);
  assert.match(sql,/public\.set_product_lot_controlled\(/);
  assert.match(sql,/public\.set_product_culinary_role\(/);
  assert.match(catalog,/save_restaurant_catalog_item/);
});

test("las conversiones métricas conocidas se validan y reparan con auditoría",()=>{
  assert.match(sql,/v_purchase='kg' and v_base='g' then return 1000/);
  assert.match(sql,/v_purchase=v_base.*then return 1/);
  assert.match(sql,/product\.purchase_unit_conversion_repaired/);
});

test("Restaurante reutiliza el módulo canónico para mínimos",()=>{
  assert.match(experience,/"inventory_replenishment"/);
  assert.match(experience,/inventory_replenishment: "Mínimos de inventario"/);
});
