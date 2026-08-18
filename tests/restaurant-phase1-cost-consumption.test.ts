import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sql=readFileSync("supabase/migrations/202608170003_restaurant_phase1_cost_consumption.sql","utf8");

test("la venta culinaria congela versiones, cantidades y costos fuente",()=>{
 assert.match(sql,/culinary_sale_item_recipe_versions/);
 assert.match(sql,/product_cost_id uuid not null references public\.product_costs/);
 assert.match(sql,/recognized_culinary_snapshot_id/);
});

test("el consumo ocurre dentro de la transacción de sale_items y bloquea saldos",()=>{
 assert.match(sql,/after insert on public\.sale_items/);
 assert.match(sql,/order by product_id/);
 assert.match(sql,/for update/);
 assert.match(sql,/Existencia insuficiente para el ingrediente/);
});

test("cancelar usa consumos originales y no recalcula recetas",()=>{
 assert.match(sql,/sale_cancellations_reverse_culinary/);
 assert.match(sql,/join public\.culinary_sale_item_snapshots/);
 assert.doesNotMatch(sql,/reverse_cancelled_culinary_consumptions[\s\S]*expand_culinary_recipe/);
});

test("productos core sin receta conservan su ruta actual",()=>{
 assert.match(sql,/if v_version is null then return new;end if/);
 assert.doesNotMatch(sql,/create or replace function public\.complete_sale/);
 assert.doesNotMatch(sql,/create or replace function public\.complete_pos_sale/);
});
