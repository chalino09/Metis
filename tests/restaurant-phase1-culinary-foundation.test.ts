import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const migration = readFileSync("supabase/migrations/202608170002_restaurant_phase1_culinary_foundation.sql", "utf8");

test("fase 1 normaliza sólo masa, volumen y conteo sin densidades implícitas", () => {
  assert.match(migration, /dimension in\('mass','volume','count'\)/);
  assert.match(migration, /'kg','kilogramo','mass',1000000/);
  assert.match(migration, /'l','litro','volume',1000/);
  assert.match(migration, /dimensionalmente incompatibles/);
  assert.doesNotMatch(migration, /density|densidad/i);
});

test("recetas conservan versiones, rendimiento, merma y activación no destructiva", () => {
  assert.match(migration, /create table public\.culinary_recipe_versions/);
  assert.match(migration, /waste_percent numeric/);
  assert.match(migration, /status='retired',valid_to=now\(\)/);
  assert.match(migration, /culinary_recipe_one_active_idx/);
  assert.match(migration, /assert_culinary_recipe_acyclic/);
});

test("readiness bloquea receta o costos faltantes sin cambiar surtido", () => {
  assert.match(migration, /missing_active_recipe/);
  assert.match(migration, /missing_component_cost/);
  assert.doesNotMatch(migration, /update public\.sales_assortment_items/);
});

test("las identidades culinarias apuntan a productos canónicos", () => {
  assert.match(migration, /product_id uuid not null references public\.products/);
  assert.match(migration, /component_product_id uuid not null references public\.products/);
  assert.doesNotMatch(migration, /create table public\.(restaurant_products|ingredients)/);
});
