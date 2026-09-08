import test from 'node:test';
import assert from 'node:assert/strict';
import { initialMealSelection,mealSelectionError,mealSelectionTotal,restaurantCartRows,type MealPicker,type MealInstance } from '../app/lib/restaurant/pos.ts';
const picker:MealPicker={configured:true,solo_price:116,combo_price:174,currency_code:'MXN',groups:[{id:'soup',name:'Sopa',minimum:1,maximum:1,options:[{id:'one',product_id:'s',name:'Fideo',available:true},{id:'two',product_id:'s2',name:'Crema',available:false}]}],extras:[{id:'extra',product_id:'e',name:'Guacamole',available:true,final_price:11.6}]};
function instance(id:string,mode:'solo'|'complete',quantity=1):MealInstance{return {id,cart_item_id:'dish-line',product_id:'d',mode,quantity,unit_final_price:mode==='solo'?116:174,solo_unit_final_price:116,selections:[],extras:[]};}
test('selecciona sólo la única opción disponible obligatoria y recupera elecciones previas',()=>{
 const initial=initialMealSelection(picker,undefined,'complete');assert.deepEqual(initial.selections,{soup:['one']});assert.equal(mealSelectionError(picker,initial),null);
 const optional={...picker,groups:picker.groups.map(g=>({...g,minimum:0}))};assert.deepEqual(initialMealSelection(optional).selections,{soup:[]});
 const previous={...instance('1','complete'),selections:[{group_id:'soup',option_id:'two',group:'Sopa',product_id:'s2',name:'Crema',quantity:1}]};const restored=initialMealSelection(picker,previous);assert.deepEqual(restored.selections,{soup:['two']});assert.match(mealSelectionError(picker,restored)??'',/disponibles/);
});
test('calcula el precio final con extras por cada comida sin inventar precios faltantes',()=>{
 const value={...initialMealSelection(picker,undefined,'complete'),extras:['e'],quantity:2};assert.equal(mealSelectionTotal(picker,value),371.2);
 assert.equal(mealSelectionTotal({...picker,combo_price:null},value),null);assert.match(mealSelectionError({...picker,combo_price:null},value)??'',/precio/);
 assert.equal(mealSelectionTotal(picker,{...value,mode:'solo'}),255.2);assert.match(mealSelectionError(picker,{...value,quantity:1.5})??'',/1 a 100/);
});
test('separa modalidades y asocia extras sin duplicar importes del servidor',()=>{
 const solo=instance('solo','solo'),complete={...instance('combo','complete',2),extras:[{product_id:'e',name:'Guacamole'}]};
 const rows=restaurantCartRows([{cart_item_id:'dish-line',product_id:'d',name:'Tacos',quantity:3,total_amount:464},{cart_item_id:'extra-line',product_id:'e',name:'Guacamole',quantity:3,total_amount:34.8}],[solo,complete]);
 assert.deepEqual(rows.meals.map(m=>m.total),[116,371.2]);assert.equal(rows.plainItems[0].quantity,1);assert.equal(rows.plainItems[0].total_amount,11.6);
 assert.equal(Math.round([...rows.meals.map(m=>m.total),...rows.plainItems.map(i=>i.total_amount)].reduce((a,b)=>a+b,0)*100),49880);
});
test('asigna cada centavo una sola vez con descuentos y redondeo por partida',()=>{
 const rows=restaurantCartRows([{cart_item_id:'dish-line',product_id:'d',name:'Tacos',quantity:3,total_amount:417.61}],[instance('a','solo'),instance('b','complete'),instance('c','complete')]);
 assert.equal(Math.round(rows.meals.reduce((a,b)=>a+b.total,0)*100),41761);assert.equal(rows.plainItems.length,0);
});
