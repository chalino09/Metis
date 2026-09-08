export type MealOption = { id: string; product_id: string; name: string; available: boolean };
export type MealGroup = { id: string; name: string; minimum: number; maximum: number; options: MealOption[] };
export type MealPicker = { configured: boolean; bundle_id?: string; solo_price: number | null; combo_price: number | null; currency_code?: string; groups: MealGroup[]; extras: Array<MealOption & { final_price: number | null; currency_code?: string }> };
export type MealInstance = { id: string; cart_item_id: string; product_id: string; mode: 'solo' | 'complete'; quantity: number; unit_final_price: number | null; solo_unit_final_price?: number | null; has_complete?: boolean; has_extras?: boolean; selections: Array<{ group_id: string; option_id: string; group: string; product_id: string; name: string; quantity: number }>; extras: Array<{ product_id: string; name: string }> };
export type MealSelection = { mode: 'solo' | 'complete'; selections: Record<string,string[]>; extras: string[]; quantity: number };
type PricedLine = { cart_item_id: string; product_id: string; name: string; quantity: number; total_amount: number };

export function initialMealSelection(picker: MealPicker, instance?: MealInstance, mode?: 'solo' | 'complete'): MealSelection {
  return { mode: mode ?? instance?.mode ?? 'solo', quantity: instance?.quantity ?? 1, extras: instance?.extras.map(e=>e.product_id) ?? [], selections: Object.fromEntries(picker.groups.map(group=>{
    const existing=instance?.selections.filter(s=>s.group_id===group.id).map(s=>s.option_id) ?? [];
    const available=group.options.filter(o=>o.available);
    return [group.id, existing.length ? existing : group.minimum===1 && group.maximum===1 && available.length===1 ? [available[0].id] : []];
  })) };
}
export function mealSelectionError(picker: MealPicker, value: MealSelection): string | null {
  if(!Number.isInteger(value.quantity)||value.quantity<1||value.quantity>100) return 'Indica de 1 a 100 platillos.';
  if((value.mode==='complete'?picker.combo_price:picker.solo_price)==null) return 'Falta el precio vigente de esta opción.';
  if(value.mode==='complete') {
    if(!picker.groups.length) return 'Configura los acompañamientos en Restaurante.';
    for(const g of picker.groups){const ids=value.selections[g.id]??[];if(ids.length<g.minimum||ids.length>g.maximum) return `Elige ${g.minimum===g.maximum?g.minimum:`de ${g.minimum} a ${g.maximum}`} en ${g.name}.`;if(ids.some(id=>!g.options.some(o=>o.id===id&&o.available)))return `Revisa las opciones disponibles en ${g.name}.`;}
  }
  if(value.extras.some(id=>!picker.extras.some(e=>e.product_id===id&&e.available&&e.final_price!=null))) return 'Quita o cambia los extras que ya no están disponibles.';
  return null;
}
export function mealSelectionTotal(picker: MealPicker,value:MealSelection){
 const price=value.mode==='complete'?picker.combo_price:picker.solo_price;
 if(price==null)return null;
 let total=Number(price);for(const id of value.extras){const e=picker.extras.find(e=>e.product_id===id);if(e?.final_price==null)return null;total+=Number(e.final_price);}
 return Math.round(total*value.quantity*100)/100;
}

/** Allocate each authoritative line's cents once, including shared extras and mixed modes. */
export function restaurantCartRows<T extends PricedLine>(items:T[],instances:MealInstance[]){
 const meals=instances.filter(i=>items.some(item=>item.cart_item_id===i.cart_item_id)).map(instance=>({instance,item:items.find(item=>item.cart_item_id===instance.cart_item_id)!,total:0}));
 const plainItems:T[]=[];
 for(const item of items){
   const shares:Array<{index:number;quantity:number;weight:number}>=[];
   meals.forEach((m,index)=>{if(m.instance.cart_item_id===item.cart_item_id)shares.push({index,quantity:m.instance.quantity,weight:m.instance.quantity*Number(m.instance.unit_final_price??0)});if(m.instance.extras.some(e=>e.product_id===item.product_id))shares.push({index,quantity:m.instance.quantity,weight:0});});
   const assigned=shares.reduce((sum,s)=>sum+s.quantity,0), remaining=Math.max(0,item.quantity-assigned);
   // Extras and ordinary units use the price of a solo unit. Reconstruct it from
   // the authoritative aggregate when the product also has complete meals.
   const solo=meals.find(m=>m.instance.cart_item_id===item.cart_item_id)?.instance.solo_unit_final_price ?? meals.find(m=>m.instance.cart_item_id===item.cart_item_id&&m.instance.mode==='solo')?.instance.unit_final_price;
   const fallback=Number(solo??(item.total_amount/item.quantity));
   for(const share of shares)if(share.weight===0)share.weight=share.quantity*fallback;
   const plainWeight=remaining*fallback;
   const weight=shares.reduce((sum,s)=>sum+s.weight,0)+plainWeight;
   let cumulative=0,allocated=0;
   for(const share of shares){cumulative+=share.weight;const cents=weight>0?Math.round(item.total_amount*100*cumulative/weight):0;meals[share.index].total+=(cents-allocated)/100;allocated=cents;}
   if(remaining>0)plainItems.push({...item,quantity:remaining,total_amount:(Math.round(item.total_amount*100)-allocated)/100});
   // Without partial units, the last share receives any final rounding cent.
   else if(shares.length) meals[shares[shares.length-1].index].total+=(Math.round(item.total_amount*100)-allocated)/100;
 }
 return {meals:meals.map(m=>({...m,total:Math.round(m.total*100)/100})),plainItems};
}
