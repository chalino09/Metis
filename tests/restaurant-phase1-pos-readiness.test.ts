import assert from "node:assert/strict";import{readFileSync}from"node:fs";import test from"node:test";
const sql=readFileSync("supabase/migrations/202608170005_restaurant_phase1_pos_readiness.sql","utf8");
test("readiness culinario se aplica sólo a vendibles no inventariables de Restaurant",()=>{assert.match(sql,/v_experience<>'restaurant'or not v_product\.is_sellable or v_product\.is_inventory_tracked then return v_core/);});
test("la pertenencia al surtido permanece separada de bloqueos culinarios",()=>{assert.match(sql,/v_core:=public\.validate_pos_product_for_location_before_culinary/);assert.doesNotMatch(sql,/update public\.sales_assortment_items/);});
test("readiness explica receta, conversión, costo y existencia",()=>{for(const code of ["missing_active_recipe","invalid_recipe_conversion","missing_purchase_conversion","insufficient_ingredient_stock"])assert.match(sql,new RegExp(code));assert.match(sql,/culinary_version_cost/);});
