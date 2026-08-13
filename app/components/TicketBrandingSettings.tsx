"use client";
/* eslint-disable @next/next/no-img-element -- El logotipo procede del bucket de la empresa y sólo es una vista previa pequeña. */

import { ImagePlus, ReceiptText, Save, X } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { Button, Input, Select, useToast } from "@/app/components/ui/primitives";
import { DataState } from "@/app/components/ui/data";
import { getSupabaseClient } from "@/app/lib/supabase";

type TicketBranding = {
  company_id: string; display_name: string; legal_name: string | null; tax_id: string | null; contact_line: string | null; document_title: string; header_message: string | null; website: string | null; return_policy: string | null; footer_message: string; paper_width: "58mm" | "80mm"; show_customer: boolean; show_product_code: boolean; show_payment_details: boolean; show_tax_id: boolean; logo_path: string | null;
};
type TicketLocation = { id: string; name: string; external_code: string };
type TicketLocationPreview = { id: string; code: string; name: string; address: string | null; contact_phone: string | null };

function publicLogoUrl(path: string | null) { return path ? getSupabaseClient().storage.from("ticket-branding-assets").getPublicUrl(path).data.publicUrl : null; }

function normalizeBranding(value: Partial<TicketBranding>): TicketBranding {
  return {
    company_id: value.company_id ?? "",
    display_name: value.display_name ?? "",
    legal_name: value.legal_name ?? null,
    tax_id: value.tax_id ?? null,
    contact_line: value.contact_line ?? null,
    document_title: value.document_title ?? "TICKET DE VENTA",
    header_message: value.header_message ?? null,
    website: value.website ?? null,
    return_policy: value.return_policy ?? null,
    footer_message: value.footer_message ?? "Gracias por su compra",
    paper_width: value.paper_width === "58mm" ? "58mm" : "80mm",
    show_customer: value.show_customer ?? true,
    show_product_code: value.show_product_code ?? false,
    show_payment_details: value.show_payment_details ?? true,
    show_tax_id: value.show_tax_id ?? false,
    logo_path: value.logo_path ?? null,
  };
}

function TicketPreview({ branding, logoUrl }: { branding: TicketBranding; logoUrl: string | null }) {
  const [locations,setLocations]=useState<TicketLocation[]>([]);const [locationId,setLocationId]=useState("");const [location,setLocation]=useState<TicketLocationPreview|null>(null);
  useEffect(()=>{if(!branding.company_id)return;void getSupabaseClient().from("locations").select("id,name,external_code").eq("company_id",branding.company_id).eq("is_active",true).order("name").then(({data})=>{const items=(data??[]) as TicketLocation[];setLocations(items);setLocationId(current=>current||items[0]?.id||"");const first=items[0];if(first)setLocation(current=>current??{id:first.id,code:first.external_code,name:first.name,address:null,contact_phone:null});});},[branding.company_id]);
  useEffect(()=>{if(!locationId)return;void getSupabaseClient().rpc("get_ticket_location_preview",{p_company_id:branding.company_id,p_location_id:locationId}).then(({data})=>{if(data)setLocation(data as TicketLocationPreview);});},[branding.company_id,locationId]);
  const onLocationChange=(value:string)=>{const selected=locations.find(item=>item.id===value);if(selected)setLocation({id:selected.id,code:selected.external_code,name:selected.name,address:null,contact_phone:null});setLocationId(value);};
  return <aside className={`ticket-preview ticket-preview--${branding.paper_width}`} aria-label="Vista previa del ticket">
    <header><span>Vista previa</span><strong>{branding.paper_width}</strong></header>
    {locations.length>0&&<Select ariaLabel="Sucursal para vista previa" value={locationId} onValueChange={onLocationChange} options={locations.map(item=>({value:item.id,label:`${item.name} · ${item.external_code}`}))}/>}
    <section className="ticket-automatic-data" aria-labelledby="ticket-automatic-data-title">
      <header><div><strong id="ticket-automatic-data-title">Datos automáticos</strong><span>Se toman de la venta y de la sucursal seleccionada.</span></div><Link href="/satrapy/configuracion/empresa/sucursales">Editar sucursal</Link></header>
      <dl>
        <div><dt>Sucursal</dt><dd>{location?`${location.name} · ${location.code}`:"Selecciona una sucursal"}</dd></div>
        <div><dt>Domicilio</dt><dd>{location?.address??"Pendiente en el maestro de la sucursal"}</dd></div>
        <div><dt>Teléfono</dt><dd>{location?.contact_phone??"Pendiente en el maestro de la sucursal"}</dd></div>
        <div><dt>Caja y colaborador</dt><dd>Se registran automáticamente al cobrar.</dd></div>
      </dl>
    </section>
    <article className="ticket-preview__paper">{logoUrl ? <img src={logoUrl} alt="Logotipo en ticket" /> : <ReceiptText size={25} />}<strong>{branding.display_name}</strong>{branding.legal_name && branding.legal_name !== branding.display_name && <small>{branding.legal_name}</small>}{branding.show_tax_id && branding.tax_id && <small>RFC {branding.tax_id}</small>}{location&&<b>{location.name} · {location.code}</b>}{location?.address&&<small>{location.address}</small>}{location?.contact_phone&&<small>Tel. {location.contact_phone}</small>}{branding.contact_line && <small>{branding.contact_line}</small>}{branding.header_message && <p>{branding.header_message}</p>}<b>{branding.document_title}</b><b>0000000012</b>{branding.show_customer && <span>Venta de mostrador</span>}<small>23 jul 2026, 2:30 p.m.</small><small>Atendió: Colaborador de ejemplo · Caja principal</small><hr/><div className="ticket-preview__line"><span>1 x Producto de ejemplo {branding.show_product_code && <small>· SKU-001</small>}</span><b>$125.00</b></div><div className="ticket-preview__line"><span>2 x Insumo de muestra {branding.show_product_code && <small>· SKU-002</small>}</span><b>$80.00</b></div><hr/><div className="ticket-preview__total"><b>TOTAL</b><b>$205.00</b></div>{branding.show_payment_details && <div className="ticket-preview__payment"><span>Pago <b>EFECTIVO</b></span><span>Recibido <b>$300.00</b></span><span>Cambio <b>$95.00</b></span></div>}<hr/><p>{branding.footer_message}</p>{branding.return_policy && <small>{branding.return_policy}</small>}{branding.website && <small>{branding.website}</small>}</article>
    <p>La sucursal, caja y persona que atendió se toman automáticamente al cobrar.</p>
  </aside>;
}

