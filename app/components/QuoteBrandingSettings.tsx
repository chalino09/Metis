"use client";

import { FileText, Save } from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import { Button, Input, useToast } from "@/app/components/ui/primitives";
import { DataState } from "@/app/components/ui/data";
import { getSupabaseClient } from "@/app/lib/supabase";

type Branding = {
  display_name: string; legal_name: string | null; tax_id: string | null; document_title: string;
  contact_line: string | null; header_message: string | null; footer_message: string;
  terms_and_conditions: string | null; website: string | null; logo_path: string | null;
};

function normalize(value: Partial<Branding>): Branding {
  return {
    display_name: value.display_name ?? "", legal_name: value.legal_name ?? null, tax_id: value.tax_id ?? null,
    document_title: value.document_title ?? "COTIZACIÓN", contact_line: value.contact_line ?? null,
    header_message: value.header_message ?? null, footer_message: value.footer_message ?? "Gracias por considerar nuestra propuesta.",
    terms_and_conditions: value.terms_and_conditions ?? null, website: value.website ?? null, logo_path: value.logo_path ?? null,
  };
}

function QuotePreview({ branding }: { branding: Branding }) {
  return <aside className="quote-format-preview" aria-label="Vista previa de cotización">
    <header><span>Vista previa</span><strong>A4</strong></header>
    <article>
      <div className="quote-format-preview__head"><FileText size={28} /><span><strong>{branding.display_name}</strong>{branding.contact_line && <small>{branding.contact_line}</small>}</span><b>{branding.document_title}<small>COT-260723-AB12CD</small></b></div>
      {branding.header_message && <p>{branding.header_message}</p>}
      <div className="quote-format-preview__client"><small>CLIENTE</small><strong>Cliente de ejemplo</strong><span>CLI-001 · Sucursal principal</span></div>
      <div className="quote-format-preview__table"><b>Producto de ejemplo</b><span>2 × $125.00</span><strong>$250.00</strong><b>Insumo de muestra</b><span>1 × $80.00</span><strong>$80.00</strong></div>
      <div className="quote-format-preview__total"><span>Total</span><strong>$330.00</strong></div>
      {branding.terms_and_conditions && <p><b>Condiciones</b>{branding.terms_and_conditions}</p>}
      <footer>{branding.footer_message}{branding.website && <small>{branding.website}</small>}</footer>
    </article>
    <p>El logotipo se toma de la configuración de Ticket; los documentos ya generados conservan su formato.</p>
  </aside>;
}

export function QuoteBrandingSettings({ companyId }: { companyId: string }) {
  const { toast } = useToast();
  const [branding, setBranding] = useState<Branding | null>(null);
  const [loading, setLoading] = useState(true); const [saving, setSaving] = useState(false); const [error, setError] = useState<string | null>(null);
  const update = (patch: Partial<Branding>) => setBranding((current) => current ? { ...current, ...patch } : current);
  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: loadError } = await getSupabaseClient().rpc("get_quote_branding", { p_company_id: companyId });
    if (loadError) { setError(loadError.message); setBranding(null); } else { setBranding(normalize((data ?? {}) as Partial<Branding>)); setError(null); }
    setLoading(false);
  }, [companyId]);
  useEffect(() => { void Promise.resolve().then(load); }, [load]);
  async function save(event: React.FormEvent) {
    event.preventDefault(); if (!branding) return; setSaving(true);
    const { data, error: saveError } = await getSupabaseClient().rpc("update_quote_branding", {
      p_company_id: companyId, p_display_name: branding.display_name, p_document_title: branding.document_title,
      p_contact_line: branding.contact_line, p_header_message: branding.header_message, p_footer_message: branding.footer_message,
      p_terms_and_conditions: branding.terms_and_conditions, p_website: branding.website,
    });
    setSaving(false);
    if (saveError) toast({ title: "No se pudo guardar", description: saveError.message, tone: "error" });
    else { setBranding(normalize((data ?? {}) as Partial<Branding>)); toast({ title: "Formato de cotización actualizado", description: "Se aplicará en los documentos nuevos.", tone: "success" }); }
  }
  return <section className="ticket-branding-settings quote-branding-settings">
    <header><div><h2>Formato de cotización</h2><p>Personaliza el PDF A4. No cambia cotizaciones cuyo documento ya fue generado.</p></div></header>
    <DataState loading={loading} error={error} hasData={branding ? 1 : 0} empty="No se pudo cargar el formato." errorAction={<Button size="sm" onClick={() => void load()}>Reintentar</Button>}>
      {branding && <div className="ticket-branding-workspace"><form className="sales-form ticket-branding-form" onSubmit={save}>
        <fieldset><legend>Encabezado</legend><label>Nombre visible<Input required maxLength={120} value={branding.display_name} onChange={(event) => update({ display_name: event.target.value })} /></label><label>Título del documento<Input required maxLength={60} value={branding.document_title} onChange={(event) => update({ document_title: event.target.value })} /></label><label>Contacto o dirección<Input maxLength={180} value={branding.contact_line ?? ""} onChange={(event) => update({ contact_line: event.target.value || null })} placeholder="Tel. 555 000 0000 · Ciudad, Estado" /></label><label>Mensaje de presentación<textarea maxLength={300} value={branding.header_message ?? ""} onChange={(event) => update({ header_message: event.target.value || null })} placeholder="Ej. Nos complace presentar la siguiente propuesta." /></label></fieldset>
        <fieldset><legend>Pie y condiciones</legend><label>Mensaje final<Input required maxLength={180} value={branding.footer_message} onChange={(event) => update({ footer_message: event.target.value })} /></label><label>Condiciones de pago o entrega<textarea maxLength={600} value={branding.terms_and_conditions ?? ""} onChange={(event) => update({ terms_and_conditions: event.target.value || null })} placeholder="Ej. Precios sujetos a vigencia. Entrega conforme a disponibilidad." /></label><label>Sitio web o red social<Input maxLength={120} value={branding.website ?? ""} onChange={(event) => update({ website: event.target.value || null })} placeholder="www.miempresa.mx" /></label></fieldset>
        <p className="settings-note">El logotipo se administra una sola vez en Ticket y se reutiliza en la cotización.</p><Button type="submit" variant="primary" loading={saving}><Save size={16} /> Guardar formato</Button>
      </form><QuotePreview branding={branding} /></div>}
    </DataState>
  </section>;
}
