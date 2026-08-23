"use client";

import { Download, FileSpreadsheet, UploadCloud } from "lucide-react";
import { useRef, useState, type ChangeEvent } from "react";
import { Badge, Button, Modal, useToast } from "@/app/components/ui/primitives";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { downloadRestaurantCatalogTemplate, parseRestaurantCatalogFile, type RestaurantCatalogImportPreview, type RestaurantImportRole } from "@/app/lib/restaurant-catalog-import";
import { getSupabaseClient } from "@/app/lib/supabase";

const roleCopy: Record<RestaurantImportRole, { singular:string; plural:string; description:string }> = {
  dish: { singular:"platillo", plural:"platillos", description:"Importa los datos del menú. Las recetas se completan después, platillo por platillo." },
  ingredient: { singular:"insumo", plural:"insumos", description:"Importa nombres, unidades y presentaciones de compra en una sola operación." },
  preparation: { singular:"base", plural:"bases reutilizables", description:"Importa las bases y después arma la receta de cada tanda." },
};

function errorMessage(error:{message?:string}|null) {
  return error?.message?.replace(/^.*?error:\s*/i, "").trim() || "No se pudo importar el archivo. Revisa los datos e intenta nuevamente.";
}

export function RestaurantCatalogImportModal({
  companyId,role,open,onOpenChange,onImported,
}:{
  companyId:string;
  role:RestaurantImportRole;
  open:boolean;
  onOpenChange:(open:boolean)=>void;
  onImported:()=>Promise<void>|void;
}) {
  const copy=roleCopy[role];
  const fileHint=role==="preparation"?"El rendimiento y la unidad se definen después, al armar la receta.":role==="ingredient"?"Usa la plantilla para conservar unidades y presentaciones de compra correctas.":"Usa la plantilla para conservar categorías y datos fiscales correctos.";
  const {toast}=useToast();
  const keys=useRef(new OperationIdempotencyKeys()).current;
  const fileInputRef=useRef<HTMLInputElement|null>(null);
  const [preview,setPreview]=useState<RestaurantCatalogImportPreview|null>(null);
  const [parsing,setParsing]=useState(false);
  const [importing,setImporting]=useState(false);
  const [reason,setReason]=useState("");
  const [error,setError]=useState<string|null>(null);

  function reset(){setPreview(null);setReason("");setError(null);setParsing(false);setImporting(false);if(fileInputRef.current)fileInputRef.current.value="";}
  function close(){if(importing)return;reset();onOpenChange(false);}
  async function chooseFile(event:ChangeEvent<HTMLInputElement>){
    const file=event.target.files?.[0];
    if(!file)return;
    setParsing(true);setError(null);
    try{setPreview(await parseRestaurantCatalogFile(file,role));}
    catch(parseError){setPreview(null);setError(parseError instanceof Error?parseError.message:"No se pudo leer el archivo.");}
    setParsing(false);
  }
  async function runImport(){
    if(!preview){setError("Selecciona el archivo que quieres importar.");fileInputRef.current?.focus();return;}
    if(preview.errors.length){setError("Corrige los errores del archivo antes de importarlo.");return;}
    if(!reason.trim()){setError("Indica el motivo de la importación.");document.getElementById("restaurant-import-reason")?.focus();return;}
    const fingerprint=JSON.stringify({role,fileName:preview.fileName,rows:preview.rows,reason:reason.trim()});
    setImporting(true);setError(null);
    const {data,error:requestError}=await getSupabaseClient().rpc("import_restaurant_catalog_batch",{
      p_company_id:companyId,p_role:role,p_rows:preview.rows,p_reason:reason.trim(),p_client_request_id:keys.get("restaurant-catalog-import",fingerprint),
    });
    if(requestError){setError(errorMessage(requestError));setImporting(false);return;}
    keys.clear("restaurant-catalog-import");
    const processed=Number((data as {processed?:number}|null)?.processed??preview.rows.length);
    toast({title:`${processed} ${processed===1?copy.singular:copy.plural} importados`,description:role==="ingredient"?"Ya puedes usarlos al armar recetas.":"Completa las recetas pendientes desde el listado.",tone:"success"});
    await onImported();
    setImporting(false);reset();onOpenChange(false);
  }

  const footer=<><Button variant="secondary" disabled={importing} onClick={close}>Cancelar</Button><Button variant="primary" loading={importing} onClick={()=>void runImport()}><UploadCloud size={16} aria-hidden="true"/> Importar {copy.plural}</Button></>;
  return <Modal open={open} onOpenChange={value=>{if(!value)close();}} eyebrow="Carga masiva" title={`Importar ${copy.plural}`} description={copy.description} footer={footer} closeDisabled={importing} className="restaurant-import">
    <div className="restaurant-import__actions">
      <Button variant="secondary" size="sm" onClick={()=>void downloadRestaurantCatalogTemplate(role)}><Download size={15} aria-hidden="true"/> Descargar plantilla</Button>
      <small>CSV o Excel · máximo 500 registros por lote</small>
    </div>
    <label className={`restaurant-import__dropzone${preview?" has-file":""}`}>
      <FileSpreadsheet size={24} aria-hidden="true"/>
      <span><strong>{preview?.fileName??`Seleccionar archivo de ${copy.plural}`}</strong><small>{preview?`${preview.rows.length} registros detectados`:fileHint}</small></span>
      <input ref={fileInputRef} type="file" accept=".csv,.xls,.xlsx" onChange={event=>void chooseFile(event)} disabled={parsing||importing}/>
      <span className="ui-button ui-button--secondary ui-button--sm" aria-hidden="true">{parsing?"Leyendo…":preview?"Cambiar archivo":"Elegir archivo"}</span>
    </label>
    {preview?.errors.length?<section className="restaurant-import__errors" role="alert" aria-labelledby="restaurant-import-errors-title"><strong id="restaurant-import-errors-title">Corrige {preview.errors.length} {preview.errors.length===1?"dato":"datos"}</strong><ul>{preview.errors.slice(0,8).map(message=><li key={message}>{message}</li>)}</ul>{preview.errors.length>8&&<small>Y {preview.errors.length-8} errores más.</small>}</section>:null}
    {preview&&!preview.errors.length?<section className="restaurant-import__preview" aria-labelledby="restaurant-import-preview-title"><header><div><strong id="restaurant-import-preview-title">Vista previa</strong><p>Se guardarán todos los registros o ninguno.</p></div><Badge tone="success">{preview.rows.length} listos</Badge></header><div className="table-wrap"><table><thead><tr><th>Nombre</th><th>Categoría</th><th>Unidad</th>{role==="ingredient"&&<th>Compra</th>}<th>Estado</th></tr></thead><tbody>{preview.rows.slice(0,8).map((row,index)=><tr key={`${row.name}:${index}`}><td><strong>{row.name}</strong>{row.internal_sku&&<small>{row.internal_sku}</small>}</td><td>{row.product_group||"Sin categoría"}</td><td>{role==="preparation"?"Se define en la receta":row.unit}</td>{role==="ingredient"&&<td>{row.purchase_unit_code} · {row.base_units_per_purchase_unit} {row.unit}</td>}<td>{row.is_active?"Activo":"Inactivo"}</td></tr>)}</tbody></table></div>{preview.rows.length>8&&<small>Se muestran 8 de {preview.rows.length} registros.</small>}</section>:null}
    <label className="operation-reason">Motivo de la importación<textarea id="restaurant-import-reason" rows={2} maxLength={240} value={reason} onChange={event=>{setReason(event.target.value);setError(null);}} placeholder={`Ej. Carga inicial de ${copy.plural}`} aria-invalid={Boolean(error&&!reason.trim())||undefined}/></label>
    {error&&<p className="restaurant-import__request-error" role="alert">{error}</p>}
  </Modal>;
}
