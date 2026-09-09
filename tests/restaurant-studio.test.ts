import assert from "node:assert/strict";
import test from "node:test";
import {
  compatibleUnits,
  bundleIssues,
  nextBundleGroupName,
  type BundleDraft,
  purchaseFactor,
  netMargin,
  recipeComponents,
  type RecipeLine,
} from "../app/lib/restaurant/studio.ts";

test("comida completa identifica el grupo vacío sin culpar al precio ni a los extras", () => {
  const bundle: BundleDraft = {
    is_active: true, combo_price_amount: "120",
    groups: [
      { name: "Sopa", minimum_selections: 1, maximum_selections: 1, options: [{ id: "sopa", name: "Sopa" }] },
      { name: "Agua", minimum_selections: 1, maximum_selections: 1, options: [] },
    ],
    extras: [{ id: "huevo", name: "Huevo extra" }],
  };
  const issues = bundleIssues(bundle);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].field, "options");
  assert.equal(issues[0].groupIndex, 1);
  assert.match(issues[0].message, /Agua/);
  bundle.groups[1].options.push({ id: "agua", name: "Agua" });
  assert.deepEqual(bundleIssues(bundle), []);
  assert.equal(bundle.extras[0].id, "huevo");
});

test("precio y nombres repetidos tienen errores independientes; agregar grupos da nombres únicos", () => {
  const group = { name: " Acompañamiento ", minimum_selections: 1, maximum_selections: 1, options: [{ id: "sopa", name: "Sopa" }] };
  const bundle: BundleDraft = { is_active: true, combo_price_amount: "", groups: [group, { ...group, name: "acompañamiento" }], extras: [] };
  assert.deepEqual(bundleIssues(bundle).map(issue => issue.field), ["price", "name"]);
  assert.equal(nextBundleGroupName(bundle.groups), "Acompañamiento 2");
  bundle.groups.push({ ...group, name: "Acompañamiento 2" });
  assert.equal(nextBundleGroupName(bundle.groups), "Acompañamiento 3");
  assert.deepEqual(bundleIssues({ ...bundle, is_active: false }), []);
  assert.deepEqual(bundleIssues(null), []);
});

test("una comida guardada con precio nulo pide completarlo sin romper el editor", () => {
  const bundle: BundleDraft = {
    is_active: true,
    combo_price_amount: null,
    groups: [{ name: "Sopa", minimum_selections: 1, maximum_selections: 1, options: [{ id: "sopa", name: "Sopa" }] }],
    extras: [{ id: "huevo", name: "Huevo extra" }],
  };
  assert.deepEqual(bundleIssues(bundle).map(issue => issue.field), ["price"]);
  assert.deepEqual(bundleIssues({ ...bundle, combo_price_amount: "120" }), []);
  assert.deepEqual(bundleIssues({ ...bundle, is_active: false }), []);
});

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
