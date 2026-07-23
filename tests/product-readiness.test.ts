import assert from "node:assert/strict";
import test from "node:test";
import { productReadinessLabel, productReadinessSummary } from "../app/lib/product-readiness.ts";

test("muestra un diagnóstico entendible para cada bloqueo del catálogo", () => {
  assert.equal(productReadinessLabel("missing_current_tax_rate"), "Sin tasa fiscal vigente");
  assert.equal(
    productReadinessSummary(["missing_sales_unit", "missing_or_zero_price"]),
    "Sin unidad de venta · Sin precio vigente",
  );
});

test("un producto listo no muestra acciones manuales", () => {
  assert.equal(productReadinessSummary([]), "Sin bloqueos");
  assert.equal(productReadinessSummary(undefined), "Sin bloqueos");
});
