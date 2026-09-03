"use client";
/* eslint-disable @next/next/no-img-element -- Las páginas se renderizan desde el PDF generado como imágenes locales de vista previa. */

import { AlertTriangle, Check, Download, Eye, FileCheck2, MessageSquare, PackageCheck, Plus, Printer, Send, Trash2, UserPlus, X, XCircle } from "lucide-react";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { DataRefreshStatus, DataState, InteractiveTableRow, Table } from "@/app/components/ui/data";
import { Badge, Drawer, Modal, useToast } from "@/app/components/ui/primitives";
import { SalesButton as Button, SalesDataPagination as DataPagination, SalesDataToolbar as DataToolbar, SalesField as Field, SalesInput as Input } from "@/app/components/reui/sales-controls";
import { Tabs as ReuiTabs, TabsList as ReuiTabsList, TabsTrigger as ReuiTabsTrigger } from "@/app/components/reui/tabs";
import { CompactSelect } from "@/components/reui/compact-select";
import { Autocomplete, AutocompleteContent, AutocompleteEmpty, AutocompleteInput, AutocompleteItem, AutocompleteList } from "@/components/reui/autocomplete";
import { QuotePreparationInbox } from "@/app/components/QuotePreparationInbox";
import { createQuotePdfBlob, downloadQuotePdf, printQuotePdf, type QuotePdfDocument } from "@/app/lib/quote-pdf";
import { getSupabaseClient } from "@/app/lib/supabase";

type Status = "draft" | "approved" | "sent" | "accepted" | "not_converted";
type Location = { id: string; name: string; code: string };
type Customer = { id: string; code: string; display_name: string };
type Product = { product_id: string; code: string | null; name: string; unit: string | null; price_amount: number; currency_code: string };
type AvailabilityStatus = "available" | "partial" | "unavailable" | "not_applicable";
type Line = { product_id: string; product_code?: string | null; product_name: string; unit_name?: string | null; quantity: number | ""; unit_total_amount: number; line_total_amount?: number; inventory_tracked?: boolean; quantity_on_hand?: number | null; available_quantity?: number | null; shortage_quantity?: number; availability_status?: AvailabilityStatus };
type QuoteRow = { id: string; folio: string; status: Status; customer_name: string; location_name: string; currency_code: string; total_amount: number; valid_until: string | null; updated_at: string };
type FollowUp = { id: string; event_type: "created" | "approved" | "sent" | "accepted" | "not_converted" | "note"; reason_code: string | null; note: string | null; created_at: string; actor_name: string | null };
type Detail = { id: string; folio: string; status: Status; currency_code: string; valid_until: string | null; subtotal_amount: number; tax_amount: number; total_amount: number; approved_at: string | null; approved_by: { id: string; name: string | null } | null; supply_status?: "available" | "pending"; shortage_line_count?: number; customer: Customer; location: Location; lines: Line[]; follow_ups: FollowUp[]; order: { id: string; folio: string; status: "open" | "completed" | "cancelled" } | null };
type Draft = { id?: string; locationId: string; customerId: string; customerLabel: string; validUntil: string; lines: Line[] };

const PAGE_SIZE = 25;
const statusLabels: Record<Status, string> = { draft: "Borrador", approved: "Aprobada", sent: "Enviada", accepted: "Aceptada", not_converted: "No concretada" };
const reasonLabels: Record<string, string> = { rejected_by_customer: "Rechazada por el cliente", cancelled_by_customer: "Cancelada por el cliente", lost_to_competition: "Se eligió otra opción", no_follow_up_response: "Sin respuesta", other: "Otro motivo" };
const money = (amount: number, currency = "MXN") => new Intl.NumberFormat("es-MX", { style: "currency", currency }).format(Number(amount ?? 0));
const dateTime = (value: string) => new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
const today = () => new Date().toISOString().slice(0, 10);
const expiry = () => { const value = new Date(); value.setDate(value.getDate() + 15); return value.toISOString().slice(0, 10); };

function QuoteBadge({ status }: { status: Status }) {
  return <Badge tone={status === "approved" || status === "accepted" ? "success" : status === "not_converted" ? "danger" : status === "sent" ? "info" : "neutral"}>{statusLabels[status]}</Badge>;
}

function availabilityLabel(line: Line) {
  if (line.availability_status === "unavailable") return "Sin existencia";
  if (line.availability_status === "partial") return `Faltan ${Number(line.shortage_quantity ?? 0).toLocaleString("es-MX")}`;
  if (line.availability_status === "available") return "Disponible";
  return "No aplica";
}

