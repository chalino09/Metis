import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const experience = readFileSync("app/lib/product-experience.ts", "utf8");
const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const bi = readFileSync("app/components/BiModule.tsx", "utf8");
const configuration = readFileSync("app/components/ConfigurationHome.tsx", "utf8");

test("Restaurant reutiliza operación, personal e indicadores sin habilitar módulos avanzados", () => {
  for (const view of ["bi_summary", "inventory_counts", "collaborators_directory", "payroll", "sales_settings", "sales_audit"]) {
    assert.match(experience, new RegExp(`"${view}"`));
  }
  assert.doesNotMatch(experience, /"bi_explorer",/);
  assert.doesNotMatch(experience, /"procurement",/);
});

test("la interfaz Restaurant usa lenguaje operativo y roles del piloto", () => {
  assert.match(app, /experienceSectionLabel\(section\.id, section\.label, experience\)/);
  assert.match(app, /const RESTAURANT_ROLES:[\s\S]*code: "punto_venta", display_name: "Cajero"/);
  assert.match(configuration, /isRestaurant \? "Caja, pagos y ticket"/);
  assert.match(bi, /"net_sales","tickets","average_ticket","gross_margin"/);
  assert.match(bi, /title=\{isRestaurant\?"Indicadores":"Resumen ejecutivo"\}/);
});
