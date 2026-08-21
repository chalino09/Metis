import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202608140001_product_inventory_policy.sql", "utf8");
const catalog = readFileSync("app/components/ProductCatalogView.tsx", "utf8");
const readiness = readFileSync("app/lib/product-readiness.ts", "utf8");

test("la política distingue mercancía, servicio y origen importado ambiguo", () => {
  assert.match(migration, /inventory_policy in \('tracked', 'not_required', 'unclassified'\)/);
  assert.match(migration, /when 'p\. terminado' then 'tracked'/);
  assert.match(migration, /when 'servicios' then 'not_required'/);
  assert.match(migration, /else 'unclassified'/);
});

test("POS bloquea preparación pendiente sin sacar el producto del surtido", () => {
  assert.match(migration, /inventory_setup_required/);
  assert.match(migration, /p\.inventory_policy<>'unclassified'/);
  assert.match(migration, /product\.inventory_policy='unclassified'/);
  assert.match(readiness, /inventory_setup_required: "Inventario pendiente de preparar"/);
});

test("las altas manuales eligen una política explícita", () => {
  assert.match(catalog, /Mercancía con inventario/);
  assert.match(catalog, /Servicio sin inventario/);
  assert.match(catalog, /Elige el tipo operativo/);
  assert.match(catalog, /disabled=\{saving\|\|draft\.inventoryPolicy==="unclassified"\}/);
  assert.match(catalog, /p_inventory_policy:normalized\.inventoryPolicy/);
  assert.doesNotMatch(catalog, /p_is_inventory_tracked:normalized\.inventoryTracked/);
});
