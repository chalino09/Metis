"use client";
import { useEffect, useId, useState } from 'react';
import { Check, Minus, Plus, Soup, UtensilsCrossed } from 'lucide-react';
import { Modal, Button } from '@/app/components/ui/primitives';
import { initialMealSelection, mealSelectionError, mealSelectionTotal, type MealPicker, type MealInstance, type MealSelection } from '@/app/lib/restaurant/pos';
import { money } from '@/app/lib/restaurant/studio';
import styles from './restaurant-pos.module.css';
export function RestaurantMealDrawer({name,picker,instance,initialMode,busy,onClose,onSave,onPreview}:{name:string;picker:MealPicker;instance?:MealInstance;initialMode?:'solo'|'complete';busy:boolean;onClose:()=>void;onSave:(value:MealSelection)=>Promise<void>;onPreview:(value:MealSelection)=>Promise<{total:number;cartTotal:number}>}){
 const [value,setValue]=useState(()=>initialMealSelection(picker,instance,initialMode));
 const [error,setError]=useState<string|null>(null);const id=useId();
 const [preview,setPreview]=useState<{fingerprint:string;total:number;cartTotal:number}|null>(null);
 const [previewError,setPreviewError]=useState<string|null>(null);
 const [retry,setRetry]=useState(0);
 const fingerprint=JSON.stringify(value);const current=preview?.fingerprint===fingerprint?preview:null;
 const validation=mealSelectionError(picker,value);const total=current?.total??null;
 const estimated=mealSelectionTotal(picker,value);
 useEffect(()=>{
  if(busy)return;
  let active=true;
  const timer=setTimeout(()=>{
   setPreviewError(null);
   if(validation)return;
   void onPreview(value).then(result=>{if(active)setPreview({...result,fingerprint});}).catch(e=>{if(active)setPreviewError(e instanceof Error?e.message:'No se pudo calcular la selección.');});
  },180);
  return()=>{active=false;clearTimeout(timer);};
 },[value,fingerprint,validation,busy,onPreview,retry]);
 function toggle(group:MealPicker['groups'][number],option:string){setValue(current=>{const ids=current.selections[group.id]??[];return {...current,selections:{...current.selections,[group.id]:ids.includes(option)?ids.filter(i=>i!==option):group.maximum===1?[option]:ids.length<group.maximum?[...ids,option]:ids}};});}
 async function save(){if(!current)return;const issue=mealSelectionError(picker,value);setError(issue);if(issue)return;try{await onSave(value);}catch(e){setError(e instanceof Error?e.message:'No se guardó la selección. Intenta nuevamente.');}}
 return <Modal open onOpenChange={open=>{if(!open&&!busy)onClose();}} closeDisabled={busy} className={styles.drawer} eyebrow="Personaliza el platillo" title={name} description="Elige cómo servirlo. Los precios incluyen impuestos." footer={<div className={styles.footer}><div aria-live="polite"><span>Total de esta selección</span><strong>{money(total,picker.currency_code)}</strong><small>{current?`Venta completa: ${money(current.cartTotal,picker.currency_code)}`:validation??(previewError?"Revisa la selección":"Calculando total…")}</small>{current&&estimated!=null&&Math.abs(current.total-estimated)>.005&&<small>Incluye descuentos y redondeo fiscal</small>}</div><Button variant="primary" disabled={busy||!current||Boolean(validation)||Boolean(previewError)} onClick={()=>void save()}>{busy?'Guardando…':current?`${instance?'Actualizar':'Agregar'} · ${money(total,picker.currency_code)}`:'Calculando…'}</Button></div>}>
  <div className={styles.content}>
   <fieldset disabled={busy}><legend>¿Cómo lo quieres?</legend><div className={styles.modes}>{(['solo','complete']as const).map(mode=><label key={mode} className={value.mode===mode?styles.selected:''}><input type="radio" name={`${id}-mode`} checked={value.mode===mode} disabled={mode==='complete'&&(picker.combo_price==null||!picker.groups.length)} onChange={()=>setValue({...value,mode})}/>{mode==='solo'?<UtensilsCrossed size={20}/>:<Soup size={20}/>}<span><strong>{mode==='solo'?'Platillo solo':'Comida completa'}</strong><small>{(mode==='solo'?picker.solo_price:picker.combo_price)==null?'Precio pendiente':money(mode==='solo'?picker.solo_price:picker.combo_price,picker.currency_code)}</small></span></label>)}</div></fieldset>
   {value.mode==='complete'&&picker.groups.map(group=><fieldset key={group.id} disabled={busy}><legend>{group.name}<small>{group.minimum===group.maximum?`Elige ${group.minimum}`:`Elige de ${group.minimum} a ${group.maximum}`}</small></legend><div className={styles.options}>{group.options.map(option=><label key={option.id} className={(value.selections[group.id]??[]).includes(option.id)?styles.selected:''}><input type={group.maximum===1?'radio':'checkbox'} name={`${id}-${group.id}`} checked={(value.selections[group.id]??[]).includes(option.id)} disabled={!option.available} onChange={()=>toggle(group,option.id)}/><span><strong>{option.name}</strong><small>{option.available?'Incluido':'No disponible en esta sucursal'}</small></span><Check size={16} aria-hidden="true"/></label>)}</div></fieldset>)}
   {picker.extras.length>0&&<fieldset disabled={busy}><legend>Agregar extras<small>Opcional</small></legend><div className={styles.options}>{picker.extras.map(extra=><label key={extra.id} className={value.extras.includes(extra.product_id)?styles.selected:''}><input type="checkbox" checked={value.extras.includes(extra.product_id)} disabled={!extra.available||extra.final_price==null} onChange={()=>setValue({...value,extras:value.extras.includes(extra.product_id)?value.extras.filter(id=>id!==extra.product_id):[...value.extras,extra.product_id]})}/><span><strong>{extra.name}</strong><small>{extra.final_price==null?'Sin precio vigente':!extra.available?'No disponible en esta sucursal':`+ ${money(extra.final_price,picker.currency_code)}`}</small></span><Check size={16} aria-hidden="true"/></label>)}</div></fieldset>}
   <div className={styles.quantity}><label htmlFor={`${id}-quantity`}>Platillos con esta selección</label><div><Button variant="secondary" size="icon" aria-label="Restar un platillo" disabled={busy||value.quantity<=1} onClick={()=>setValue({...value,quantity:value.quantity-1})}><Minus size={16}/></Button><input id={`${id}-quantity`} type="number" min={1} max={100} step={1} value={Number.isNaN(value.quantity)?'':value.quantity} disabled={busy} onChange={e=>setValue({...value,quantity:e.target.valueAsNumber})}/><Button variant="secondary" size="icon" aria-label="Sumar un platillo" disabled={busy||value.quantity>=100} onClick={()=>setValue({...value,quantity:value.quantity+1})}><Plus size={16}/></Button></div></div>
   {previewError&&<div className={styles.error} role="alert">{previewError}<Button variant="ghost" disabled={busy} onClick={()=>setRetry(n=>n+1)}>Reintentar</Button></div>}{error&&<p className={styles.error} role="alert">{error}</p>}
  </div>
 </Modal>;
}