export function TicketBrandingSettings({ companyId }: { companyId: string }) {
  const { toast } = useToast();
  const [branding, setBranding] = useState<TicketBranding | null>(null);
  const [loading, setLoading] = useState(true); const [saving, setSaving] = useState(false); const [uploading, setUploading] = useState(false); const [error, setError] = useState<string | null>(null);
  const logoUrl = publicLogoUrl(branding?.logo_path ?? null);
  const update = (patch: Partial<TicketBranding>) => setBranding((current) => current ? { ...current, ...patch } : current);
  const load = useCallback(async () => {
    setLoading(true); const { data, error: loadError } = await getSupabaseClient().rpc("get_ticket_branding", { p_company_id: companyId });
    if (loadError) { setError(loadError.message); setBranding(null); } else { setBranding(normalizeBranding({ ...((data ?? {}) as Partial<TicketBranding>), company_id: companyId })); setError(null); } setLoading(false);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  async function uploadLogo(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0]; event.currentTarget.value = ""; if (!file) return;
    if (!["image/png", "image/jpeg"].includes(file.type) || file.size > 2 * 1024 * 1024) { toast({ title: "Archivo no válido", description: "Usa PNG o JPG de hasta 2 MB.", tone: "error" }); return; }
    setUploading(true); const extension = file.type === "image/png" ? "png" : "jpg"; const path = `${companyId}/ticket-logo-${crypto.randomUUID()}.${extension}`;
    const { error: uploadError } = await getSupabaseClient().storage.from("ticket-branding-assets").upload(path, file, { contentType: file.type, upsert: false });
    if (uploadError) toast({ title: "No se pudo cargar el logotipo", description: uploadError.message, tone: "error" }); else { update({ logo_path: path }); toast({ title: "Logotipo cargado", description: "Guarda los cambios para aplicarlo al ticket.", tone: "success" }); }
    setUploading(false);
  }
  async function save(event: React.FormEvent) {
    event.preventDefault(); if (!branding) return; setSaving(true);
    const { data, error: saveError } = await getSupabaseClient().rpc("update_ticket_branding", {
      p_company_id: companyId, p_display_name: branding.display_name, p_contact_line: branding.contact_line, p_footer_message: branding.footer_message, p_logo_path: branding.logo_path, p_document_title: branding.document_title, p_header_message: branding.header_message, p_website: branding.website, p_return_policy: branding.return_policy, p_paper_width: branding.paper_width, p_show_customer: branding.show_customer, p_show_product_code: branding.show_product_code, p_show_payment_details: branding.show_payment_details, p_show_tax_id: branding.show_tax_id,
    });
    if (saveError) toast({ title: "No se pudo guardar", description: saveError.message, tone: "error" }); else { setBranding(normalizeBranding({ ...((data ?? {}) as Partial<TicketBranding>), company_id: companyId })); toast({ title: "Ticket actualizado", description: "La configuración se usará al imprimir ventas.", tone: "success" }); }
    setSaving(false);
  }
  if (loading) return <DataState loading error={null} hasData={0} empty="">{null}</DataState>;
  if (error || !branding) return <DataState loading={false} error={error ?? "No se pudo cargar la configuración."} hasData={0} empty="" errorAction={<Button onClick={() => void load()}>Reintentar</Button>}>{null}</DataState>;
  return <section className="ticket-branding-settings"><header><div><h2>Ticket de venta</h2><p>Personaliza el comprobante y revisa el resultado antes de guardar. No se alteran ventas confirmadas.</p></div></header><div className="ticket-branding-workspace"><form className="sales-form ticket-branding-form" onSubmit={save}><fieldset><legend>Encabezado</legend><label>Nombre visible<Input required maxLength={120} value={branding.display_name} onChange={(event) => update({ display_name: event.target.value })} /></label><label>Título del documento<Input required maxLength={60} value={branding.document_title} onChange={(event) => update({ document_title: event.target.value })} /></label><label>Contacto o dirección<Input maxLength={180} value={branding.contact_line ?? ""} onChange={(event) => update({ contact_line: event.target.value || null })} placeholder="Tel. 555 000 0000 · Ciudad, Estado" /></label><label>Mensaje de bienvenida<textarea maxLength={180} value={branding.header_message ?? ""} onChange={(event) => update({ header_message: event.target.value || null })} placeholder="Ej. Gracias por elegirnos" /></label></fieldset><fieldset><legend>Presentación</legend><Select ariaLabel="Ancho de papel" value={branding.paper_width} onValueChange={(value) => update({ paper_width: value as TicketBranding["paper_width"] })} options={[{ value: "58mm", label: "Papel térmico 58 mm" }, { value: "80mm", label: "Papel térmico 80 mm" }]} /><div className="ticket-branding-checks"><label><input type="checkbox" checked={branding.show_customer} onChange={(event) => update({ show_customer: event.target.checked })} /> Mostrar cliente</label><label><input type="checkbox" checked={branding.show_product_code} onChange={(event) => update({ show_product_code: event.target.checked })} /> Mostrar código de producto</label><label><input type="checkbox" checked={branding.show_payment_details} onChange={(event) => update({ show_payment_details: event.target.checked })} /> Mostrar pago y cambio</label>{branding.tax_id && <label><input type="checkbox" checked={branding.show_tax_id} onChange={(event) => update({ show_tax_id: event.target.checked })} /> Mostrar RFC de la empresa</label>}</div></fieldset><fieldset><legend>Pie de ticket</legend><label>Mensaje final<Input required maxLength={180} value={branding.footer_message} onChange={(event) => update({ footer_message: event.target.value })} /></label><label>Política de cambios o devoluciones<textarea maxLength={180} value={branding.return_policy ?? ""} onChange={(event) => update({ return_policy: event.target.value || null })} placeholder="Ej. Cambios dentro de 7 días con ticket" /></label><label>Sitio web o red social<Input maxLength={120} value={branding.website ?? ""} onChange={(event) => update({ website: event.target.value || null })} placeholder="www.miempresa.mx" /></label></fieldset><fieldset><legend>Logotipo</legend><div className="ticket-branding-logo"><div>{logoUrl ? <img src={logoUrl} alt="Logotipo del ticket" /> : <ImagePlus size={20} />}<span>{logoUrl ? "Logotipo listo" : "Sin logotipo"}</span></div><label className="button button--secondary"><ImagePlus size={15} /> {logoUrl ? "Reemplazar" : "Cargar logotipo"}<input type="file" accept="image/png,image/jpeg" onChange={(event) => void uploadLogo(event)} hidden /></label>{branding.logo_path && <Button type="button" variant="ghost" onClick={() => update({ logo_path: null })}><X size={15} /> Quitar</Button>}</div><small>PNG o JPG, máximo 2 MB.</small></fieldset><Button type="submit" variant="primary" loading={saving || uploading} disabled={uploading}><Save size={16} /> Guardar configuración</Button></form><TicketPreview branding={branding} logoUrl={logoUrl} /></div></section>;
}