function QuotePreview({ documentData }: { documentData: QuotePdfDocument }) {
  const [pages, setPages] = useState<string[]>([]);
  const [previewError, setPreviewError] = useState<string | null>(null);
  useEffect(() => {
    let active = true; let loadedPdf: { cleanup: () => Promise<unknown> } | null = null;
    void (async () => {
      const pdfjs = await import("pdfjs-dist");
      pdfjs.GlobalWorkerOptions.workerPort ??= new Worker(new URL("pdfjs-dist/build/pdf.worker.min.mjs", import.meta.url), { type: "module" });
      const blob = await createQuotePdfBlob(documentData);
      const source = await blob.arrayBuffer();
      const pdfDocument = await pdfjs.getDocument({ data: new Uint8Array(source) }).promise;
      loadedPdf = pdfDocument;
      const rendered: string[] = [];
      for (let number = 1; number <= pdfDocument.numPages; number += 1) {
        const page = await pdfDocument.getPage(number);
        const viewport = page.getViewport({ scale: 1.45 });
        const canvas = document.createElement("canvas");
        canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height);
        const context = canvas.getContext("2d");
        if (!context) throw new Error("El navegador no pudo preparar el visor.");
        await page.render({ canvas, canvasContext: context, viewport }).promise;
        rendered.push(canvas.toDataURL("image/png"));
      }
      if (active) setPages(rendered);
    })().catch((value) => { if (active) setPreviewError(value instanceof Error ? value.message : "No se pudo generar la vista previa."); });
    return () => { active = false; if (loadedPdf) void loadedPdf.cleanup(); };
  }, [documentData]);
  if (previewError) return <div className="quote-document-frame__state" role="alert"><strong>No se pudo mostrar el PDF</strong><span>{previewError}</span></div>;
  if (!pages.length) return <div className="quote-document-frame__state" role="status"><strong>Preparando documento…</strong><span>Estamos componiendo el PDF A4.</span></div>;
  return <div className="quote-document-pages" aria-label={`Vista previa de ${documentData.quote.folio}`}>{pages.map((page, index) => <img key={page.slice(-32)} src={page} alt={`Página ${index + 1} de la cotización ${documentData.quote.folio}`} />)}</div>;
}

