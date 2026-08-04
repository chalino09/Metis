"use client";

import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
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
};

type QuoteLine = {
  id: string;
  requisition_line_id: string;
  available_quantity: number;
  unit_price: number;
  commercial_discount_percent: number;
  prompt_payment_discount_percent: number;
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
    valid_until: string | null;
    lines: QuoteLine[];
  }>;
  award: null | {
    status: string;
    recommendation_reason: string;
    decided_reason: string | null;
    purchase_order_ids: string[];
  };
};

type Supplier = { id: string; display_name: string; code: string };
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
  prompt: string;
  financing: string;
};

const pageSize = 50;
const status: Record<string, string> = {
  draft: "Borrador",
  quoting: "En cotización",
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

export function ProcurementView({
  companyId,
  permissions,
}: {
  companyId: string;
  permissions: string[];
}) {
  const router = useRouter();
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
  const [saving, setSaving] = useState(false);
  const [reason, setReason] = useState("");
  const [decision, setDecision] = useState<"recommend" | "approve" | null>(null);
  const [awardChoices, setAwardChoices] = useState<Record<string, string>>({});
  const [quote, setQuote] = useState({
    supplierId: "",
    currency: "MXN",
    validUntil: "",
    deliveryDays: "",
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

  async function open(id: string) {
    const { data, error: rpcError } = await getSupabaseClient().rpc(
      "get_procurement_requisition",
      { p_company_id: companyId, p_requisition_id: id },
    );
    if (rpcError) {
      setError(rpcError.message);
      return;
    }
    setDetail(data as Detail);
  }

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

  async function openQuote() {
    if (!detail) return;
    const { data } = await getSupabaseClient().rpc("search_suppliers", {
      p_company_id: companyId,
      p_query: null,
      p_page: 1,
      p_page_size: 100,
      p_is_active: true,
      p_origin: null,
    });
    setSuppliers(((data as { items?: Supplier[] } | null)?.items ?? []));
    setQuote({
      supplierId: "",
      currency: "MXN",
      validUntil: "",
      deliveryDays: "",
      notes: "",
      lines: detail.lines.map((line) => ({
        requisitionLineId: line.id,
        available: String(line.required_quantity),
        price: "",
        commercial: "0",
        prompt: "0",
        financing: "",
      })),
    });
    setQuoteOpen(true);
  }

  async function saveQuote() {
    if (
      !detail ||
      !quote.supplierId ||
      quote.lines.some(
        (line) =>
          !Number.isFinite(Number(line.available)) ||
          Number(line.available) < 0 ||
          !Number.isFinite(Number(line.price)) ||
          Number(line.price) < 0,
      )
    ) {
      toast({
        title: "Revisa la cotización",
        description: "Selecciona proveedor y captura cantidades y precios válidos.",
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
      p_notes: quote.notes || null,
      p_lines: quote.lines.map((line) => ({
        requisition_line_id: line.requisitionLineId,
        available_quantity: Number(line.available),
        unit_price: Number(line.price),
        commercial_discount_percent: Number(line.commercial) || 0,
        prompt_payment_discount_percent: Number(line.prompt) || 0,
        financing_terms: line.financing || null,
      })),
    });
    setSaving(false);
    if (rpcError) {
      toast({ title: "No se guardó la cotización", description: rpcError.message, tone: "error" });
      return;
    }
    setQuoteOpen(false);
    await open(detail.id);
    await load();
    toast({
      title: "Cotización registrada",
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
    setDecision("recommend");
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

  async function recommend() {
    if (!detail) return;
    const lines = selectedAwards();
    if (lines.length !== detail.lines.length || !reason.trim()) {
      toast({
        title: "No se puede recomendar",
        description: "Selecciona una cotización disponible por partida e indica el motivo.",
        tone: "error",
      });
      return;
    }
    setSaving(true);
    const { error: rpcError } = await getSupabaseClient().rpc("recommend_procurement_award", {
      p_company_id: companyId,
      p_requisition_id: detail.id,
      p_reason: reason.trim(),
      p_lines: lines,
    });
    setSaving(false);
    if (rpcError) {
      toast({ title: "No se guardó la selección", description: rpcError.message, tone: "error" });
      return;
    }
    setReason("");
    setDecision(null);
    await open(detail.id);
    await load();
    toast({ title: "Selección preparada", description: "Quedó lista para aprobación.", tone: "success" });
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
                      {status[row.status] ?? row.status}
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
              </div>
              <Badge tone={detail.status === "approved" ? "success" : detail.status === "recommended" ? "warning" : "neutral"}>
                {status[detail.status] ?? detail.status}
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

            <section className="procurement-comparison">
              <header className="procurement-section-header">
                <div>
                  <span className="eyebrow">Cotizaciones recibidas</span>
                  <h3>Comparativo por proveedor</h3>
                </div>
                <p>El descuento comercial afecta el total; pronto pago y financiamiento se muestran por separado.</p>
              </header>

              {detail.quotes.length ? (
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
                                  <div>
                                    <dt>Pronto pago</dt>
                                    <dd>{Number(quoteLine?.prompt_payment_discount_percent ?? 0)}%</dd>
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
                        </footer>
                      </article>
                    );
                  })}
                </div>
              ) : (
                <div className="procurement-empty-comparison">
                  <strong>Aún no hay cotizaciones registradas.</strong>
                  <span>Registra las respuestas de los proveedores para preparar la selección.</span>
                </div>
              )}
            </section>

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
              {canQuote && detail.status !== "approved" && <Button onClick={() => void openQuote()}>Registrar cotización</Button>}
              {canRecommend && detail.status === "quoting" && (
                <Button variant="primary" onClick={openRecommendation}>
                  Preparar selección
                </Button>
              )}
              {canApprove && detail.status === "recommended" && (
                <Button
                  variant="primary"
                  onClick={() => {
                    setReason("");
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
                title={decision === "approve" ? "Aprobar selección" : "Seleccionar proveedor por partida"}
                description={
                  decision === "approve"
                    ? "La aprobación creará una orden de compra por proveedor seleccionado."
                    : "Elige la cotización que gana cada partida; el precio menor se propone como punto de partida."
                }
                footer={
                  <>
                    <Button onClick={() => setDecision(null)}>Cancelar</Button>
                    <Button variant="primary" loading={saving} onClick={() => void (decision === "approve" ? approve() : recommend())}>
                      {decision === "approve" ? "Aprobar y crear orden de compra" : "Guardar selección"}
                    </Button>
                  </>
                }
              >
                {decision === "recommend" && (
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
                <Field label="Motivo">
                  <Input value={reason} onChange={(event) => setReason(event.target.value)} placeholder="Explica la elección o aprobación" />
                </Field>
              </Modal>
            )}
          </div>
        )}
      </Drawer>

      <Modal
        open={quoteOpen}
        onOpenChange={(isOpen) => !saving && setQuoteOpen(isOpen)}
        eyebrow="Proveedor"
        title="Registrar cotización"
        description="Las condiciones de crédito y pronto pago se toman del proveedor; captura la respuesta comercial."
        footer={
          <>
            <Button onClick={() => setQuoteOpen(false)}>Cancelar</Button>
            <Button variant="primary" loading={saving} onClick={() => void saveQuote()}>
              Guardar cotización
            </Button>
          </>
        }
      >
        <div className="purchase-order-form">
          <Field label="Proveedor">
            <Select
              ariaLabel="Proveedor"
              value={quote.supplierId}
              onValueChange={(supplierId) => setQuote({ ...quote, supplierId })}
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
                <Field label="Pronto pago %">
                  <Input
                    type="number"
                    min="0"
                    max="100"
                    value={quote.lines[index]?.prompt ?? "0"}
                    onChange={(event) =>
                      setQuote({
                        ...quote,
                        lines: quote.lines.map((item, itemIndex) =>
                          itemIndex === index ? { ...item, prompt: event.target.value } : item,
                        ),
                      })
                    }
                  />
                </Field>
              </div>
            </section>
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
