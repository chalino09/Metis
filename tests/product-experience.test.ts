import assert from "node:assert/strict";
import test from "node:test";
import { experienceRoleLabel, experienceSectionLabel, experienceViewLabel, isViewAvailableForExperience, normalizeProductExperience, productVocabulary } from "../app/lib/product-experience.ts";

test("core conserva todos los módulos y el vocabulario original", () => {
  assert.equal(isViewAvailableForExperience("accounting_summary", "core"), true);
  assert.equal(isViewAvailableForExperience("ecommerce_readiness", "core"), true);
  assert.equal(experienceViewLabel("products", "Productos", "core"), "Productos");
  assert.equal(productVocabulary("core").singularTitle, "Producto");
});

test("Restaurant limita la superficie sin alterar las entidades canónicas", () => {
  for (const view of ["bi_summary", "pos", "sales_history", "cash", "products", "inventory", "inventory_counts", "collaborators_directory", "sales_settings"]) {
    assert.equal(isViewAvailableForExperience(view, "restaurant"), true, view);
  }
  for (const view of ["accounting_summary", "payroll", "ecommerce_readiness", "procurement", "bi_explorer", "inventory_replenishment"]) {
    assert.equal(isViewAvailableForExperience(view, "restaurant"), false, view);
  }
  assert.equal(experienceViewLabel("products", "Productos", "restaurant"), "Platillos");
  assert.equal(experienceViewLabel("sales_history", "Ventas", "restaurant"), "Tickets y ventas");
  assert.equal(experienceViewLabel("inventory_counts", "Conteos físicos", "restaurant"), "Conteos y ajustes");
  assert.equal(experienceViewLabel("sales_settings", "Ventas y caja", "restaurant"), "Caja, pagos y ticket");
  assert.equal(experienceSectionLabel("bi", "BI", "restaurant"), "Indicadores");
  assert.equal(experienceSectionLabel("collaborators", "Colaboradores", "restaurant"), "Colaboradores");
  assert.equal(experienceRoleLabel("punto_venta", "Punto de Venta", "restaurant"), "Cajero");
  assert.equal(experienceRoleLabel("sucursal", "Operador de Sucursal", "restaurant"), "Encargado");
  assert.equal(experienceRoleLabel("direccion_admin", "Administrador", "restaurant"), "Administrador");
  assert.equal(productVocabulary("restaurant").singular, "platillo");
});

test("valores desconocidos regresan a core de forma segura", () => {
  assert.equal(normalizeProductExperience(null), "core");
  assert.equal(normalizeProductExperience("restaurant"), "restaurant");
  assert.equal(normalizeProductExperience("otro"), "core");
});
