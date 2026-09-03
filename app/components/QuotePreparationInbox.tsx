"use client";

import { AlertTriangle, CheckCircle2, MessageSquareText, Plus, Search, Sparkles, Trash2, UserPlus } from "lucide-react";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { DataRefreshStatus, DataState, InteractiveTableRow, Table } from "@/app/components/ui/data";
import { Badge, Drawer, Modal, useToast } from "@/app/components/ui/primitives";
import { SalesButton as Button, SalesDataPagination as DataPagination, SalesField as Field, SalesInput as Input, SalesSelect as Select } from "@/app/components/reui/sales-controls";
import { getSupabaseClient } from "@/app/lib/supabase";

type Location = { id: string; name: string; code: string };
type Customer = { id: string; code: string; display_name: string };
type IntakeStatus = "processing" | "review_required" | "ready" | "dismissed" | "failed" | "converted";
type IntakeRow = { id: string; status: IntakeStatus; original_message: string; intent: string | null; intent_confidence: number | null; line_count: number; estimated_total: number; currency_code: string | null; latency_ms: number | null; created_at: string; location_name: string; customer_name: string | null };
type Product = { product_id: string; code: string | null; name: string; unit: string | null; price_amount: number; currency_code: string };
type PreparedLine = { raw_text: string; quantity: number; requested_unit: string | null; product_id: string | null; product_code?: string | null; product_name?: string | null; unit_name?: string | null; unit_total_amount?: number | null; currency_code?: string | null; inventory_tracked?: boolean; quantity_on_hand?: number; match_confidence: number; alternatives: Array<{ product_id: string; name: string; code: string | null; confidence: number }> };
type IntakeDetail = { id: string; status: IntakeStatus; source: string; source_sender?: string | null; original_message: string; intent: string | null; intent_confidence: number | null; customer_hint: string | null; prepared_lines: PreparedLine[]; latency_ms: number | null; error_message: string | null; created_at: string; location: Location; customer: Customer | null };
type ReviewLine = Omit<PreparedLine, "quantity"> & { quantity: number | "" };
type ReviewDraft = { locationId: string; customer: Customer | null; validUntil: string; lines: ReviewLine[] };

const PAGE_SIZE = 25;
const statusLabels: Record<IntakeStatus, string> = { processing: "Analizando", review_required: "Requiere revisión", ready: "Lista para preparar", dismissed: "No es cotización", failed: "No procesada", converted: "Cotización creada" };
const intentLabels: Record<string, string> = { quotation_request: "Solicitud de cotización", order: "Pedido", product_question: "Consulta de producto", general_question: "Consulta general", support: "Soporte", other: "Otro" };
const money = (amount: number, currency = "MXN") => new Intl.NumberFormat("es-MX", { style: "currency", currency }).format(Number(amount ?? 0));
const dateTime = (value: string) => new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));
const quoteExpiry = () => { const value = new Date(); value.setDate(value.getDate() + 15); return value.toISOString().slice(0, 10); };

function StatusBadge({ status }: { status: IntakeStatus }) {
  return <Badge tone={status === "ready" || status === "converted" ? "success" : status === "review_required" ? "warning" : status === "failed" ? "danger" : status === "processing" ? "info" : "neutral"}>{statusLabels[status]}</Badge>;
}

