"use client";

import { Package, Store, Wrench } from "lucide-react";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { Button, Drawer, Field, Input, Select, useToast } from "@/app/components/ui/primitives";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { getSupabaseClient } from "@/app/lib/supabase";

type TaxCategory={id:string;code:string;name:string;rate:number|null;is_active:boolean};
type Location={id:string;code:string|null;name:string};
type PriceList={id:string;name:string;currency_code:string;is_default:boolean};
type Assortment={id:string;code:string;name:string;locations:Location[]};
type Context={price_lists:PriceList[];assortments:Assortment[];locations:Location[]};
type CreatedProduct={product_id:string;product_code:string;product_name:string;final_price:number;currency_code:string;assortment_ids:string[]};
type Props={companyId:string;open:boolean;taxCategories:TaxCategory[];onOpenChange:(open:boolean)=>void;onCreated:()=>Promise<void>|void};

const initial={name:"",unit:"PZA",group:"",barcode:"",inventoryPolicy:"tracked" as "tracked"|"not_required",taxId:"",finalPrice:"",priceListId:"",assortmentIds:[] as string[]};
const errorText=(error:{message?:string}|null)=>error?.message?.replace(/^.*?error:\s*/i,"").trim()||"Intenta nuevamente.";

export function ProductCreationWizard({companyId,open,taxCategories,onOpenChange,onCreated}:Props){
  const router=useRouter();
  const {toast}=useToast();
  const keys=useRef(new OperationIdempotencyKeys()).current;
  const nameRef=useRef<HTMLInputElement|null>(null);
  const [form,setForm]=useState(initial);
  const [context,setContext]=useState<Context|null>(null);
  const [loading,setLoading]=useState(false);
  const [saving,setSaving]=useState(false);
  const [errors,setErrors]=useState<Record<string,string>>({});
  const [created,setCreated]=useState<CreatedProduct|null>(null);

  useEffect(()=>{
    if(!open)return;
    let active=true;
    void Promise.resolve().then(()=>{if(active){setForm(initial);setErrors({});setCreated(null);setLoading(true);}});
    void getSupabaseClient().rpc("get_manual_product_sale_setup_context",{p_company_id:companyId}).then(({data,error})=>{
      if(!active)return;
      if(error){toast({title:"No se pudo preparar el alta",description:errorText(error),tone:"error"});setContext(null);}
      else{
        const next=data as Context;
        setContext(next);
        setForm(current=>({...current,priceListId:next.price_lists.find(item=>item.is_default)?.id??next.price_lists[0]?.id??"",assortmentIds:next.assortments.map(item=>item.id)}));
      }
      setLoading(false);
    });
    return()=>{active=false;};
  },[companyId,open,toast]);

  function validate(){
    const next:Record<string,string>={};
    if(!form.name.trim())next.name="Escribe el nombre del producto.";
    if(!form.unit.trim())next.unit="Indica la unidad de venta.";
    const price=Number(form.finalPrice.replace(",","."));
    if(!form.taxId)next.taxId="Selecciona el impuesto.";
    if(!Number.isFinite(price)||price<=0)next.finalPrice="Escribe un precio final mayor que cero.";
    if(context&&context.locations.length===0)next.locations="Primero crea al menos una sucursal activa.";
    setErrors(next);
    if(next.name)nameRef.current?.focus();
    return Object.keys(next).length===0;
  }
  async function submit(event:FormEvent){
    event.preventDefault();if(!validate()||!context)return;
    const finalPrice=Number(form.finalPrice.replace(",","."));
    const fingerprint=JSON.stringify({...form,finalPrice});setSaving(true);
    const {data,error}=await getSupabaseClient().rpc("create_product_sale_setup",{
      p_company_id:companyId,p_name:form.name.trim(),p_unit:form.unit.trim().toUpperCase(),p_product_group:form.group.trim()||null,
      p_barcode:form.barcode.trim()||null,p_inventory_policy:form.inventoryPolicy,p_tax_category_id:form.taxId,p_final_price:finalPrice,
      p_price_list_id:form.priceListId||null,p_assortment_ids:form.assortmentIds,p_client_request_id:keys.get("create-product-sale-setup",fingerprint),
    });
    if(error)toast({title:"No se pudo crear el producto",description:errorText(error),tone:"error"});
    else{
      keys.clear("create-product-sale-setup");
      const result=data as CreatedProduct;
      setCreated(result);
      toast({title:"Producto configurado",description:form.inventoryPolicy==="tracked"?"El precio y las sucursales quedaron guardados. Falta registrar existencia.":"El servicio ya tiene precio y sucursales de venta.",tone:"success"});
      await onCreated();
    }
    setSaving(false);
  }
  const selectedTax=taxCategories.find(item=>item.id===form.taxId)??null;
  const selectedList=context?.price_lists.find(item=>item.id===form.priceListId)??null;
  const selectedAssortments=context?.assortments.filter(item=>form.assortmentIds.includes(item.id))??[];
  const offeredLocations=new Set(selectedAssortments.flatMap(item=>item.locations.map(location=>location.id))).size;
  const displayPrice=Number(form.finalPrice.replace(",","."));
  function close(){onOpenChange(false);}
  function createPurchaseRequest(){if(!created)return;close();router.push(`/satrapy/compras/abastecimiento?producto_nuevo=${created.product_id}`);}
  return <Drawer open={open} onOpenChange={next=>{if(!saving)onOpenChange(next);}} eyebrow="Alta individual" title={created?"Producto configurado":"Nuevo producto"} description={created?"La configuración comercial quedó guardada.":"Captura los datos comerciales en un solo formulario."} className="product-creation-wizard__drawer">
    {created?<section className="product-creation-wizard__success" aria-labelledby="created-product-title"><div><span className="eyebrow">Configurado</span><h3 id="created-product-title">{created.product_name}</h3><p>{created.product_code} · {created.final_price.toLocaleString("es-MX",{minimumFractionDigits:2,maximumFractionDigits:2})} {created.currency_code}</p></div>{form.inventoryPolicy==="tracked"?<div className="product-creation-wizard__stock-state"><strong>Sin existencia</strong><span>El producto ya tiene precio y sucursales, pero necesita una recepción antes de venderse.</span></div>:<div className="product-creation-wizard__stock-state is-ready"><strong>Listo para vender</strong><span>El servicio no requiere inventario.</span></div>}<div className="product-creation-wizard__success-actions"><Button type="button" variant="secondary" onClick={close}>Cerrar</Button>{form.inventoryPolicy==="tracked"&&<Button type="button" variant="primary" onClick={createPurchaseRequest}>Crear solicitud de compra</Button>}</div></section>:loading?<div className="product-creation-wizard__loading" role="status">Preparando opciones…</div>:<form className="product-creation-wizard" onSubmit={submit} noValidate>
      <div className="product-creation-wizard__layout">
        <section className="product-creation-wizard__section" aria-labelledby="product-details-title"><header><h3 id="product-details-title">Datos del producto</h3><p>Identifica el artículo y define cómo se opera.</p></header>
        <div className="product-creation-wizard__type-grid">
          <label className={form.inventoryPolicy==="tracked"?"is-selected":undefined}><input type="radio" name="type" checked={form.inventoryPolicy==="tracked"} onChange={()=>setForm({...form,inventoryPolicy:"tracked"})}/><Package size={18}/><span><strong>Mercancía</strong><small>Con inventario.</small></span></label>
          <label className={form.inventoryPolicy==="not_required"?"is-selected":undefined}><input type="radio" name="type" checked={form.inventoryPolicy==="not_required"} onChange={()=>setForm({...form,inventoryPolicy:"not_required"})}/><Wrench size={18}/><span><strong>Servicio</strong><small>Sin inventario.</small></span></label>
        </div>
        <div className="product-creation-wizard__fields"><Field label="Nombre" error={errors.name}><Input ref={nameRef} autoFocus required value={form.name} onChange={event=>setForm({...form,name:event.target.value})} placeholder="Ej. Café molido 500 g" aria-invalid={Boolean(errors.name)}/></Field><Field label="Unidad de venta" error={errors.unit}><Input required value={form.unit} onChange={event=>setForm({...form,unit:event.target.value.toUpperCase()})} placeholder="PZA" aria-invalid={Boolean(errors.unit)}/></Field></div>
        <div className="product-creation-wizard__fields product-creation-wizard__fields--equal"><Field label="Grupo"><Input value={form.group} onChange={event=>setForm({...form,group:event.target.value})} placeholder="Opcional"/></Field><Field label="Código de barras"><Input value={form.barcode} onChange={event=>setForm({...form,barcode:event.target.value})} placeholder="Opcional"/></Field></div>
      </section>
      <section className="product-creation-wizard__section" aria-labelledby="sale-setup-title"><header><h3 id="sale-setup-title">Venta y disponibilidad</h3><p>Define precio, impuesto y dónde estará disponible.</p></header>
        <div className="product-creation-wizard__fields"><Field label="Impuesto" error={errors.taxId}><Select value={form.taxId} onValueChange={taxId=>setForm({...form,taxId})} ariaLabel="Impuesto" placeholder="Selecciona el impuesto" options={taxCategories.filter(item=>item.is_active).map(item=>({value:item.id,label:`${item.name}${item.rate!=null?` · ${item.rate*100}%`:""}`}))}/></Field><Field label="Precio final" hint="Impuesto incluido." error={errors.finalPrice}><Input required inputMode="decimal" value={form.finalPrice} onChange={event=>setForm({...form,finalPrice:event.target.value})} placeholder="0.00" aria-invalid={Boolean(errors.finalPrice)}/></Field></div>
        {context&&context.price_lists.length>1?<Field label="Lista de precios"><Select value={form.priceListId} onValueChange={priceListId=>setForm({...form,priceListId})} ariaLabel="Lista de precios" options={context.price_lists.map(item=>({value:item.id,label:`${item.name} · ${item.currency_code}`}))}/></Field>:selectedList&&<p className="product-creation-wizard__automatic">Precio guardado en <strong>{selectedList.name} · {selectedList.currency_code}</strong>.</p>}
        <div className="product-creation-wizard__assortments"><strong><Store size={17}/> Sucursales de venta</strong>{context?.assortments.length?context.assortments.map(item=><label key={item.id}><input type="checkbox" checked={form.assortmentIds.includes(item.id)} onChange={event=>setForm({...form,assortmentIds:event.target.checked?[...form.assortmentIds,item.id]:form.assortmentIds.filter(id=>id!==item.id)})}/><span><strong>{item.name}</strong><small>{item.locations.map(location=>location.name).join(", ")||"Sin sucursales activas"}</small></span></label>):<p>Satrapy creará <strong>Productos generales</strong> para {context?.locations.map(item=>item.name).join(", ")||"las sucursales activas"}.</p>}{errors.locations&&<small className="ui-field__error" role="alert">{errors.locations}</small>}</div>
        {form.inventoryPolicy==="tracked"&&<p className="product-creation-wizard__notice">Esto define dónde se ofrece. La existencia se carga por separado desde compras o recepción.</p>}
      </section>
      </div>
      <section className="product-creation-wizard__summary" aria-labelledby="product-creation-summary-title"><strong id="product-creation-summary-title">Antes de crear</strong><dl><div><dt>Precio final</dt><dd>{Number.isFinite(displayPrice)&&displayPrice>0?`${displayPrice.toLocaleString("es-MX",{minimumFractionDigits:2,maximumFractionDigits:2})} ${selectedList?.currency_code??"MXN"}`:"Por definir"}</dd></div><div><dt>Impuesto</dt><dd>{selectedTax?`${selectedTax.name}${selectedTax.rate!=null?` · ${selectedTax.rate*100}%`:""}`:"Por definir"}</dd></div><div><dt>Lista</dt><dd>{selectedList?.name??"Por definir"}</dd></div><div><dt>Sucursales</dt><dd>{offeredLocations||context?.locations.length||0}</dd></div></dl></section>
      <div className="product-creation-wizard__actions"><p>{form.inventoryPolicy==="tracked"?"Se guardará la configuración comercial. La existencia se registra después mediante compras y recepción.":"El servicio quedará disponible sin control de inventario."}</p><div><Button type="button" variant="secondary" disabled={saving} onClick={close}>Cancelar</Button><Button type="submit" variant="primary" loading={saving}>Crear producto para venta</Button></div></div>
    </form>}
  </Drawer>;
}
