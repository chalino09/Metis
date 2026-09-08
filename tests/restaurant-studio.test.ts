import assert from "node:assert/strict";
import test from "node:test";
import {
  compatibleUnits,
  purchaseFactor,
  netMargin,
  recipeComponents,
  type RecipeLine,
} from "../app/lib/restaurant/studio.ts";

test("las compras estándar se convierten sin pedir factores técnicos", () => {
  assert.equal(purchaseFactor("KG", "g"), 1000);
  assert.equal(purchaseFactor("L", "ml"), 1000);
  assert.equal(purchaseFactor("PZA", "piece"), 1);
  assert.equal(purchaseFactor("BOTELLA", "ml"), null);
  assert.equal(purchaseFactor("KG", "ml"), null);
  assert.deepEqual(
    compatibleUnits("g").map((unit) => unit.value),
    ["mg", "g", "kg"],
  );
  assert.deepEqual(
    compatibleUnits("piece").map((unit) => unit.value),
    ["piece"],
  );
});
test("el margen usa venta neta, conserva pérdidas y nunca inventa un costo", () => {
  assert.deepEqual(netMargin(116, 0.16, 40), {
    net: 100,
    amount: 60,
    percent: 60,
  });
  assert.deepEqual(netMargin(116, 0.16, 140), {
    net: 100,
    amount: -40,
    percent: -40,
  });
  assert.equal(netMargin(116, 0.16, null), null);
  assert.equal(netMargin(116, null, 40), null);
  assert.equal(netMargin(NaN, 0.16, 40), null);
  assert.equal(netMargin(0, 0.16, 40), null);
});
test("el payload conserva cantidades de la tanda para normalizarlas una sola vez en el servidor", () => {
  const lines: RecipeLine[] = [
    {
      id: "arrachera",
      name: "Arrachera",
      unit: "g",
      unit_code: "kg",
      quantity: "1,5",
      internal_sku: "I-1",
      catalog_role: "ingredient",
      recipe_kind: null,
    },
  ];
  assert.deepEqual(recipeComponents(lines), [
    {
      product_id: "arrachera",
      quantity: 1.5,
      unit_code: "kg",
      base_unit_code: "g",
      sort_order: 0,
    },
  ]);
  assert.ok(
    Number.isNaN(recipeComponents([{ ...lines[0], quantity: "" }])[0].quantity),
  );
});
