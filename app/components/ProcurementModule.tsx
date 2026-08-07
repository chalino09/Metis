"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import {
  DataPagination,
  DataState,
  DataToolbar,
  InteractiveTableRow,
} from "@/app/components/ui/data";
import {
  Badge,
  Button,
  Drawer,
  Field,
  Input,
  Modal,
  Select,
  useToast,
} from "@/app/components/ui/primitives";
import { useSatrapy } from "@/app/components/SatrapyProvider";
import { getSupabaseClient } from "@/app/lib/supabase";

type Row = {
  id: string;
  folio: string;
  location_name: string;
  status: string;
  source: string;
  target_date: string | null;
  created_at: string;
  quote_count: number;
};

type QuoteLine = {
  id: string;
  requisition_line_id: string;
  available_quantity: number;
  unit_price: number;
  commercial_discount_percent: number;
  financing_terms: string | null;
  expected_date: string | null;
};

type Detail = Row & {
  lines: Array<{
    id: string;
    line_number: number;
    product_name: string;
    product_code: string | null;
    required_quantity: number;
    unit: string | null;
    available_quantity_snapshot: number;
  }>;
  quotes: Array<{
    id: string;
    supplier_id: string;
    supplier_name: string;
    currency_code: string;
    delivery_days: number | null;
    credit_days_snapshot: number | null;
    prompt_payment_discount_percent: number;
    prompt_payment_term_days: number | null;
    valid_until: string | null;
    notes: string | null;
    lines: QuoteLine[];
  }>;
  award: null | {
    status: string;
    recommendation_reason: string;
    decided_reason: string | null;
    purchase_order_ids: string[];
  };
};

type Supplier = {
  id: string;
  display_name: string;
  code: string;
  prompt_payment_terms: Array<{ term_days: number; effective_discount_percent: number }>;
};
type Product = {
  id: string;
  name: string;
  alpha_sku: string | null;
  internal_sku: string | null;
  unit: string | null;
};

type QuoteDraftLine = {
  requisitionLineId: string;
  available: string;
  price: string;
  commercial: string;
  financing: string;
  expectedDate: string;
};

const pageSize = 50;
const status: Record<string, string> = {
  draft: "Borrador",
  quoting: "Pendiente de cotizar",
  recommended: "Por aprobar",
  approved: "Compra autorizada",
  cancelled: "Cancelada",
};