export function SalesQuotesView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { toast } = useToast();
  const router = useRouter();
  const request = useRef(0); const productRequest = useRef(0);
  const [rows, setRows] = useState<QuoteRow[]>([]); const [total, setTotal] = useState(0); const [page, setPage] = useState(1); const [query, setQuery] = useState(""); const [status, setStatus] = useState("all"); const [loading, setLoading] = useState(true); const [error, setError] = useState<string | null>(null);
  const [locations, setLocations] = useState<Location[]>([]); const [draft, setDraft] = useState<Draft | null>(null); const [detail, setDetail] = useState<Detail | null>(null); const [saving, setSaving] = useState(false);
  const [customerQuery, setCustomerQuery] = useState(""); const [customers, setCustomers] = useState<Customer[]>([]); const [customerOpen, setCustomerOpen] = useState(false); const [productOpen, setProductOpen] = useState(false); const [productQuery, setProductQuery] = useState(""); const [products, setProducts] = useState<Product[]>([]);
  const [followUp, setFollowUp] = useState<{ event: "accepted" | "not_converted" | "note"; reason: string; note: string } | null>(null);
  const [approval, setApproval] = useState<{ note: string } | null>(null);
  const [quickCustomer, setQuickCustomer] = useState({ name: "", taxId: "", phone: "" }); const [quickCustomerOpen, setQuickCustomerOpen] = useState(false);
  const [documentData, setDocumentData] = useState<QuotePdfDocument | null>(null); const [documentBusy, setDocumentBusy] = useState<"preview" | "print" | "download" | null>(null);
  const [section, setSection] = useState<"quotes" | "prepare">("quotes");
  const canManage = permissions.includes("manage_sales_quotes"); const canQuickCustomer = canManage && permissions.includes("manage_customers");

  const load = useCallback(async () => {
    const current = ++request.current; setLoading(true);
    const { data, error: loadError } = await getSupabaseClient().rpc("list_sales_quotes", { p_company_id: companyId, p_query: query || null, p_status: status === "all" ? null : status, p_page: page, p_page_size: PAGE_SIZE });
    if (current !== request.current) return;
    const result = data as { items?: QuoteRow[]; total?: number } | null; setRows(result?.items ?? []); setTotal(result?.total ?? 0); setError(loadError?.message ?? null); setLoading(false);
  }, [companyId, page, query, status]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 180); return () => window.clearTimeout(timer); }, [load]);
  useEffect(() => { void getSupabaseClient().rpc("get_sales_quote_context", { p_company_id: companyId }).then(({ data }) => setLocations(((data as { locations?: Location[] } | null)?.locations ?? []))); }, [companyId]);
  useEffect(() => {
    if (!draft || !customerOpen) return;
    const timer = window.setTimeout(async () => { const { data } = await getSupabaseClient().rpc("search_sales_quote_customers", { p_company_id: companyId, p_query: customerQuery || null, p_limit: 30 }); setCustomers(((data as { items?: Customer[] } | null)?.items ?? [])); }, 160);
    return () => window.clearTimeout(timer);
  }, [companyId, customerOpen, customerQuery, draft]);
  useEffect(() => {
    if (!draft || !productOpen || !draft.locationId || !draft.customerId || productQuery.trim().length < 2) return;
    const current = ++productRequest.current;
    const timer = window.setTimeout(async () => { const { data } = await getSupabaseClient().rpc("search_sales_quote_products", { p_company_id: companyId, p_location_id: draft.locationId, p_customer_id: draft.customerId, p_query: productQuery, p_limit: 30 }); if (current === productRequest.current) setProducts(((data as { items?: Product[] } | null)?.items ?? [])); }, 160);
    return () => window.clearTimeout(timer);
  }, [companyId, draft, productOpen, productQuery]);

  function createDraft() {
    const location = locations[0];
    if (!location) { toast({ title: "Sin sucursal disponible", description: "Necesitas acceso a una sucursal activa para cotizar.", tone: "error" }); return; }
    setDetail(null); setCustomerQuery(""); setCustomers([]); setProductOpen(false); setProducts([]); setDraft({ locationId: location.id, customerId: "", customerLabel: "", validUntil: expiry(), lines: [] });
  }
  const openDetail = useCallback(async (id: string) => {
    const { data, error: detailError } = await getSupabaseClient().rpc("get_sales_quote_detail", { p_company_id: companyId, p_quote_id: id });
    if (detailError) toast({ title: "No se abrió la cotización", description: detailError.message, tone: "error" }); else setDetail(data as Detail);
  }, [companyId, toast]);
  useEffect(() => {
    const quoteId = new URLSearchParams(window.location.search).get("quote");
    if (!quoteId) return;
    const timer = window.setTimeout(() => void openDetail(quoteId), 0);
    return () => window.clearTimeout(timer);
  }, [openDetail]);
  function selectCustomer(customer: Customer) { if (!draft) return; setCustomerQuery(customer.display_name); setCustomerOpen(false); setDraft({ ...draft, customerId: customer.id, customerLabel: customer.display_name, lines: [] }); }
  function clearCustomer() { if (!draft) return; setCustomerQuery(""); setCustomers([]); setDraft({ ...draft, customerId: "", customerLabel: "", lines: [] }); }
  function editDetail() {
    if (!detail || detail.status !== "draft") return;
    setCustomerQuery(detail.customer.display_name); setDraft({ id: detail.id, locationId: detail.location.id, customerId: detail.customer.id, customerLabel: detail.customer.display_name, validUntil: detail.valid_until ?? "", lines: detail.lines.map((line) => ({ ...line, quantity: Number(line.quantity), unit_total_amount: Number(line.unit_total_amount), line_total_amount: Number(line.line_total_amount) })) }); setDetail(null);
  }
  function chooseProduct(product: Product) {
    if (!draft) return;
    if (draft.lines.some((line) => line.product_id === product.product_id)) { toast({ title: "Producto repetido", description: "Ajusta la cantidad en la partida existente.", tone: "error" }); return; }
    setDraft({ ...draft, lines: [...draft.lines, { product_id: product.product_id, product_code: product.code, product_name: product.name, unit_name: product.unit, quantity: 1, unit_total_amount: Number(product.price_amount), line_total_amount: Number(product.price_amount) }] }); setProductOpen(false); setProductQuery("");
  }
  function setQuantity(index: number, rawQuantity: string) {
    if (!draft) return;
    const quantity = rawQuantity === "" ? "" : Number(rawQuantity);
    setDraft({ ...draft, lines: draft.lines.map((line, candidate) => candidate === index ? { ...line, quantity, line_total_amount: Number(line.unit_total_amount) * Number(quantity || 0) } : line) });
  }
  async function save() {
    if (!draft || !draft.customerId || !draft.locationId || !draft.lines.length || draft.lines.some((line) => !(Number(line.quantity) > 0))) { toast({ title: "Revisa la cotización", description: "Selecciona cliente, sucursal y al menos un producto con cantidad válida.", tone: "error" }); return; }
    setSaving(true);
    const { data, error: saveError } = await getSupabaseClient().rpc("save_sales_quote", { p_company_id: companyId, p_quote_id: draft.id ?? null, p_location_id: draft.locationId, p_customer_id: draft.customerId, p_valid_until: draft.validUntil || null, p_lines: draft.lines.map((line) => ({ product_id: line.product_id, quantity: Number(line.quantity) })) });
    setSaving(false);
    if (saveError) { toast({ title: "No se guardó la cotización", description: saveError.message, tone: "error" }); return; }
    const wasDraft = Boolean(draft.id); setDraft(null); setDetail(data as Detail); toast({ title: wasDraft ? "Borrador actualizado" : "Cotización creada", description: "El servidor confirmó precio y total; no se reservó inventario.", tone: "success" }); await load();
  }
  async function createQuickCustomer(event: FormEvent) {
    event.preventDefault(); if (!draft || !quickCustomer.name.trim()) return; setSaving(true);
    const { data, error: createError } = await getSupabaseClient().rpc("create_sales_quote_customer", { p_company_id: companyId, p_location_id: draft.locationId, p_display_name: quickCustomer.name.trim(), p_tax_id: quickCustomer.taxId.trim() || null, p_phone: quickCustomer.phone.trim() || null });
    setSaving(false);
    if (createError || !data) { toast({ title: "No se pudo crear el cliente", description: createError?.message ?? "Verifica nombre, RFC y teléfono.", tone: "error" }); return; }
    selectCustomer(data as Customer); setQuickCustomer({ name: "", taxId: "", phone: "" }); setQuickCustomerOpen(false); toast({ title: "Cliente creado", description: "Quedó seleccionado para esta cotización y permanece de contado.", tone: "success" });
  }
  async function record(event: "sent" | "accepted" | "not_converted" | "note", reason: string | null = null, note: string | null = null) {
    if (!detail) return; setSaving(true);
    const { data, error: recordError } = await getSupabaseClient().rpc("record_sales_quote_follow_up", { p_company_id: companyId, p_quote_id: detail.id, p_event_type: event, p_reason_code: reason, p_note: note });
    setSaving(false);
    if (recordError) { toast({ title: "No se registró el seguimiento", description: recordError.message, tone: "error" }); return; }
    setFollowUp(null); setDetail(data as Detail); toast({ title: event === "not_converted" ? "Motivo registrado" : "Seguimiento registrado", description: "El historial comercial fue actualizado.", tone: "success" }); await load();
  }
  async function approve() {
    if (!detail || detail.status !== "draft" || !approval) return;
    setSaving(true);
    const { data, error: approvalError } = await getSupabaseClient().rpc("approve_sales_quote", { p_company_id: companyId, p_quote_id: detail.id, p_note: approval.note.trim() || null });
    setSaving(false);
    if (approvalError || !data) { toast({ title: "No se aprobó la cotización", description: approvalError?.message ?? "Revisa la vigencia e intenta nuevamente.", tone: "error" }); return; }
    const approved = data as Detail;
    setApproval(null); setDetail(approved); setDocumentData(null);
    toast({ title: "Cotización aprobada", description: "El documento quedó finalizado y registrado para su envío.", tone: "success" });
    await load();
  }
  async function createOrder() {
    if (!detail || detail.status !== "accepted") return;
    setSaving(true);
    const { data, error: orderError } = await getSupabaseClient().rpc("create_sales_order_from_quote", { p_company_id: companyId, p_quote_id: detail.id, p_expected_delivery_date: null });
    setSaving(false);
    if (orderError || !data) { toast({ title: "No se creó la orden", description: orderError?.message ?? "Intenta nuevamente.", tone: "error" }); return; }
    toast({ title: "Pedido creado", description: "Conserva el cliente y los productos confirmados de la cotización.", tone: "success" });
    router.push(`/satrapy/ventas/pedidos?order=${(data as { id: string }).id}`);
  }
  async function prepareDocument(mode: "preview" | "print" | "download") {
    if (!detail) return; setDocumentBusy(mode);
    const { data, error: documentError } = await getSupabaseClient().rpc("get_sales_quote_document", { p_company_id: companyId, p_quote_id: detail.id });
    if (documentError || !data) { setDocumentBusy(null); toast({ title: "No se pudo preparar el documento", description: documentError?.message ?? "Intenta nuevamente.", tone: "error" }); return; }
    const prepared = data as QuotePdfDocument & { branding: QuotePdfDocument["branding"] & { logo_path?: string | null } };
    const logoPath = prepared.branding.logo_path;
    const documentWithLogo: QuotePdfDocument = { ...prepared, branding: { ...prepared.branding, logo_url: logoPath ? getSupabaseClient().storage.from("ticket-branding-assets").getPublicUrl(logoPath).data.publicUrl : null } };
    try {
      if (mode === "preview") setDocumentData(documentWithLogo);
      if (mode === "print") await printQuotePdf(documentWithLogo);
      if (mode === "download") await downloadQuotePdf(documentWithLogo);
      if (mode !== "preview") toast({ title: mode === "print" ? "Cotización lista para imprimir" : "PDF descargado", tone: "success" });
    } catch (value) { toast({ title: "No se pudo generar el PDF", description: value instanceof Error ? value.message : "Intenta nuevamente.", tone: "error" }); }
    setDocumentBusy(null);
  }
  const draftTotal = draft?.lines.reduce((sum, line) => sum + Number(line.unit_total_amount) * Number(line.quantity || 0), 0) ?? 0;
  const supplyPending = detail?.supply_status === "pending";
  const shortageLines = detail?.lines.filter((line) => Number(line.shortage_quantity ?? 0) > 0) ?? [];

  return <div className="content-frame sales-quotes sales-reui-page">
    <div className="page-heading"><div><span className="eyebrow">Relación comercial</span><h1>Cotizaciones</h1><p>Prepara solicitudes recibidas y da seguimiento a las propuestas comerciales.</p></div>{section === "quotes" && canManage && <Button variant="primary" onClick={createDraft}><Plus size={16} /> Nueva cotización</Button>}</div>
    <ReuiTabs className="sales-quotes__tabs sales-reui-tabs" value={section} onValueChange={(value) => setSection(value as "quotes" | "prepare")}>
      <ReuiTabsList aria-label="Secciones de cotizaciones">
        <ReuiTabsTrigger value="quotes">Cotizaciones</ReuiTabsTrigger>
        <ReuiTabsTrigger value="prepare">Por preparar</ReuiTabsTrigger>
      </ReuiTabsList>
    </ReuiTabs>
    {section === "quotes" ? <>
    <DataToolbar search={query} onSearchChange={(value) => { setQuery(value); setPage(1); }} placeholder="Buscar folio o cliente" results={total} activeFilters={status === "all" ? 0 : 1} onClear={() => { setStatus("all"); setPage(1); }} filters={<CompactSelect className="sales-filter-select" ariaLabel="Filtrar por estado" value={status} onValueChange={(value) => { setStatus(value as Status | "all"); setPage(1); }} options={[{ value: "all", label: "Todos los estados" }, ...Object.entries(statusLabels).map(([value, label]) => ({ value, label }))]} />} />
    <DataRefreshStatus loading={loading} hasData={rows.length} />
    <DataState loading={loading && !rows.length} error={error} hasData={rows.length} emptyTitle={query || status !== "all" ? "No encontramos cotizaciones." : "Aún no hay cotizaciones."} empty={query || status !== "all" ? "Cambia o limpia los filtros para ampliar la búsqueda." : "Crea una cotización para iniciar el seguimiento comercial."} errorAction={<Button size="sm" onClick={() => void load()}>Reintentar</Button>}>
      <Table><thead><tr><th>Folio</th><th>Cliente</th><th>Sucursal</th><th>Vigencia</th><th>Estado</th><th className="number-cell">Total</th></tr></thead><tbody>{rows.map((quote) => <InteractiveTableRow key={quote.id} label={"Abrir cotización " + quote.folio} onActivate={() => void openDetail(quote.id)}><td><strong className="mono">{quote.folio}</strong><small>Actualizada {dateTime(quote.updated_at)}</small></td><td>{quote.customer_name}</td><td>{quote.location_name}</td><td>{quote.valid_until ? new Date(quote.valid_until + "T12:00:00").toLocaleDateString("es-MX") : "Sin fecha"}</td><td><QuoteBadge status={quote.status} /></td><td className="number-cell">{money(Number(quote.total_amount), quote.currency_code)}</td></InteractiveTableRow>)}</tbody></Table>
      <DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={setPage} />
    </DataState>
    </> : <QuotePreparationInbox companyId={companyId} canManage={canManage} canCreateCustomer={canQuickCustomer} onQuoteCreated={async (quoteId) => { setSection("quotes"); await load(); await openDetail(quoteId); }} />}
    <Drawer open={Boolean(draft)} onOpenChange={(open) => !open && !saving && setDraft(null)} title={draft?.id ? "Editar borrador" : "Nueva cotización"} className="sales-quote-drawer">{draft && <form className="sales-quote-form quote-composer" onSubmit={(event) => { event.preventDefault(); void save(); }}>
      <p className="sales-quote-form__notice">Una cotización no aparta producto ni bloquea ventas. El precio definitivo se confirma al guardar.</p>
      <section className="quote-composer__context"><Field label="Sucursal"><CompactSelect ariaLabel="Sucursal de la cotización" value={draft.locationId} onValueChange={(locationId) => { setDraft({ ...draft, locationId, lines: [] }); setProductOpen(false); }} options={locations.map((location) => ({ value: location.id, label: location.name }))} /></Field><Field label="Vigencia"><Input type="date" min={today()} value={draft.validUntil} onChange={(event) => setDraft({ ...draft, validUntil: event.target.value })} /></Field></section>
      <section className="quote-composer__customer"><header><div><strong>Cliente</strong><small>Define la lista de precio de la propuesta.</small></div>{canQuickCustomer && <Button type="button" size="sm" variant="ghost" onClick={() => { setQuickCustomer({ name: "", taxId: "", phone: "" }); setQuickCustomerOpen(true); }}><UserPlus size={15} /> Alta rápida</Button>}</header>{draft.customerId ? <div className="quote-composer__customer-chip"><span><strong>{draft.customerLabel}</strong><small>Cliente seleccionado</small></span><Button type="button" size="icon" variant="ghost" aria-label="Cambiar cliente" onClick={clearCustomer}><X size={15} /></Button></div> : <Autocomplete className="sales-quote-picker sales-reui-autocomplete" items={customers} value={customerQuery} open={customerOpen} onOpenChange={setCustomerOpen} onValueChange={setCustomerQuery} openOnInputClick autoHighlight itemToStringValue={(customer) => customer.display_name}><AutocompleteInput showClear={Boolean(customerQuery)} placeholder="Busca por nombre, clave o RFC" aria-label="Cliente" autoComplete="off" />{customerOpen && <AutocompleteContent><AutocompleteEmpty>{customerQuery.trim() ? "No se encontraron clientes." : "Escribe para buscar clientes."}</AutocompleteEmpty><AutocompleteList>{customers.map((customer) => <AutocompleteItem value={customer} key={customer.id} onClick={() => selectCustomer(customer)}><span><strong>{customer.display_name}</strong><small>{customer.code}</small></span></AutocompleteItem>)}</AutocompleteList></AutocompleteContent>}</Autocomplete>}</section>
      <div className="quote-composer__workspace"><section className="sales-quote-lines"><header><div><strong>Productos</strong><small>Los precios usan la lista vigente; la existencia se valida sólo al vender.</small></div><Button type="button" size="sm" variant="secondary" disabled={!draft.customerId} onClick={() => { setProductOpen(true); setProductQuery(""); }}><Plus size={14} /> Agregar producto</Button></header>{productOpen && <Autocomplete className="sales-quote-product-search sales-reui-autocomplete" items={products} value={productQuery} open={productOpen} onOpenChange={setProductOpen} onValueChange={setProductQuery} openOnInputClick autoHighlight itemToStringValue={(product) => product.name}><AutocompleteInput autoFocus showClear={Boolean(productQuery)} placeholder="Escribe al menos 2 letras para buscar" aria-label="Buscar producto para cotizar" />{productOpen && <AutocompleteContent><AutocompleteEmpty>{productQuery.trim().length < 2 ? "Escribe al menos 2 letras para buscar." : "Sin productos cotizables con precio vigente."}</AutocompleteEmpty><AutocompleteList>{productQuery.trim().length >= 2 && products.map((product) => <AutocompleteItem value={product} key={product.product_id} onClick={() => chooseProduct(product)}><span><strong>{product.name}</strong><small>{product.code ?? "Sin código"} · {product.unit ?? "Unidad"}</small></span><b>{money(Number(product.price_amount), product.currency_code)}</b></AutocompleteItem>)}</AutocompleteList></AutocompleteContent>}</Autocomplete>}{draft.lines.length ? <div className="sales-quote-lines__list">{draft.lines.map((line, index) => <article key={line.product_id}><span className="sales-quote-line__product"><strong>{line.product_name}</strong><small>{line.product_code ?? "Sin código"} · {money(Number(line.unit_total_amount))} c/u</small></span><label className="sales-quote-line__quantity"><span>Cantidad</span><Input aria-label={"Cantidad de " + line.product_name} type="number" min="0.001" step="0.001" inputMode="decimal" value={line.quantity} onChange={(event) => setQuantity(index, event.target.value)} /></label><span className="sales-quote-line__total"><small>Importe</small><b>{money(Number(line.unit_total_amount) * Number(line.quantity || 0))}</b></span><Button type="button" size="icon" variant="ghost" aria-label={"Quitar " + line.product_name} onClick={() => setDraft({ ...draft, lines: draft.lines.filter((_, candidate) => candidate !== index) })}><Trash2 size={15} /></Button></article>)}</div> : <p className="sales-quote-lines__empty">{draft.customerId ? "Agrega productos para preparar la propuesta." : "Selecciona o crea un cliente para comenzar."}</p>}</section><aside className="quote-composer__summary"><span>Resumen estimado</span><strong>{money(draftTotal)}</strong><small>IVA y total se validan en servidor al guardar.</small><p>{draft.lines.length} {draft.lines.length === 1 ? "partida" : "partidas"}</p></aside></div>
      <footer><Button type="button" disabled={saving} onClick={() => setDraft(null)}>Cancelar</Button><Button type="submit" variant="primary" loading={saving}>Guardar borrador</Button></footer>
    </form>}</Drawer>
    <Drawer open={Boolean(detail)} onOpenChange={(open) => !open && !saving && setDetail(null)} title={detail?.folio ?? "Cotización"} className="sales-quote-detail">{detail && <div className="sales-quote-detail__body">
      <header><div><span className="sales-quote-detail__badges"><QuoteBadge status={detail.status} />{supplyPending && <Badge tone="warning">Surtido pendiente</Badge>}</span><strong>{detail.customer.display_name}</strong><small>{detail.customer.code} · {detail.location.name}{detail.valid_until ? " · Vigente hasta " + new Date(detail.valid_until + "T12:00:00").toLocaleDateString("es-MX") : ""}</small></div><b>{money(Number(detail.total_amount), detail.currency_code)}</b></header>
      <ol className="sales-quote-progress" aria-label="Progreso de la cotización">
        {[{ value: "draft", label: "Preparada" }, { value: "approved", label: "Aprobada" }, { value: "sent", label: "Enviada" }, { value: "accepted", label: "Aceptada" }].map((step, index) => {
          const current = ["draft", "approved", "sent", "accepted"].indexOf(detail.status); const complete = current >= index;
          return <li key={step.value} className={complete ? "is-complete" : ""}><span>{complete ? <Check size={13} aria-hidden="true" /> : index + 1}</span><strong>{step.label}</strong></li>;
        })}
      </ol>
      {supplyPending && <section className="sales-quote-availability" aria-label="Disponibilidad de la cotización">
        <AlertTriangle size={20} aria-hidden="true" />
        <div><strong>Surtido pendiente</strong><p>Puedes aprobar y enviar la cotización. La existencia no se aparta y el pedido quedará bloqueado hasta completar el surtido.</p><ul>{shortageLines.map((line) => <li key={line.product_id}><span>{line.product_name}</span><b>Solicitado {Number(line.quantity).toLocaleString("es-MX")} · Disponible {Number(line.available_quantity ?? 0).toLocaleString("es-MX")} · Faltan {Number(line.shortage_quantity ?? 0).toLocaleString("es-MX")}</b></li>)}</ul></div>
      </section>}
      {detail.approved_at && <p className="sales-quote-approval-record"><FileCheck2 size={16} aria-hidden="true" /><span><strong>Documento aprobado</strong>{detail.approved_by?.name ?? "Usuario autorizado"} · {dateTime(detail.approved_at)}</span></p>}
      <section className="sales-quote-detail__totals"><span>Subtotal <b>{money(Number(detail.subtotal_amount), detail.currency_code)}</b></span><span>IVA <b>{money(Number(detail.tax_amount), detail.currency_code)}</b></span><span>Total <b>{money(Number(detail.total_amount), detail.currency_code)}</b></span></section>
      <Table><thead><tr><th>Producto</th><th className="number-cell">Cantidad</th><th>Disponibilidad</th><th className="number-cell">Precio total</th><th className="number-cell">Importe</th></tr></thead><tbody>{detail.lines.map((line) => <tr key={line.product_id}><td><strong>{line.product_name}</strong><small>{line.product_code ?? "Sin código"}</small></td><td className="number-cell">{Number(line.quantity).toLocaleString("es-MX")}</td><td><Badge tone={line.availability_status === "available" ? "success" : line.availability_status === "not_applicable" || !line.availability_status ? "neutral" : "warning"}>{availabilityLabel(line)}</Badge>{line.inventory_tracked && <small>{Number(line.available_quantity ?? 0).toLocaleString("es-MX")} disponibles ahora</small>}</td><td className="number-cell">{money(Number(line.unit_total_amount), detail.currency_code)}</td><td className="number-cell">{money(Number(line.line_total_amount), detail.currency_code)}</td></tr>)}</tbody></Table>
      <section className="sales-quote-history"><h3>Seguimiento</h3>{detail.follow_ups.length ? detail.follow_ups.map((item) => <article key={item.id}><span><strong>{item.event_type === "not_converted" ? reasonLabels[item.reason_code ?? ""] : item.event_type === "note" ? "Nota de seguimiento" : item.event_type === "created" ? "Borrador creado" : statusLabels[item.event_type as Status]}</strong><small>{item.actor_name ?? "Usuario"} · {dateTime(item.created_at)}</small></span>{item.note && <p>{item.note}</p>}</article>) : <p>Sin seguimientos todavía.</p>}</section>
      <footer className="sales-quote-detail__actions">
        <Button variant={detail.status === "draft" ? "primary" : "secondary"} loading={documentBusy === "preview"} onClick={() => void prepareDocument("preview")}><Eye size={15} aria-hidden="true" /> {detail.status === "draft" ? "Revisar documento" : "Vista previa"}</Button>
        <Button variant="secondary" loading={documentBusy === "print"} onClick={() => void prepareDocument("print")}><Printer size={15} aria-hidden="true" /> Imprimir</Button>
        <Button variant="secondary" loading={documentBusy === "download"} onClick={() => void prepareDocument("download")}><Download size={15} aria-hidden="true" /> Descargar PDF</Button>
        {canManage && <>
          {detail.status === "draft" && <Button variant="secondary" onClick={editDetail}>Editar borrador</Button>}
          {detail.status === "draft" && <Button variant="primary" loading={saving} onClick={() => setApproval({ note: "" })}><FileCheck2 size={15} aria-hidden="true" /> Aprobar cotización</Button>}
          {detail.status === "approved" && <Button variant="primary" loading={saving} onClick={() => void record("sent")}><Send size={15} aria-hidden="true" /> Marcar enviada</Button>}
          {detail.status === "sent" && <Button variant="primary" onClick={() => setFollowUp({ event: "accepted", reason: "", note: "" })}><Check size={15} aria-hidden="true" /> Marcar aceptada</Button>}
          {detail.status === "accepted" && (detail.order ? <Button variant="primary" onClick={() => router.push(`/satrapy/ventas/pedidos?order=${detail.order?.id}`)}><PackageCheck size={15} aria-hidden="true" /> Ver pedido {detail.order.folio}</Button> : <Button variant="primary" loading={saving} onClick={() => void createOrder()}><PackageCheck size={15} aria-hidden="true" /> Crear pedido</Button>)}
          {["draft", "approved", "sent"].includes(detail.status) && <Button variant="danger" onClick={() => setFollowUp({ event: "not_converted", reason: "", note: "" })}><XCircle size={15} aria-hidden="true" /> No se concretó</Button>}
          {["draft", "approved", "sent"].includes(detail.status) && <Button variant="ghost" onClick={() => setFollowUp({ event: "note", reason: "", note: "" })}><MessageSquare size={15} aria-hidden="true" /> Añadir nota</Button>}
        </>}
      </footer>
    </div>}</Drawer>
    <Modal open={quickCustomerOpen && Boolean(draft)} onOpenChange={(open) => !open && setQuickCustomerOpen(false)} eyebrow="Cliente de contado" title="Alta rápida de cliente" description="Para cotizaciones individuales. El cliente queda sin crédito y podrás completar sus datos después." footer={<><Button disabled={saving} onClick={() => setQuickCustomerOpen(false)}>Cancelar</Button><Button type="submit" form="quote-quick-customer" variant="primary" loading={saving}>Crear y seleccionar</Button></>}><form id="quote-quick-customer" className="sales-quote-follow-up-form" onSubmit={createQuickCustomer}><Field label="Nombre"><Input required autoFocus value={quickCustomer.name} onChange={(event) => setQuickCustomer({ ...quickCustomer, name: event.target.value })} placeholder="Nombre o razón social" /></Field><Field label="RFC (opcional)"><Input value={quickCustomer.taxId} onChange={(event) => setQuickCustomer({ ...quickCustomer, taxId: event.target.value.toUpperCase() })} placeholder="XAXX010101000" /></Field><Field label="Teléfono (opcional)"><Input value={quickCustomer.phone} onChange={(event) => setQuickCustomer({ ...quickCustomer, phone: event.target.value })} placeholder="222 000 0000" /></Field></form></Modal>
    <Modal open={Boolean(approval)} onOpenChange={(open) => !open && !saving && setApproval(null)} eyebrow="Documento final" title="Aprobar cotización" description="Confirma que cliente, productos, cantidades, vigencia y condiciones están correctos. Después de aprobar ya no podrá editarse." closeDisabled={saving} footer={<><Button disabled={saving} onClick={() => setApproval(null)}>Volver</Button><Button variant="primary" loading={saving} onClick={() => void approve()}><FileCheck2 size={15} aria-hidden="true" /> Aprobar documento</Button></>}>
      {approval && detail && <div className="sales-quote-approval-form">
        {supplyPending && <div className="sales-quote-approval-warning"><AlertTriangle size={18} aria-hidden="true" /><span><strong>Esta cotización tiene surtido pendiente</strong><small>Puede aprobarse, pero el pedido no podrá cobrar ni entregar hasta reservar el inventario.</small></span></div>}
        <div className="sales-quote-approval-summary"><span><small>Folio</small><strong>{detail.folio}</strong></span><span><small>Cliente</small><strong>{detail.customer.display_name}</strong></span><span><small>Total</small><strong>{money(detail.total_amount, detail.currency_code)}</strong></span></div>
        <Field label="Nota de aprobación" hint="Opcional. Quedará visible en el historial interno."><textarea autoFocus rows={3} maxLength={500} value={approval.note} onChange={(event) => setApproval({ note: event.target.value })} placeholder="Ej. Precios y vigencia confirmados con dirección comercial" /></Field>
      </div>}
    </Modal>
    <Modal open={Boolean(followUp)} onOpenChange={(open) => !open && !saving && setFollowUp(null)} eyebrow="Seguimiento comercial" title={followUp?.event === "not_converted" ? "¿Por qué no se concretó?" : followUp?.event === "accepted" ? "Registrar aceptación" : "Nota de seguimiento"} description={followUp?.event === "not_converted" ? "Elige el motivo y agrega detalle cuando ayude a entender el cierre." : "Se registrará fecha, usuario y nota en el historial."} footer={<><Button disabled={saving} onClick={() => setFollowUp(null)}>Volver</Button><Button variant={followUp?.event === "not_converted" ? "danger" : "primary"} loading={saving} disabled={!followUp || (followUp.event === "not_converted" && (!followUp.reason || (followUp.reason === "other" && !followUp.note.trim())))} onClick={() => followUp && void record(followUp.event, followUp.reason || null, followUp.note || null)}>Guardar seguimiento</Button></>}>{followUp && <div className="sales-quote-follow-up-form">{followUp.event === "not_converted" && <Field label="Motivo"><CompactSelect ariaLabel="Motivo de no concreción" value={followUp.reason} onValueChange={(reason) => setFollowUp({ ...followUp, reason })} options={[{ value: "", label: "Selecciona un motivo" }, ...Object.entries(reasonLabels).map(([value, label]) => ({ value, label }))]} /></Field>}<Field label={followUp.event === "not_converted" ? "Detalle" : "Nota"}><textarea rows={4} value={followUp.note} onChange={(event) => setFollowUp({ ...followUp, note: event.target.value })} placeholder={followUp.event === "not_converted" ? "Opcional, salvo que elijas Otro motivo" : "Ej. Cliente solicitó revisar la propuesta el viernes"} /></Field></div>}</Modal>
    <Modal open={Boolean(documentData)} onOpenChange={(open) => !open && setDocumentData(null)} eyebrow="Documento comercial" title={"Vista previa · " + (documentData?.quote.folio ?? "")} description="Estás viendo el PDF A4 real que se imprimirá y descargará." className="quote-document-dialog" footer={<><Button onClick={() => setDocumentData(null)}>Cerrar</Button>{documentData?.quote.status === "draft" && canManage && <Button variant="secondary" onClick={() => { setDocumentData(null); editDetail(); }}>Editar cotización</Button>}<Button variant="secondary" loading={documentBusy === "print"} onClick={() => void prepareDocument("print")}><Printer size={15} aria-hidden="true" /> Imprimir</Button><Button variant="secondary" loading={documentBusy === "download"} onClick={() => void prepareDocument("download")}><Download size={15} aria-hidden="true" /> Descargar PDF</Button>{documentData?.quote.status === "draft" && canManage && <Button variant="primary" onClick={() => { setDocumentData(null); setApproval({ note: "" }); }}><FileCheck2 size={15} aria-hidden="true" /> Aprobar cotización</Button>}</>}>{documentData && <QuotePreview key={`${documentData.quote.folio}-${documentData.quote.status}-${documentData.quote.approved_at ?? "pending"}`} documentData={documentData} />}</Modal>
  </div>;
}
