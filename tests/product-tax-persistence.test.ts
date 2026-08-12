import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const products = readFileSync("app/components/ProductCatalogView.tsx", "utf8");

test("crear una categoría fiscal la selecciona sin reconstruir un borrador obsoleto", () => {
  assert.match(products, /setDraft\(current=>current\?\{\.\.\.current,taxCategoryId:category\.id\}:current\)/);
  assert.match(products, /Categoría fiscal seleccionada/);
  assert.match(products, /Guarda los cambios del/);
  assert.doesNotMatch(products, /setDraft\(\{\.\.\.draft,taxCategoryId:category\.id\}\)/);
});

test("guardar un producto verifica que el IVA elegido quedó persistido", () => {
  assert.match(products, /p_tax_category_id:selectedTaxCategoryId/);
  assert.match(products, /select\("id, tax_category_id, updated_at"\)/);
  assert.match(products, /confirmed\.tax_category_id!==selectedTaxCategoryId/);
  assert.match(products, /se guardó sin el IVA seleccionado/);
});