function formatMoney(value: number, currency: string) {
  return new Intl.NumberFormat("es-MX", {
    style: "currency",
    currency,
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(value);
}

function formatDate(value: string | null) {
  return value ? new Date(`${value}T00:00:00`).toLocaleDateString("es-MX") : "—";
}

function requisitionStatusLabel(requisition: Pick<Row, "status" | "quote_count">) {
  if (requisition.status === "quoting") return Number(requisition.quote_count) > 0 ? "Cotizaciones recibidas" : "Pendiente de cotizar";
  return status[requisition.status] ?? requisition.status;
}

export function ProcurementView({
  companyId,
  permissions,
}: {
  companyId: string;
  permissions: string[];
}) {
  const router = useRouter();
  const searchParams = useSearchParams();
  const { accessibleLocations } = useSatrapy();
  const { toast } = useToast();
  const canCreate = permissions.includes("create_procurement_requisitions");
  const canQuote = permissions.includes("manage_procurement_quotes");
  const canRecommend = permissions.includes("recommend_procurement_awards");
  const canApprove = permissions.includes("approve_procurement_awards");

  const [rows, setRows] = useState<Row[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [detail, setDetail] = useState<Detail | null>(null);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [quoteOpen, setQuoteOpen] = useState(false);
  const [editingQuoteId, setEditingQuoteId] = useState<string | null>(null);
  const [quantityEditorOpen, setQuantityEditorOpen] = useState(false);
  const [quantityDraft, setQuantityDraft] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [reason, setReason] = useState("");
  const [decision, setDecision] = useState<"selection" | "approve" | null>(null);
  const [awardChoices, setAwardChoices] = useState<Record<string, string>>({});
  const [quote, setQuote] = useState({
    supplierId: "",
    currency: "MXN",
    validUntil: "",
    deliveryDays: "",
    promptPaymentDiscount: "0",
    promptPaymentDays: "",
    notes: "",
    lines: [] as QuoteDraftLine[],
  });
  const [manualOpen, setManualOpen] = useState(false);
  const [products, setProducts] = useState<Product[]>([]);
  const [manual, setManual] = useState({
    locationId: "",
    productId: "",
    quantity: "",
    targetDate: "",
    reason: "",
  });

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error: rpcError } = await getSupabaseClient().rpc(
      "search_procurement_requisitions",
      {
        p_company_id: companyId,
        p_query: query || null,
        p_status: filter === "all" ? null : filter,
        p_page: page,
        p_page_size: pageSize,
      },
    );
    const result = data as { items?: Row[]; pagination?: { total: number } } | null;
    setRows(result?.items ?? []);
    setTotal(result?.pagination?.total ?? 0);
    setError(rpcError?.message ?? null);
    setLoading(false);
  }, [companyId, filter, page, query]);

  useEffect(() => {
    void Promise.resolve().then(load);
  }, [load]);

  const open = useCallback(async (id: string) => {
    const { data, error: rpcError } = await getSupabaseClient().rpc(
      "get_procurement_requisition",
      { p_company_id: companyId, p_requisition_id: id },
    );
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    setDetail(data as Detail);
  }, [companyId]);

  useEffect(() => {
    const requisitionId = searchParams.get("solicitud");
    if (!requisitionId) return;
    const timer = window.setTimeout(() => void open(requisitionId), 0);
    return () => window.clearTimeout(timer);
  }, [open, searchParams]);

  async function openManual() {
    const { data } = await getSupabaseClient().rpc("search_purchase_order_products", {
      p_company_id: companyId,
      p_query: null,
      p_limit: 50,
    });
    setProducts(((data as { items?: Product[] } | null)?.items ?? []));
    setManual({ locationId: "", productId: "", quantity: "", targetDate: "", reason: "" });
    setManualOpen(true);
  }

  async function saveManual() {
    if (!manual.locationId || !manual.productId || !(Number(manual.quantity) > 0) || !manual.reason.trim()) {
      toast({
        title: "Revisa la solicitud",
        description: "La excepción requiere ubicación, producto, cantidad y motivo.",
        tone: "error",
      });
      return;
    }
    setSaving(true);
    const { error: rpcError } = await getSupabaseClient().rpc("save_procurement_requisition", {
      p_company_id: companyId,
      p_location_id: manual.locationId,
      p_source: "manual_exception",
      p_target_date: manual.targetDate || null,
      p_exception_reason: manual.reason.trim(),
      p_lines: [{ product_id: manual.productId, quantity: Number(manual.quantity) }],
    });
    setSaving(false);
    if (rpcError) {
      toast({ title: "No se creó la solicitud", description: rpcError.message, tone: "error" });
      return;
    }
    setManualOpen(false);
    await load();
    toast({
      title: "Solicitud de compra creada",
      description: "Quedó identificada y auditada como excepción manual.",
      tone: "success",
    });
  }

  async function openQuote(existingQuote?: Detail["quotes"][number]) {
    if (!detail) return;
    const { data } = await getSupabaseClient().rpc("search_suppliers", {
      p_company_id: companyId,
      p_query: null,
      p_page: 1,
      p_page_size: 100,
      p_is_active: true,
      p_origin: null,
    });
    const supplierRows = ((data as { items?: Supplier[] } | null)?.items ?? []);
    const supplierDefaultTerm = existingQuote
      ? supplierRows.find((supplier) => supplier.id === existingQuote.supplier_id)?.prompt_payment_terms?.[0]
      : undefined;
    const hasSavedPromptPayment = Boolean(existingQuote && (Number(existingQuote.prompt_payment_discount_percent) > 0 || existingQuote.prompt_payment_term_days != null));
    setSuppliers(supplierRows);
    setEditingQuoteId(existingQuote?.id ?? null);
    setQuote({
      supplierId: existingQuote?.supplier_id ?? "",
      currency: existingQuote?.currency_code ?? "MXN",
      validUntil: existingQuote?.valid_until ?? "",
      deliveryDays: existingQuote?.delivery_days == null ? "" : String(existingQuote.delivery_days),
      promptPaymentDiscount: hasSavedPromptPayment ? String(existingQuote?.prompt_payment_discount_percent ?? 0) : supplierDefaultTerm ? String(supplierDefaultTerm.effective_discount_percent) : "0",
      promptPaymentDays: hasSavedPromptPayment ? (existingQuote?.prompt_payment_term_days == null ? "" : String(existingQuote.prompt_payment_term_days)) : supplierDefaultTerm ? String(supplierDefaultTerm.term_days) : "",
      notes: existingQuote?.notes ?? "",
      lines: detail.lines.map((line) => ({
        requisitionLineId: line.id,
        available: String(existingQuote?.lines.find((quoteLine) => quoteLine.requisition_line_id === line.id)?.available_quantity ?? line.required_quantity),
        price: String(existingQuote?.lines.find((quoteLine) => quoteLine.requisition_line_id === line.id)?.unit_price ?? ""),
        commercial: String(existingQuote?.lines.find((quoteLine) => quoteLine.requisition_line_id === line.id)?.commercial_discount_percent ?? 0),
        financing: existingQuote?.lines.find((quoteLine) => quoteLine.requisition_line_id === line.id)?.financing_terms ?? "",
        expectedDate: existingQuote?.lines.find((quoteLine) => quoteLine.requisition_line_id === line.id)?.expected_date ?? "",
      })),
    });
    setQuoteOpen(true);
  }

  async function saveQuote() {
    if (
      !detail ||
      !quote.supplierId ||
      !quote.validUntil ||
      quote.lines.some(
        (line) =>
          !Number.isFinite(Number(line.available)) ||
          Number(line.available) <= 0 ||
          !Number.isFinite(Number(line.price)) ||
          Number(line.price) <= 0 ||
          !line.expectedDate ||
          !Number.isFinite(Number(quote.promptPaymentDiscount)) ||
          Number(quote.promptPaymentDiscount) < 0 ||
          Number(quote.promptPaymentDiscount) > 100 ||
          (Number(quote.promptPaymentDiscount) > 0 && (!Number.isInteger(Number(quote.promptPaymentDays)) || Number(quote.promptPaymentDays) < 0)),
      )
    ) {
      toast({
        title: "Revisa la cotización",
        description: "Captura vigencia, fecha estimada, disponibilidad y precio mayor a cero para cada partida.",
        tone: "error",
      });
      return;
    }
    setSaving(true);
    const { error: rpcError } = await getSupabaseClient().rpc("save_procurement_quote", {
      p_company_id: companyId,
      p_requisition_id: detail.id,
      p_supplier_id: quote.supplierId,
      p_currency_code: quote.currency,
      p_valid_until: quote.validUntil || null,
      p_delivery_days: quote.deliveryDays ? Number(quote.deliveryDays) : null,
      p_prompt_payment_discount_percent: Number(quote.promptPaymentDiscount) || 0,
      p_prompt_payment_term_days: quote.promptPaymentDays === "" ? null : Number(quote.promptPaymentDays),
      p_notes: quote.notes || null,
      p_lines: quote.lines.map((line) => ({
        requisition_line_id: line.requisitionLineId,
        available_quantity: Number(line.available),
        unit_price: Number(line.price),
        commercial_discount_percent: Number(line.commercial) || 0,
        financing_terms: line.financing || null,
        expected_date: line.expectedDate || null,
      })),
    });
    setSaving(false);
    if (rpcError) {
      toast({ title: "No se guardó la cotización", description: rpcError.message, tone: "error" });
      return;
    }
    setQuoteOpen(false); setEditingQuoteId(null);
    await open(detail.id);
    await load();
    toast({
      title: editingQuoteId ? "Cotización actualizada" : "Cotización registrada",
      description: "Se conservaron precios y condiciones del proveedor.",
      tone: "success",
    });
  }

  function awardCandidates(lineId: string, required: number) {
    return (
      detail?.quotes
        .flatMap((supplierQuote) =>
          supplierQuote.lines
            .filter(
              (quoteLine) =>
                quoteLine.requisition_line_id === lineId &&
                Number(quoteLine.available_quantity) >= required,
            )
            .map((quoteLine) => ({
              quote: supplierQuote,
              line: quoteLine,
              net:
                Number(quoteLine.unit_price) *
                (1 - Number(quoteLine.commercial_discount_percent) / 100),
            })),
        )
        .sort((a, b) => a.net - b.net) ?? []
    );
  }

  function openRecommendation() {
    if (!detail) return;
    const next: Record<string, string> = {};
    for (const line of detail.lines) {
      const candidate = awardCandidates(line.id, Number(line.required_quantity))[0];
      if (candidate) next[line.id] = candidate.line.id;
    }
    setAwardChoices(next);
    setReason("");
    setDecision("selection");
  }

  function selectedAwards() {
    if (!detail) return [];
    return detail.lines.flatMap((line) => {
      const id = awardChoices[line.id];
      return id
        ? [{ quote_line_id: id, awarded_quantity: Number(line.required_quantity), reason: "Selección de Compras" }]
        : [];
    });
  }

  async function completeSelection() {
    if (!detail) return;
    const lines = selectedAwards();
    if (lines.length !== detail.lines.length) {
      toast({
        title: "Completa la selección",
        description: "Elige una cotización que cubra cada partida.",
        tone: "error",
      });
      return;
    }
    setSaving(true);
    const { error: rpcError } = canApprove
      ? await getSupabaseClient().rpc("create_procurement_order_from_selection", { p_company_id: companyId, p_requisition_id: detail.id, p_lines: lines })
      : await getSupabaseClient().rpc("recommend_procurement_award", { p_company_id: companyId, p_requisition_id: detail.id, p_reason: "Selección preparada desde cotizaciones registradas.", p_lines: lines });
    setSaving(false);
    if (rpcError) {
      toast({ title: "No se guardó la selección", description: rpcError.message, tone: "error" });
      return;
    }
    setReason("");
    setDecision(null);
    await open(detail.id);
    await load();
    toast({ title: canApprove ? "Orden de compra creada" : "Selección enviada a aprobación", description: canApprove ? "La compra quedó autorizada y lista para recibir." : "La compra quedó lista para que una persona autorizada la apruebe.", tone: "success" });
  }

  function openQuantityEditor() {
    if (!detail) return;
    setQuantityDraft(Object.fromEntries(detail.lines.map((line) => [line.id, String(line.required_quantity)])));
    setQuantityEditorOpen(true);
  }

  async function saveAdjustedQuantities() {
    if (!detail || detail.lines.some((line) => !Number.isFinite(Number(quantityDraft[line.id])) || Number(quantityDraft[line.id]) <= 0)) {
      toast({ title: "Revisa las cantidades", description: "Usa una cantidad mayor a cero para cada partida.", tone: "error" });
      return;
    }
    setSaving(true);
    const { error: rpcError } = await getSupabaseClient().rpc("adjust_procurement_requisition_quantities", {
      p_company_id: companyId,
      p_requisition_id: detail.id,
      p_lines: detail.lines.map((line) => ({ requisition_line_id: line.id, required_quantity: Number(quantityDraft[line.id]) })),
    });
    setSaving(false);
    if (rpcError) { toast({ title: "No se ajustó la necesidad", description: rpcError.message, tone: "error" }); return; }
    setQuantityEditorOpen(false);
    await open(detail.id); await load();
    toast({ title: "Necesidad ajustada", description: "La cantidad quedó actualizada antes de pedir cotizaciones.", tone: "success" });
  }

  async function approve() {
    if (!detail || !reason.trim()) {
      toast({
        title: "Indica el motivo",
        description: "La aprobación requiere un motivo auditado.",
        tone: "error",
      });
      return;
    }
    setSaving(true);
    const { error: rpcError } = await getSupabaseClient().rpc("approve_procurement_award", {
      p_company_id: companyId,
      p_requisition_id: detail.id,
      p_reason: reason.trim(),
    });
    setSaving(false);
    if (rpcError) {
      toast({ title: "No se aprobó", description: rpcError.message, tone: "error" });
      return;
    }
    setReason("");
    setDecision(null);
    await open(detail.id);
    await load();
    toast({
      title: "Compra autorizada",
      description: "Se generó una orden de compra por cada proveedor seleccionado.",
      tone: "success",
    });
  }

  const hasCompleteQuote = detail ? detail.quotes.some((supplierQuote) => detail.lines.every((line) => {
    const quoteLine = supplierQuote.lines.find((candidate) => candidate.requisition_line_id === line.id);
    return quoteLine && Number(quoteLine.available_quantity) >= Number(line.required_quantity);
  })) : false;
  const canAdjustNeed = Boolean(detail && detail.status === "quoting" && detail.quotes.length === 0 && canCreate);
  const canSelectSupplier = Boolean(detail && detail.status === "quoting" && hasCompleteQuote && canRecommend);

  return (
    <div className="content-frame">
      <div className="page-heading">
        <div>
          <span className="eyebrow">Compras</span>
          <h1>Solicitudes de compra</h1>
          <p>Solicitudes, cotizaciones y selecciones de proveedores antes de emitir órdenes de compra.</p>
        </div>
        {canCreate && (
          <Button variant="secondary" onClick={() => void openManual()}>
            Nueva solicitud de compra
          </Button>
        )}
      </div>

      <DataToolbar
        search={query}
        onSearchChange={(value) => {
          setQuery(value);
          setPage(1);
        }}
        placeholder="Folio o ubicación"
        results={total}
        filters={
          <Select
            ariaLabel="Estado"
            value={filter}
            onValueChange={(value) => {
              setFilter(value);
              setPage(1);
            }}
            options={[
              { value: "all", label: "Todos los estados" },
              ...Object.entries(status).map(([value, label]) => ({ value, label })),
            ]}
          />
        }
      />

      <DataState
        loading={loading && !rows.length}
        error={error}
        hasData={rows.length}
        emptyTitle="No hay necesidades de compra."
        empty="Las necesidades generadas desde reabastecimiento aparecerán aquí."
        errorAction={<Button onClick={() => void load()}>Reintentar</Button>}
      >
        <div className="table-wrap surface-table">
          <table>
            <thead>
              <tr>
                <th>Folio</th>
                <th>Destino</th>
                <th>Origen</th>
                <th>Objetivo</th>
                <th>Estado</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <InteractiveTableRow key={row.id} label={`Abrir ${row.folio}`} onActivate={() => void open(row.id)}>
                  <td>
                    <strong className="mono">{row.folio}</strong>
                  </td>
                  <td>{row.location_name}</td>
                  <td>{row.source === "replenishment" ? "Reabastecimiento" : "Excepción manual"}</td>
                  <td>{formatDate(row.target_date)}</td>
                  <td>
                    <Badge tone={row.status === "approved" ? "success" : row.status === "recommended" ? "warning" : "neutral"}>
                      {requisitionStatusLabel(row)}
                    </Badge>
                  </td>
                </InteractiveTableRow>
              ))}
            </tbody>
          </table>
        </div>
        <DataPagination page={page} total={total} pageSize={pageSize} onChange={setPage} />
      </DataState>

      <Drawer
        open={Boolean(detail)}
        onOpenChange={(isOpen) => !isOpen && !saving && setDetail(null)}
        title={detail?.folio ?? "Solicitud de compra"}
        className="purchase-order-detail-drawer procurement-detail-drawer"
      >
        {detail && (
          <div className="procurement-detail">
            <header className="procurement-detail__header">
              <div>
                <span className="eyebrow">Destino</span>
                <strong>{detail.location_name}</strong>
                <small>{detail.source === "replenishment" ? "Origen: Reabastecimiento" : "Origen: excepción manual"}</small>
              </div>
              <Badge tone={detail.status === "approved" ? "success" : detail.status === "recommended" ? "warning" : "neutral"}>
                {requisitionStatusLabel({ ...detail, quote_count: detail.quotes.length })}
              </Badge>
            </header>

            <section className="procurement-detail__need">
              <header>
                <div>
                  <span className="eyebrow">Necesidad de compra</span>
                  <h3>Partidas solicitadas</h3>
                </div>
                <p>Existencia al crear la solicitud y cantidad a recuperar.</p>
              </header>
              <table>
                <thead>
                  <tr>
                    <th>Producto</th>
                    <th>Disponible</th>
                    <th>Requerido</th>
                  </tr>
                </thead>
                <tbody>
                  {detail.lines.map((line) => (
                    <tr key={line.id}>
                      <td>
                        <strong>{line.product_name}</strong>
                        <small>
                          {line.product_code ?? "Sin código"} · {line.unit ?? "Unidad"}
                        </small>
                      </td>
                      <td>{Number(line.available_quantity_snapshot).toLocaleString("es-MX")}</td>
                      <td>{Number(line.required_quantity).toLocaleString("es-MX")}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </section>

            {detail.status === "quoting" && (
              <section className="procurement-next-action" aria-labelledby="procurement-next-action-title">
                <div>
                  <span className="eyebrow">Siguiente paso</span>
                  <h3 id="procurement-next-action-title">{detail.quotes.length === 0 ? "Registra la propuesta del proveedor" : hasCompleteQuote ? "Elige cómo atender la necesidad" : "Completa una propuesta que cubra la necesidad"}</h3>
                  <p>{detail.quotes.length === 0 ? "Captura proveedor, precio y fecha estimada. Después podrás crear la orden de compra." : hasCompleteQuote ? "La cotización más conveniente se propone automáticamente; puedes cambiarla antes de confirmar." : "La disponibilidad actual no cubre todas las partidas. Registra otra cotización o actualiza la existente."}</p>
                </div>
                <div>
                  {detail.quotes.length === 0 && canQuote && <Button variant="primary" onClick={() => void openQuote()}>Registrar cotización</Button>}
                  {detail.quotes.length > 0 && !hasCompleteQuote && canQuote && <Button variant="primary" onClick={() => void openQuote()}>Registrar otra cotización</Button>}
                  {canSelectSupplier && <Button variant="primary" onClick={openRecommendation}>{canApprove ? "Crear orden de compra" : "Elegir proveedor"}</Button>}
                  {canAdjustNeed && <Button variant="secondary" onClick={openQuantityEditor}>Ajustar cantidad</Button>}
                  {detail.quotes.length > 0 && canQuote && <Button variant="secondary" onClick={() => void openQuote()}>Agregar cotización</Button>}
                </div>
              </section>
            )}

            {detail.quotes.length > 0 && <section className="procurement-comparison">
              <header className="procurement-section-header">
                <div>
                  <span className="eyebrow">Cotizaciones recibidas</span>
                  <h3>Comparativo por proveedor</h3>
                </div>
                <p>El descuento comercial afecta el total; pronto pago y financiamiento se muestran por separado.</p>
              </header>

              <div className="procurement-quote-grid">
                  {detail.quotes.map((supplierQuote) => {
                    const quoteLines = detail.lines.map((line) => ({
                      requisitionLine: line,
                      quoteLine: supplierQuote.lines.find((candidate) => candidate.requisition_line_id === line.id),
                    }));
                    const commercialTotal = quoteLines.reduce((sum, { requisitionLine, quoteLine }) => {
                      if (!quoteLine) return sum;
                      return (
                        sum +
                        Number(quoteLine.unit_price) *
                          Number(requisitionLine.required_quantity) *
                          (1 - Number(quoteLine.commercial_discount_percent) / 100)
                      );
                    }, 0);
                    const completeAvailability = quoteLines.every(
                      ({ requisitionLine, quoteLine }) =>
                        quoteLine && Number(quoteLine.available_quantity) >= Number(requisitionLine.required_quantity),
                    );

                    return (
                      <article className="procurement-quote-card" key={supplierQuote.id}>
                        <header>
                          <div>
                            <span className="eyebrow">Proveedor</span>
                            <h4>{supplierQuote.supplier_name}</h4>
                          </div>
                          <span className="procurement-quote-card__currency">{supplierQuote.currency_code}</span>
                        </header>

                        <dl className="procurement-quote-card__terms">
                          <div>
                            <dt>Disponibilidad</dt>
                            <dd className={completeAvailability ? "is-positive" : "is-warning"}>
                              {completeAvailability ? "Completa" : "Parcial"}
                            </dd>
                          </div>
                          <div>
                            <dt>Entrega</dt>
                            <dd>{supplierQuote.delivery_days ?? "—"} días</dd>
                          </div>
                          <div>
                            <dt>Crédito</dt>
                            <dd>{supplierQuote.credit_days_snapshot ?? "—"} días</dd>
                          </div>
                          <div>
                            <dt>Pronto pago</dt>
                            <dd>{Number(supplierQuote.prompt_payment_discount_percent) > 0 ? `${Number(supplierQuote.prompt_payment_discount_percent)}% · ${supplierQuote.prompt_payment_term_days ?? "—"} días` : "No aplica"}</dd>
                          </div>
                          <div>
                            <dt>Vigencia</dt>
                            <dd>{formatDate(supplierQuote.valid_until)}</dd>
                          </div>
                        </dl>

                        <div className="procurement-quote-card__lines">
                          {quoteLines.map(({ requisitionLine, quoteLine }) => {
                            const required = Number(requisitionLine.required_quantity);
                            const available = Number(quoteLine?.available_quantity ?? 0);
                            const gap = available - required;
                            const unitPrice = Number(quoteLine?.unit_price ?? 0);
                            const commercialDiscount = Number(quoteLine?.commercial_discount_percent ?? 0);

                            return (
                              <article key={requisitionLine.id}>
                                <header>
                                  <strong>{requisitionLine.product_name}</strong>
                                  <span>
                                    Requerido {required.toLocaleString("es-MX")} {requisitionLine.unit ?? ""}
                                  </span>
                                </header>
                                <dl>
                                  <div>
                                    <dt>Precio unitario</dt>
                                    <dd>{quoteLine ? formatMoney(unitPrice, supplierQuote.currency_code) : "Sin respuesta"}</dd>
                                  </div>
                                  <div>
                                    <dt>Disponible</dt>
                                    <dd className={gap >= 0 ? "is-positive" : "is-warning"}>
                                      {quoteLine ? `${available.toLocaleString("es-MX")} (${gap >= 0 ? "cubre" : `faltan ${Math.abs(gap).toLocaleString("es-MX")}`})` : "Sin respuesta"}
                                    </dd>
                                  </div>
                                  <div>
                                    <dt>Desc. comercial</dt>
                                    <dd>{commercialDiscount}%</dd>
                                  </div>
                                  <div className="procurement-quote-card__finance">
                                    <dt>Financiamiento / precio posterior</dt>
                                    <dd>{quoteLine?.financing_terms || "No informado"}</dd>
                                  </div>
                                </dl>
                              </article>
                            );
                          })}
                        </div>

                        <footer>
                          <span>Total con descuento comercial</span>
                          <strong>{formatMoney(commercialTotal, supplierQuote.currency_code)}</strong>
                          <small>No incluye descuento por pronto pago.</small>
                          {canQuote && detail.status === "quoting" && <Button variant="secondary" size="sm" onClick={() => void openQuote(supplierQuote)}>Editar cotización</Button>}
                        </footer>
                      </article>
                    );
                  })}
                </div>
            </section>}

            {detail.award && (
              <section className="procurement-award">
                <header className="procurement-section-header">
                  <div>
                    <span className="eyebrow">Selección formal</span>
                    <h3>{detail.award.status === "approved" ? "Compra autorizada" : "Selección pendiente"}</h3>
                  </div>
                  <Badge tone={detail.award.status === "approved" ? "success" : "warning"}>
                    {detail.award.status === "approved" ? "Aprobada" : "Por aprobar"}
                  </Badge>
                </header>
                <dl>
                  <div>
                    <dt>Motivo de Compras</dt>
                    <dd>{detail.award.recommendation_reason}</dd>
                  </div>
                  {detail.award.decided_reason && (
                    <div>
                      <dt>Motivo de aprobación</dt>
                      <dd>{detail.award.decided_reason}</dd>
                    </div>
                  )}
                </dl>
                {detail.award.purchase_order_ids.length > 0 && (
                  <footer>
                    <span>
                      <strong>{detail.award.purchase_order_ids.length}</strong> orden{detail.award.purchase_order_ids.length === 1 ? "" : "es"} de compra generada{detail.award.purchase_order_ids.length === 1 ? "" : "s"}, una por proveedor seleccionado.
                    </span>
                    <Button size="sm" onClick={() => router.push("/satrapy/compras/ordenes")}>
                      Ver órdenes de compra
                    </Button>
                  </footer>
                )}
              </section>
            )}

            <div className="purchase-order-actions">
              {canApprove && detail.status === "recommended" && (
                <Button
                  variant="primary"
                  onClick={() => {
                    setReason("Aprobación operativa de la selección preparada.");
                    setDecision("approve");
                  }}
                >
                  Aprobar selección
                </Button>
              )}
            </div>

            {decision && (
              <Modal
                open={Boolean(decision)}
                onOpenChange={(isOpen) => !isOpen && !saving && setDecision(null)}
                eyebrow="Decisión auditada"
                title={decision === "approve" ? "Aprobar selección" : canApprove ? "Crear orden de compra" : "Elegir proveedor"}
                description={
                  decision === "approve"
                    ? "La aprobación creará una orden de compra por proveedor seleccionado."
                    : canApprove
                      ? "Confirma la cotización elegida para cada partida. La orden de compra se creará al continuar."
                      : "Elige la cotización que gana cada partida para enviarla a aprobación."
                }
                footer={
                  <>
                    <Button onClick={() => setDecision(null)}>Cancelar</Button>
                    <Button variant="primary" loading={saving} onClick={() => void (decision === "approve" ? approve() : completeSelection())}>
                      {decision === "approve" ? "Aprobar y crear orden de compra" : canApprove ? "Crear orden de compra" : "Enviar a aprobación"}
                    </Button>
                  </>
                }
              >
                {decision === "selection" && (
                  <div className="purchase-order-form">
                    {detail.lines.map((line) => {
                      const choices = awardCandidates(line.id, Number(line.required_quantity));
                      return (
                        <Field key={line.id} label={line.product_name}>
                          <Select
                            ariaLabel={`Proveedor para ${line.product_name}`}
                            value={awardChoices[line.id] ?? ""}
                            onValueChange={(value) => setAwardChoices({ ...awardChoices, [line.id]: value })}
                            options={[
                              { value: "", label: "Sin selección", disabled: true },
                              ...choices.map((choice) => ({
                                value: choice.line.id,
                                label: `${choice.quote.supplier_name} · ${choice.quote.currency_code} ${formatMoney(choice.net, choice.quote.currency_code)} · ${choice.quote.delivery_days ?? "—"} días`,
                              })),
                            ]}
                          />
                        </Field>
                      );
                    })}
                  </div>
                )}
              </Modal>
            )}
          </div>
        )}
      </Drawer>

      <Modal
        open={quoteOpen}
        onOpenChange={(isOpen) => {
          if (!saving) {
            setQuoteOpen(isOpen);
            if (!isOpen) setEditingQuoteId(null);
          }
        }}
        eyebrow="Proveedor"
        title={editingQuoteId ? "Editar cotización" : "Registrar cotización"}
        description={editingQuoteId ? "Actualiza la respuesta comercial de este proveedor." : "Las condiciones de crédito y pronto pago se toman del proveedor; captura la respuesta comercial."}
        footer={
          <>
            <Button onClick={() => { setQuoteOpen(false); setEditingQuoteId(null); }}>Cancelar</Button>
            <Button variant="primary" loading={saving} onClick={() => void saveQuote()}>
              {editingQuoteId ? "Guardar cambios" : "Guardar cotización"}
            </Button>
          </>
        }
      >
        <div className="purchase-order-form">
          <Field label="Proveedor">
            <Select
              ariaLabel="Proveedor"
              value={quote.supplierId}
              onValueChange={(supplierId) => {
                const defaultTerm = suppliers.find((supplier) => supplier.id === supplierId)?.prompt_payment_terms?.[0];
                setQuote({
                  ...quote,
                  supplierId,
                  promptPaymentDiscount: defaultTerm ? String(defaultTerm.effective_discount_percent) : "0",
                  promptPaymentDays: defaultTerm ? String(defaultTerm.term_days) : "",
                });
              }}
              disabled={Boolean(editingQuoteId)}
              options={[
                { value: "", label: "Selecciona proveedor", disabled: true },
                ...suppliers.map((supplier) => ({ value: supplier.id, label: `${supplier.display_name} · ${supplier.code}` })),
              ]}
            />
          </Field>
          <Field label="Moneda">
            <Select
              ariaLabel="Moneda"
              value={quote.currency}
              onValueChange={(currency) => setQuote({ ...quote, currency })}
              options={[{ value: "MXN", label: "MXN" }, { value: "USD", label: "USD" }]}
            />
          </Field>
          <Field label="Vigencia">
            <Input type="date" value={quote.validUntil} onChange={(event) => setQuote({ ...quote, validUntil: event.target.value })} />
          </Field>
          <Field label="Días de entrega">
            <Input type="number" min="0" value={quote.deliveryDays} onChange={(event) => setQuote({ ...quote, deliveryDays: event.target.value })} />
          </Field>
          <section className="procurement-prompt-payment" aria-labelledby="procurement-prompt-payment-title">
            <header>
              <h3 id="procurement-prompt-payment-title">Pronto pago</h3>
              <p>Se precarga desde el proveedor. Ajusta esta cotización sólo si acordaste una condición distinta.</p>
            </header>
            <div className="purchase-order-grid">
              <Field label="Descuento %">
                <Input type="number" min="0" max="100" step="0.0001" value={quote.promptPaymentDiscount} onChange={(event) => setQuote({ ...quote, promptPaymentDiscount: event.target.value })} />
              </Field>
              <Field label="Si se paga en (días)">
                <Input type="number" min="0" step="1" value={quote.promptPaymentDays} onChange={(event) => setQuote({ ...quote, promptPaymentDays: event.target.value })} placeholder="Ej. 10" />
              </Field>
            </div>
          </section>
          <Field label="Notas para Compras">
            <Input value={quote.notes} onChange={(event) => setQuote({ ...quote, notes: event.target.value })} placeholder="Ej. incluye flete o condiciones especiales" />
          </Field>
          {detail?.lines.map((line, index) => (
            <section key={line.id}>
              <strong>{line.product_name}</strong>
              <div className="purchase-order-grid">
                <Field label="Disponible">
                  <Input
                    type="number"
                    min="0"
                    value={quote.lines[index]?.available ?? ""}
                    onChange={(event) =>
                      setQuote({
                        ...quote,
                        lines: quote.lines.map((item, itemIndex) =>
                          itemIndex === index ? { ...item, available: event.target.value } : item,
                        ),
                      })
                    }
                  />
                </Field>
                <Field label="Precio unitario">
                  <Input
                    type="number"
                    min="0"
                    step="0.0001"
                    value={quote.lines[index]?.price ?? ""}
                    onChange={(event) =>
                      setQuote({
                        ...quote,
                        lines: quote.lines.map((item, itemIndex) =>
                          itemIndex === index ? { ...item, price: event.target.value } : item,
                        ),
                      })
                    }
                  />
                </Field>
                <Field label="Descuento comercial %">
                  <Input
                    type="number"
                    min="0"
                    max="100"
                    value={quote.lines[index]?.commercial ?? "0"}
                    onChange={(event) =>
                      setQuote({
                        ...quote,
                        lines: quote.lines.map((item, itemIndex) =>
                          itemIndex === index ? { ...item, commercial: event.target.value } : item,
                        ),
                      })
                    }
                  />
                </Field>
                <Field label="Fecha estimada">
                  <Input
                    type="date"
                    value={quote.lines[index]?.expectedDate ?? ""}
                    onChange={(event) =>
                      setQuote({
                        ...quote,
                        lines: quote.lines.map((item, itemIndex) =>
                          itemIndex === index ? { ...item, expectedDate: event.target.value } : item,
                        ),
                      })
                    }
                  />
                </Field>
                <Field label="Financiamiento o condición">
                  <Input
                    value={quote.lines[index]?.financing ?? ""}
                    onChange={(event) =>
                      setQuote({
                        ...quote,
                        lines: quote.lines.map((item, itemIndex) =>
                          itemIndex === index ? { ...item, financing: event.target.value } : item,
                        ),
                      })
                    }
                    placeholder="Ej. 30 días"
                  />
                </Field>
              </div>
            </section>
          ))}
        </div>
      </Modal>

      <Modal
        open={quantityEditorOpen}
        onOpenChange={(isOpen) => !saving && setQuantityEditorOpen(isOpen)}
        eyebrow="Necesidad de compra"
        title="Ajustar cantidades"
        description="Puedes ajustar la necesidad antes de registrar cotizaciones. La solicitud conservará su origen en Reabastecimiento."
        footer={
          <>
            <Button onClick={() => setQuantityEditorOpen(false)}>Cancelar</Button>
            <Button variant="primary" loading={saving} onClick={() => void saveAdjustedQuantities()}>
              Guardar cantidades
            </Button>
          </>
        }
      >
        <div className="purchase-order-form">
          {detail?.lines.map((line) => (
            <Field key={line.id} label={line.product_name} hint={`Existencia al crear la solicitud: ${Number(line.available_quantity_snapshot).toLocaleString("es-MX")}`}>
              <Input
                aria-label={`Cantidad requerida de ${line.product_name}`}
                type="number"
                min="0.000001"
                step="0.001"
                value={quantityDraft[line.id] ?? ""}
                onChange={(event) => setQuantityDraft({ ...quantityDraft, [line.id]: event.target.value })}
              />
            </Field>
          ))}
        </div>
      </Modal>

      <Modal
        open={manualOpen}
        onOpenChange={(isOpen) => !saving && setManualOpen(isOpen)}
        eyebrow="Sólo excepción"
        title="Nueva solicitud de compra"
        description="Úsala únicamente cuando la compra no provenga de faltantes; el motivo queda auditado."
        footer={
          <>
            <Button onClick={() => setManualOpen(false)}>Cancelar</Button>
            <Button variant="primary" loading={saving} onClick={() => void saveManual()}>
              Crear solicitud
            </Button>
          </>
        }
      >
        <div className="purchase-order-form">
          <Field label="Ubicación destino">
            <Select
              ariaLabel="Ubicación destino"
              value={manual.locationId}
              onValueChange={(locationId) => setManual({ ...manual, locationId })}
              options={[
                { value: "", label: "Selecciona ubicación", disabled: true },
                ...accessibleLocations.map((location) => ({ value: location.id, label: `${location.external_code} · ${location.name}` })),
              ]}
            />
          </Field>
          <Field label="Producto">
            <Select
              ariaLabel="Producto excepcional"
              value={manual.productId}
              onValueChange={(productId) => setManual({ ...manual, productId })}
              options={[
                { value: "", label: "Selecciona producto", disabled: true },
                ...products.map((product) => ({
                  value: product.id,
                  label: `${product.name} · ${product.internal_sku ?? product.alpha_sku ?? "Sin código"}`,
                })),
              ]}
            />
          </Field>
          <Field label="Cantidad">
            <Input type="number" min="0.000001" step="0.001" value={manual.quantity} onChange={(event) => setManual({ ...manual, quantity: event.target.value })} />
          </Field>
          <Field label="Fecha objetivo">
            <Input type="date" value={manual.targetDate} onChange={(event) => setManual({ ...manual, targetDate: event.target.value })} />
          </Field>
          <Field label="Motivo de excepción">
            <Input value={manual.reason} onChange={(event) => setManual({ ...manual, reason: event.target.value })} placeholder="Ej. compra especial autorizada" />
          </Field>
        </div>
      </Modal>
    </div>
  );
}