export function QuotePreparationInbox({ companyId, canManage, canCreateCustomer, onQuoteCreated }: { companyId: string; canManage: boolean; canCreateCustomer: boolean; onQuoteCreated?: (quoteId: string) => void | Promise<void> }) {
  const { toast } = useToast();
  const request = useRef(0);
  const productRequest = useRef(0);
  const [rows, setRows] = useState<IntakeRow[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [locations, setLocations] = useState<Location[]>([]);
  const [detail, setDetail] = useState<IntakeDetail | null>(null);
  const [captureOpen, setCaptureOpen] = useState(false);
  const [processing, setProcessing] = useState(false);
  const [locationId, setLocationId] = useState("");
  const [customer, setCustomer] = useState<Customer | null>(null);
  const [customerQuery, setCustomerQuery] = useState("");
  const [customers, setCustomers] = useState<Customer[]>([]);
  const [customerOpen, setCustomerOpen] = useState(false);
  const [message, setMessage] = useState("");
  const [review, setReview] = useState<ReviewDraft | null>(null);
  const [reviewSaving, setReviewSaving] = useState(false);
  const [reviewCustomerQuery, setReviewCustomerQuery] = useState("");
  const [reviewCustomers, setReviewCustomers] = useState<Customer[]>([]);
  const [reviewCustomerOpen, setReviewCustomerOpen] = useState(false);
  const [quickCustomer, setQuickCustomer] = useState<{ name: string; taxId: string; phone: string } | null>(null);
  const [productPicker, setProductPicker] = useState<{ lineIndex: number; query: string } | null>(null);
  const [reviewProducts, setReviewProducts] = useState<Product[]>([]);
  const [productSearching, setProductSearching] = useState(false);

  const load = useCallback(async () => {
    const current = ++request.current;
    setLoading(true);
    const { data, error: loadError } = await getSupabaseClient().rpc("list_sales_quote_intakes", { p_company_id: companyId, p_status: null, p_page: page, p_page_size: PAGE_SIZE });
    if (current !== request.current) return;
    const result = data as { items?: IntakeRow[]; total?: number } | null;
    setRows(result?.items ?? []);
    setTotal(Number(result?.total ?? 0));
    setError(loadError?.message ?? null);
    setLoading(false);
  }, [companyId, page]);

  useEffect(() => { const timer = window.setTimeout(() => void load(), 0); return () => window.clearTimeout(timer); }, [load]);
  useEffect(() => { void getSupabaseClient().rpc("get_sales_quote_context", { p_company_id: companyId }).then(({ data }) => { const next = ((data as { locations?: Location[] } | null)?.locations ?? []); setLocations(next); setLocationId((current) => current || next[0]?.id || ""); }); }, [companyId]);
  useEffect(() => {
    if (!captureOpen || !customerOpen) return;
    const timer = window.setTimeout(async () => { const { data } = await getSupabaseClient().rpc("search_sales_quote_customers", { p_company_id: companyId, p_query: customerQuery || null, p_limit: 20 }); setCustomers(((data as { items?: Customer[] } | null)?.items ?? [])); }, 160);
    return () => window.clearTimeout(timer);
  }, [captureOpen, companyId, customerOpen, customerQuery]);
  useEffect(() => {
    if (!review || !reviewCustomerOpen) return;
    const timer = window.setTimeout(async () => { const { data } = await getSupabaseClient().rpc("search_sales_quote_customers", { p_company_id: companyId, p_query: reviewCustomerQuery || null, p_limit: 20 }); setReviewCustomers(((data as { items?: Customer[] } | null)?.items ?? [])); }, 160);
    return () => window.clearTimeout(timer);
  }, [companyId, review, reviewCustomerOpen, reviewCustomerQuery]);
  useEffect(() => {
    const query = productPicker?.query.trim() ?? "";
    if (!productPicker || !review?.customer || !review.locationId || query.length < 2) return;
    const current = ++productRequest.current;
    const timer = window.setTimeout(async () => {
      setProductSearching(true);
      const { data } = await getSupabaseClient().rpc("search_sales_quote_products", { p_company_id: companyId, p_location_id: review.locationId, p_customer_id: review.customer?.id, p_query: query, p_limit: 30 });
      if (current !== productRequest.current) return;
      setReviewProducts(((data as { items?: Product[] } | null)?.items ?? []));
      setProductSearching(false);
    }, 160);
    return () => window.clearTimeout(timer);
  }, [companyId, productPicker, review]);

  function beginCapture() {
    setMessage(""); setCustomer(null); setCustomerQuery(""); setCustomers([]); setLocationId(locations[0]?.id ?? ""); setCaptureOpen(true);
  }

  async function openDetail(id: string) {
    const { data, error: detailError } = await getSupabaseClient().rpc("get_sales_quote_intake", { p_company_id: companyId, p_request_id: id });
    if (detailError) toast({ title: "No se abrió el mensaje", description: detailError.message, tone: "error" });
    else { setDetail(data as IntakeDetail); setReview(null); setProductPicker(null); }
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!locationId || message.trim().length < 3) { toast({ title: "Revisa el mensaje", description: "Selecciona la sucursal y captura lo que escribió el cliente.", tone: "error" }); return; }
    setProcessing(true);
    const { data: session } = await getSupabaseClient().auth.getSession();
    const response = await fetch("/api/sales/quote-intake", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${session.session?.access_token ?? ""}` }, body: JSON.stringify({ company_id: companyId, location_id: locationId, customer_id: customer?.id ?? null, message: message.trim() }) });
    const result = await response.json() as IntakeDetail & { error?: string };
    setProcessing(false);
    if (!response.ok) { toast({ title: "No se pudo preparar", description: result.error ?? "Revisa el mensaje e intenta nuevamente.", tone: "error" }); await load(); return; }
    setCaptureOpen(false); setDetail(result); await load();
    toast({ title: result.status === "ready" ? "Lista para preparar" : "Revisión necesaria", description: result.status === "ready" ? "Satrapy encontró productos, precios y existencias." : "Revisa la intención o las coincidencias encontradas.", tone: result.status === "ready" ? "success" : "info" });
  }

  function beginReview() {
    if (!detail) return;
    setReview({ locationId: detail.location.id, customer: detail.customer, validUntil: quoteExpiry(), lines: detail.prepared_lines.map((line) => ({ ...line, quantity: Number(line.quantity) })) });
    setReviewCustomerQuery(detail.customer?.display_name ?? "");
    setReviewCustomers([]);
    setReviewCustomerOpen(false);
  }

  function setReviewQuantity(index: number, value: string) {
    if (!review) return;
    const quantity = value === "" ? "" : Number(value);
    setReview({ ...review, lines: review.lines.map((line, candidate) => candidate === index ? { ...line, quantity } : line) });
  }

  function chooseReviewCustomer(next: Customer) {
    if (!review) return;
    setReview({ ...review, customer: next, lines: review.lines.map((line) => ({ ...line, unit_total_amount: null, currency_code: null })) });
    setReviewCustomerQuery(next.display_name);
    setReviewCustomerOpen(false);
  }

  function beginQuickCustomer() {
    if (!detail || !review || !canCreateCustomer) return;
    setQuickCustomer({ name: detail.customer_hint ?? "", taxId: "", phone: detail.source_sender ?? "+52 " });
  }

  async function createQuickCustomer(event: FormEvent) {
    event.preventDefault();
    if (!review || !quickCustomer?.name.trim()) return;
    setReviewSaving(true);
    const { data, error: createError } = await getSupabaseClient().rpc("create_sales_quote_customer", { p_company_id: companyId, p_location_id: review.locationId, p_display_name: quickCustomer.name.trim(), p_tax_id: quickCustomer.taxId.trim() || null, p_phone: quickCustomer.phone.trim() || null });
    setReviewSaving(false);
    if (createError || !data) { toast({ title: "No se pudo crear el cliente", description: createError?.message ?? "Verifica nombre, RFC y teléfono.", tone: "error" }); return; }
    chooseReviewCustomer(data as Customer);
    setQuickCustomer(null);
    toast({ title: "Cliente creado y seleccionado", description: "Ya puedes buscar productos con su lista de precios.", tone: "success" });
  }

  function openProductPicker(lineIndex: number) {
    if (!review?.customer) return;
    setReviewProducts([]);
    setProductPicker({ lineIndex, query: review.lines[lineIndex]?.raw_text ?? "" });
  }

  function chooseReviewProduct(product: Product) {
    if (!review || !productPicker) return;
    setReview({ ...review, lines: review.lines.map((line, index) => index === productPicker.lineIndex ? { ...line, product_id: product.product_id, product_code: product.code, product_name: product.name, unit_name: product.unit, unit_total_amount: Number(product.price_amount), currency_code: product.currency_code, match_confidence: 1 } : line) });
    setProductPicker(null);
    setReviewProducts([]);
  }

  function reviewPayload(source: ReviewDraft) {
    return source.lines.map((line) => ({ raw_text: line.raw_text, requested_unit: line.requested_unit, product_id: line.product_id, quantity: Number(line.quantity) }));
  }

  function validReview(source: ReviewDraft, requireReady: boolean) {
    if (!source.locationId || !source.lines.length || source.lines.some((line) => !(Number(line.quantity) > 0))) return false;
    return !requireReady || Boolean(source.customer && source.lines.every((line) => line.product_id));
  }

  async function saveReview() {
    if (!detail || !review || !validReview(review, false)) { toast({ title: "Revisa las partidas", description: "Conserva al menos una partida y captura cantidades mayores que cero.", tone: "error" }); return; }
    setReviewSaving(true);
    const { data, error: reviewError } = await getSupabaseClient().rpc("review_sales_quote_intake", { p_company_id: companyId, p_request_id: detail.id, p_location_id: review.locationId, p_customer_id: review.customer?.id ?? null, p_lines: reviewPayload(review) });
    setReviewSaving(false);
    if (reviewError || !data) { toast({ title: "No se guardaron los ajustes", description: reviewError?.message ?? "Intenta nuevamente.", tone: "error" }); return; }
    const result = data as IntakeDetail;
    setDetail(result); setReview(null); setProductPicker(null); await load();
    toast({ title: result.status === "ready" ? "Solicitud lista" : "Ajustes guardados", description: result.status === "ready" ? "Cliente, productos y cantidades quedaron confirmados." : "Aún hay datos por resolver.", tone: result.status === "ready" ? "success" : "info" });
  }

  async function createQuote() {
    if (!detail) return;
    const source: ReviewDraft = review ?? { locationId: detail.location.id, customer: detail.customer, validUntil: quoteExpiry(), lines: detail.prepared_lines.map((line) => ({ ...line, quantity: Number(line.quantity) })) };
    if (!validReview(source, true)) { toast({ title: "La solicitud todavía no está lista", description: "Confirma el cliente, cada producto y todas las cantidades.", tone: "error" }); return; }
    setReviewSaving(true);
    const { data, error: convertError } = await getSupabaseClient().rpc("convert_sales_quote_intake", { p_company_id: companyId, p_request_id: detail.id, p_location_id: source.locationId, p_customer_id: source.customer?.id, p_valid_until: source.validUntil || null, p_lines: reviewPayload(source) });
    setReviewSaving(false);
    if (convertError || !data) { toast({ title: "No se creó la cotización", description: convertError?.message ?? "Intenta nuevamente.", tone: "error" }); return; }
    const quote = (data as { quote: { id: string; folio: string } }).quote;
    setDetail(null); setReview(null); setProductPicker(null); await load();
    toast({ title: `Cotización ${quote.folio} creada`, description: "Precios, impuestos y totales fueron confirmados por el servidor.", tone: "success" });
    await onQuoteCreated?.(quote.id);
  }

  const reviewReady = review ? validReview(review, true) : false;
  const unresolvedProducts = review?.lines.filter((line) => !line.product_id).length ?? 0;
  const invalidQuantities = review?.lines.filter((line) => !(Number(line.quantity) > 0)).length ?? 0;
  const availabilityLines = review?.lines ?? detail?.prepared_lines ?? [];
  const shortageLines = availabilityLines.filter((line) => line.inventory_tracked && Number(line.quantity) > Number(line.quantity_on_hand ?? 0));

  return <section className="quote-preparation" aria-labelledby="quote-preparation-title">
    <header className="quote-preparation__header"><div><span className="eyebrow">Entrada asistida</span><h2 id="quote-preparation-title">Por preparar</h2><p>Interpreta mensajes y concilia productos, precios y existencias antes de crear la cotización.</p></div>{canManage && <Button variant="primary" onClick={beginCapture}><Plus size={16} aria-hidden="true" /> Preparar mensaje</Button>}</header>
    <DataRefreshStatus loading={loading} hasData={rows.length} />
    <DataState loading={loading && !rows.length} error={error} hasData={rows.length} emptyTitle="No hay mensajes por preparar" empty="Prepara un mensaje real para comprobar cómo Satrapy identifica productos y cantidades." errorAction={<Button size="sm" onClick={() => void load()}>Reintentar</Button>}>
      <Table><thead><tr><th>Mensaje</th><th>Cliente</th><th>Sucursal</th><th>Estado</th><th>Tiempo</th><th className="number-cell">Estimado</th></tr></thead><tbody>{rows.map((row) => <InteractiveTableRow key={row.id} label="Abrir mensaje por preparar" onActivate={() => void openDetail(row.id)}><td><strong className="quote-preparation__message">{row.original_message}</strong><small>{dateTime(row.created_at)} · {row.line_count} {row.line_count === 1 ? "producto" : "productos"}</small></td><td>{row.customer_name ?? "Por identificar"}</td><td>{row.location_name}</td><td><StatusBadge status={row.status} /></td><td>{row.latency_ms == null ? "—" : `${(row.latency_ms / 1000).toFixed(1)} s`}</td><td className="number-cell">{row.currency_code ? money(row.estimated_total, row.currency_code) : "Pendiente"}</td></InteractiveTableRow>)}</tbody></Table>
      <DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={setPage} />
    </DataState>

    <Modal open={captureOpen} onOpenChange={(open) => !processing && setCaptureOpen(open)} eyebrow="Prueba manual" title="Preparar un mensaje" description="Pega exactamente lo que escribió el cliente. Satrapy no enviará ninguna respuesta." closeDisabled={processing} footer={<><Button disabled={processing} onClick={() => setCaptureOpen(false)}>Cancelar</Button><Button type="submit" form="quote-intake-form" variant="primary" loading={processing}>Analizar mensaje</Button></>}>
      <form id="quote-intake-form" className="quote-intake-form" onSubmit={submit}>
        <Field label="Sucursal"><Select ariaLabel="Sucursal de origen" value={locationId} onValueChange={setLocationId} options={locations.map((location) => ({ value: location.id, label: location.name }))} /></Field>
        <Field label="Cliente existente (opcional)" hint="Seleccionarlo permite usar su lista de precios; podrás identificarlo después si aún no lo conoces."><div className="sales-quote-picker"><Input value={customerQuery} onFocus={() => setCustomerOpen(true)} onBlur={() => window.setTimeout(() => setCustomerOpen(false), 120)} onChange={(event) => { setCustomerQuery(event.target.value); setCustomer(null); setCustomerOpen(true); }} placeholder="Ej. Agroinsumos del Norte" role="combobox" aria-label="Buscar cliente existente" aria-expanded={customerOpen} aria-controls="quote-intake-customer-options" autoComplete="off" />{customerOpen && <div id="quote-intake-customer-options" className="sales-quote-picker__options" role="listbox">{customers.length ? customers.map((item) => <button type="button" role="option" aria-selected={customer?.id === item.id} key={item.id} onMouseDown={(event) => event.preventDefault()} onClick={() => { setCustomer(item); setCustomerQuery(item.display_name); setCustomerOpen(false); }}><strong>{item.display_name}</strong><small>{item.code}</small></button>) : <p>{customerQuery.trim() ? "No encontramos clientes." : "Escribe para buscar."}</p>}</div>}</div></Field>
        <label className="quote-intake-form__message"><span>Mensaje del cliente</span><textarea required autoFocus rows={6} maxLength={4000} value={message} onChange={(event) => setMessage(event.target.value)} placeholder="Ej. Cotízame 10 sacos de Calcinit y 20 de Yara Complex" /><small>{message.length.toLocaleString("es-MX")} de 4,000 caracteres</small></label>
        <div className="quote-intake-form__privacy"><Sparkles size={16} aria-hidden="true" /><span>La IA interpreta el texto. Los SKU, precios, impuestos y existencias siempre los confirma Satrapy.</span></div>
      </form>
    </Modal>

    <Drawer open={Boolean(detail)} onOpenChange={(open) => { if (!open && !reviewSaving) { setDetail(null); setReview(null); setProductPicker(null); } }} title={review ? "Revisar y ajustar" : "Mensaje por preparar"} className="quote-intake-detail">
      {detail && <div className="quote-intake-detail__body">
        <header><div><StatusBadge status={detail.status} /><strong>{review?.customer?.display_name ?? detail.customer?.display_name ?? detail.customer_hint ?? "Cliente por identificar"}</strong><small>{locations.find((location) => location.id === review?.locationId)?.name ?? detail.location.name} · {dateTime(detail.created_at)}</small></div>{detail.latency_ms != null && <span>{(detail.latency_ms / 1000).toFixed(1)} s</span>}</header>
        <blockquote><MessageSquareText size={17} aria-hidden="true" /><p>{detail.original_message}</p></blockquote>
        <section className="quote-intake-detail__intent"><span>Intención</span><strong>{detail.intent ? intentLabels[detail.intent] ?? detail.intent : "Pendiente"}</strong><small>{detail.intent_confidence == null ? "Sin confianza calculada" : `${Math.round(detail.intent_confidence * 100)}% de confianza`}</small></section>
        {detail.error_message && <div className="quote-intake-detail__error" role="alert"><AlertTriangle size={17} aria-hidden="true" /><span><strong>No se pudo completar el análisis</strong>{detail.error_message}</span></div>}

        {review ? <>
          <section className={`quote-intake-review__readiness${reviewReady ? " is-ready" : " is-pending"}`} aria-label="Estado de la revisión">
            <div className="quote-intake-review__readiness-heading"><span className="quote-intake-review__readiness-icon">{reviewReady ? <CheckCircle2 size={18} aria-hidden="true" /> : <AlertTriangle size={18} aria-hidden="true" />}</span><div><small>Estado de preparación</small><strong>{reviewReady ? "Lista para crear cotización" : "Requiere revisión"}</strong><p>{reviewReady ? "Cliente, productos y cantidades están resueltos." : "Completa los puntos pendientes para continuar."}</p></div></div>
            <div className="quote-intake-review__checks">
              <span className={`quote-intake-review__check ${review.customer ? "is-complete" : "is-pending"}`}>{review.customer ? <CheckCircle2 size={16} aria-hidden="true" /> : <AlertTriangle size={16} aria-hidden="true" />}<span><small>Cliente</small><strong>{review.customer?.display_name ?? "Por identificar"}</strong></span></span>
              <span className={`quote-intake-review__check ${!unresolvedProducts && review.lines.length ? "is-complete" : "is-pending"}`}>{!unresolvedProducts && review.lines.length ? <CheckCircle2 size={16} aria-hidden="true" /> : <AlertTriangle size={16} aria-hidden="true" />}<span><small>Productos</small><strong>{unresolvedProducts ? `${unresolvedProducts} ${unresolvedProducts === 1 ? "pendiente" : "pendientes"}` : `${review.lines.length} ${review.lines.length === 1 ? "confirmado" : "confirmados"}`}</strong></span></span>
              <span className={`quote-intake-review__check ${!invalidQuantities && review.lines.length ? "is-complete" : "is-pending"}`}>{!invalidQuantities && review.lines.length ? <CheckCircle2 size={16} aria-hidden="true" /> : <AlertTriangle size={16} aria-hidden="true" />}<span><small>Cantidades</small><strong>{invalidQuantities ? `${invalidQuantities} ${invalidQuantities === 1 ? "pendiente" : "pendientes"}` : "Válidas"}</strong></span></span>
            </div>
          </section>
          <section className="quote-intake-review__context" aria-label="Contexto de la cotización">
            <Field label="Sucursal"><Select ariaLabel="Sucursal para la cotización" value={review.locationId} onValueChange={(nextLocation) => setReview({ ...review, locationId: nextLocation })} options={locations.map((location) => ({ value: location.id, label: location.name }))} /></Field>
            <Field label="Cliente" hint={review.customer ? "Define la lista de precios." : "Selecciona un cliente existente o créalo sin salir de la revisión."}><div className="quote-intake-review__customer"><div className="sales-quote-picker"><Input value={reviewCustomerQuery} onFocus={() => setReviewCustomerOpen(true)} onBlur={() => window.setTimeout(() => setReviewCustomerOpen(false), 120)} onChange={(event) => { setReviewCustomerQuery(event.target.value); setReview({ ...review, customer: null }); setReviewCustomerOpen(true); }} placeholder="Buscar por nombre o clave" role="combobox" aria-label="Cliente de la cotización" aria-expanded={reviewCustomerOpen} aria-controls="quote-review-customer-options" autoComplete="off" />{reviewCustomerOpen && <div id="quote-review-customer-options" className="sales-quote-picker__options" role="listbox">{reviewCustomers.length ? reviewCustomers.map((item) => <button type="button" role="option" aria-selected={review.customer?.id === item.id} key={item.id} onMouseDown={(event) => event.preventDefault()} onClick={() => chooseReviewCustomer(item)}><strong>{item.display_name}</strong><small>{item.code}</small></button>) : <p>{reviewCustomerQuery.trim() ? "No encontramos clientes." : "Escribe para buscar."}</p>}</div>}</div>{!review.customer && <Button type="button" size="sm" variant="secondary" disabled={!canCreateCustomer} onClick={beginQuickCustomer}><UserPlus size={14} aria-hidden="true" /> Crear cliente rápido</Button>}</div></Field>
            <Field label="Vigencia"><Input type="date" value={review.validUntil} onChange={(event) => setReview({ ...review, validUntil: event.target.value })} /></Field>
          </section>
          <section className="quote-intake-review__lines" aria-labelledby="quote-intake-review-lines-title">
            <header><div><h3 id="quote-intake-review-lines-title">Partidas detectadas</h3><p>Confirma cada producto y ajusta su cantidad.</p></div><Button type="button" size="sm" variant="secondary" onClick={() => setReview({ ...review, lines: [...review.lines, { raw_text: "Partida agregada", quantity: 1, requested_unit: null, product_id: null, match_confidence: 0, alternatives: [] }] })}><Plus size={14} aria-hidden="true" /> Agregar partida</Button></header>
            {review.lines.map((line, index) => <article className={line.product_id ? "is-resolved" : "is-pending"} key={`${line.raw_text}-${index}`}>
              <span className="quote-intake-review__request"><small>Solicitado</small><strong>{line.raw_text}</strong><span>{line.requested_unit ?? "Unidad no indicada"}</span></span>
              <span className="quote-intake-review__product"><small>Producto</small>{line.product_id ? <><strong>{line.product_name}</strong><span>{line.product_code ?? "Sin código"} · {line.unit_name ?? "Unidad"}</span></> : <><strong>Sin coincidencia</strong><span>Selecciona un producto del catálogo.</span></>}<Button type="button" size="sm" variant="secondary" disabled={!review.customer} onClick={() => openProductPicker(index)}><Search size={14} aria-hidden="true" /> {line.product_id ? "Cambiar" : "Buscar producto"}</Button>{!review.customer && <em>Selecciona o crea un cliente para habilitar la búsqueda.</em>}</span>
              <label className="quote-intake-review__quantity"><small>Cantidad</small><Input aria-label={`Cantidad para ${line.raw_text}`} type="number" min="0.001" step="0.001" inputMode="decimal" value={line.quantity} onChange={(event) => setReviewQuantity(index, event.target.value)} /></label>
              <span className="quote-intake-review__commercial"><small>Precio estimado</small><strong>{line.unit_total_amount != null ? money(line.unit_total_amount, line.currency_code ?? "MXN") : "Pendiente"}</strong><span>{line.product_id ? "Se confirma al guardar" : "Falta producto"}</span></span>
              <Button type="button" size="icon" variant="ghost" aria-label={`Eliminar partida ${line.raw_text}`} onClick={() => setReview({ ...review, lines: review.lines.filter((_, candidate) => candidate !== index) })}><Trash2 size={15} aria-hidden="true" /></Button>
            </article>)}
            {!review.lines.length && <p className="quote-intake-detail__empty">Agrega al menos una partida para continuar.</p>}
          </section>
        </> : detail.prepared_lines.length ? <Table><thead><tr><th>Solicitado</th><th>Producto encontrado</th><th className="number-cell">Cantidad</th><th className="number-cell">Precio</th><th className="number-cell">Existencia</th><th>Confianza</th></tr></thead><tbody>{detail.prepared_lines.map((line, index) => <tr key={`${line.raw_text}-${index}`}><td><strong>{line.raw_text}</strong><small>{line.requested_unit ?? "Unidad no indicada"}</small></td><td>{line.product_name ? <><strong>{line.product_name}</strong><small>{line.product_code ?? "Sin código"}</small></> : <span className="quote-intake-unmatched">Sin coincidencia</span>}</td><td className="number-cell">{Number(line.quantity).toLocaleString("es-MX")}</td><td className="number-cell">{line.unit_total_amount != null ? money(line.unit_total_amount, line.currency_code ?? "MXN") : "—"}</td><td className="number-cell">{line.inventory_tracked ? Number(line.quantity_on_hand ?? 0).toLocaleString("es-MX") : "Sin control"}</td><td>{line.match_confidence >= .9 ? <span className="quote-intake-confidence is-high"><CheckCircle2 size={14} aria-hidden="true" /> Alta</span> : <span className="quote-intake-confidence is-review"><AlertTriangle size={14} aria-hidden="true" /> Revisar</span>}</td></tr>)}</tbody></Table> : !detail.error_message && <p className="quote-intake-detail__empty">No se detectaron productos para cotizar en este mensaje.</p>}

        {shortageLines.length > 0 && <section className="quote-intake-availability-warning" role="status" aria-label="Existencia insuficiente">
          <AlertTriangle size={19} aria-hidden="true" />
          <div><strong>Existencia insuficiente para surtir ahora</strong><p>Puedes crear la cotización; la mercancía no se apartará. El pedido se bloqueará si el faltante continúa.</p><ul>{shortageLines.map((line, index) => <li key={`${line.product_id ?? line.raw_text}-${index}`}><span>{line.product_name ?? line.raw_text}</span><b>Solicitado {Number(line.quantity).toLocaleString("es-MX")} · Existencia {Number(line.quantity_on_hand ?? 0).toLocaleString("es-MX")} · Faltan {(Number(line.quantity) - Number(line.quantity_on_hand ?? 0)).toLocaleString("es-MX")}</b></li>)}</ul></div>
        </section>}

        <footer><p>{review ? (reviewReady ? "Todo está resuelto. Puedes crear la cotización." : "Confirma cliente, productos y cantidades para continuar.") : "La existencia es informativa y no modifica el surtido ni reserva mercancía."}</p>{canManage && (detail.status === "ready" || detail.status === "review_required") && <div className="quote-intake-detail__actions">{review ? <><Button disabled={reviewSaving} onClick={() => setReview(null)}>Cancelar</Button><Button variant="secondary" loading={reviewSaving} onClick={() => void saveReview()}>Guardar ajustes</Button><Button variant="primary" loading={reviewSaving} disabled={!reviewReady} onClick={() => void createQuote()}>Crear cotización</Button></> : <><Button variant="secondary" onClick={beginReview}>Revisar y ajustar</Button>{detail.status === "ready" && <Button variant="primary" loading={reviewSaving} onClick={() => void createQuote()}>Crear cotización</Button>}</>}</div>}</footer>
      </div>}
    </Drawer>

    <Modal open={Boolean(productPicker && review)} onOpenChange={(open) => !open && setProductPicker(null)} eyebrow="Catálogo comercial" title="Seleccionar producto" description={productPicker && review ? `Resuelve “${review.lines[productPicker.lineIndex]?.raw_text ?? "partida"}” con un producto cotizable.` : undefined} footer={<Button onClick={() => setProductPicker(null)}>Cerrar</Button>}>
      {productPicker && <div className="quote-intake-product-picker"><label><span>Buscar producto o SKU</span><Input autoFocus value={productPicker.query} onChange={(event) => { const query = event.target.value; setProductPicker({ ...productPicker, query }); if (query.trim().length < 2) { setReviewProducts([]); setProductSearching(false); } }} placeholder="Escribe al menos 2 letras" aria-label="Buscar producto para resolver la partida" aria-controls="quote-intake-product-options" /></label><div id="quote-intake-product-options" className="quote-intake-product-picker__results" role="listbox" aria-busy={productSearching}>{productSearching ? <p role="status">Buscando productos…</p> : productPicker.query.trim().length < 2 ? <p>Escribe al menos 2 letras.</p> : reviewProducts.length ? reviewProducts.map((product) => <button type="button" role="option" aria-selected="false" key={product.product_id} onClick={() => chooseReviewProduct(product)}><span><strong>{product.name}</strong><small>{product.code ?? "Sin código"} · {product.unit ?? "Unidad"}</small></span><b>{money(product.price_amount, product.currency_code)}</b></button>) : <p>No encontramos productos cotizables con precio vigente.</p>}</div></div>}
    </Modal>
    <Modal open={Boolean(quickCustomer)} onOpenChange={(open) => !open && !reviewSaving && setQuickCustomer(null)} eyebrow="Alta desde revisión" title="Crear cliente rápido" description="Guarda los datos mínimos y selecciona al cliente en esta solicitud." closeDisabled={reviewSaving} footer={<><Button disabled={reviewSaving} onClick={() => setQuickCustomer(null)}>Cancelar</Button><Button type="submit" form="quote-intake-quick-customer-form" variant="primary" loading={reviewSaving}>Crear y seleccionar</Button></>}>
      {quickCustomer && <form id="quote-intake-quick-customer-form" className="quote-intake-quick-customer" onSubmit={createQuickCustomer}><Field label="Nombre o razón social"><Input required autoFocus value={quickCustomer.name} onChange={(event) => setQuickCustomer({ ...quickCustomer, name: event.target.value })} placeholder="Ej. Ferretería del Centro" /></Field><Field label="Teléfono" hint="Se conserva para reconocer futuros mensajes de WhatsApp."><Input inputMode="tel" value={quickCustomer.phone} onChange={(event) => setQuickCustomer({ ...quickCustomer, phone: event.target.value })} placeholder="+52 55 1234 5678" /></Field><Field label="RFC (opcional)"><Input autoCapitalize="characters" value={quickCustomer.taxId} onChange={(event) => setQuickCustomer({ ...quickCustomer, taxId: event.target.value })} placeholder="XAXX010101000" /></Field></form>}
    </Modal>
  </section>;
}
