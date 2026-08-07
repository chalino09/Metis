"use client";

import { Banknote, CreditCard, ExternalLink, PackageCheck, ShoppingCart } from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useRef, useState, type FormEvent } from "react";
import { DataPagination, DataRefreshStatus, DataState, DataToolbar, InteractiveTableRow, Table } from "@/app/components/ui/data";
import { Badge, Button, CurrencyInput, Drawer, Field, Input, Modal, Select, useToast } from "@/app/components/ui/primitives";
import { OperationIdempotencyKeys } from "@/app/lib/operation-idempotency";
import { getSupabaseClient } from "@/app/lib/supabase";

type Location = { id: string; name: string; code: string };
type Customer = { id: string; code: string; display_name: string };
type PaymentMethod = { id: string; code: string; name: string; settlement_kind: "cash_drawer" | "external" };
type CashSession = { id: string; location_id: string; cash_register_id: string };
type OrderLine = { product_id: string; product_code?: string | null; product_name: string; unit_name?: string | null; quantity: number; unit_total_amount: number; line_total_amount: number };
type OrderPayment = { id: string; payment_kind: "deposit" | "final"; payment_method_id: string; payment_method_name: string; settlement_kind: "cash_drawer" | "external"; amount: number; payment_reference: string | null; received_at: string };
type OrderRow = { id: string; folio: string; status: "open" | "completed"; customer_name: string; location_name: string; currency_code: string; total_amount: number; paid_amount: number; outstanding_amount: number; expected_delivery_date: string | null; updated_at: string };
type OrderDetail = {
  id: string; folio: string; status: "open" | "completed"; expected_delivery_date: string | null; currency_code: string;
  subtotal_amount: number; tax_amount: number; total_amount: number; paid_amount: number; outstanding_amount: number;
  sale_id: string | null; completed_at: string | null; source: { kind: "quote" | "pos"; id?: string; folio?: string } | null; customer: Customer; location: Location; lines: OrderLine[]; payments: OrderPayment[];
};

const PAGE_SIZE = 25;
const money = (amount: number, currency = "MXN") => new Intl.NumberFormat("es-MX", { style: "currency", currency }).format(Number(amount ?? 0));
const dateTime = (value: string) => new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value));

function paymentLabel(order: { paid_amount: number; outstanding_amount: number }) {
  return order.outstanding_amount <= 0 ? "Pagada" : order.paid_amount > 0 ? "Pago parcial" : "Sin pagos";
}

export function SalesOrdersView({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { toast } = useToast();
  const idempotency = useRef(new OperationIdempotencyKeys()).current;
  const request = useRef(0);
  const [rows, setRows] = useState<OrderRow[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState("open");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [detail, setDetail] = useState<OrderDetail | null>(null);
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethod[]>([]);
  const [cashSession, setCashSession] = useState<CashSession | null>(null);
  const [paymentOpen, setPaymentOpen] = useState(false);
  const [paymentMethodId, setPaymentMethodId] = useState("");
  const [paymentAmount, setPaymentAmount] = useState("");
  const [paymentReference, setPaymentReference] = useState("");
  const [busy, setBusy] = useState(false);
  const canManage = permissions.includes("*") || permissions.includes("manage_sales_orders");

  const loadContext = useCallback(async () => {
    const { data } = await getSupabaseClient().rpc("get_sales_deposit_order_context", { p_company_id: companyId });
    const context = data as { payment_methods?: PaymentMethod[]; own_open_session?: CashSession | null } | null;
    setPaymentMethods(context?.payment_methods ?? []);
    setCashSession(context?.own_open_session ?? null);
    setPaymentMethodId((current) => context?.payment_methods?.some((method) => method.id === current) ? current : context?.payment_methods?.[0]?.id ?? "");
  }, [companyId]);

  const load = useCallback(async () => {
    const current = ++request.current;
    setLoading(true);
    const { data, error: loadError } = await getSupabaseClient().rpc("list_sales_deposit_orders", {
      p_company_id: companyId, p_query: query || null, p_status: status === "all" ? null : status, p_page: page, p_page_size: PAGE_SIZE,
    });
    if (current !== request.current) return;
    const result = data as { items?: OrderRow[]; total?: number } | null;
    setRows(result?.items ?? []); setTotal(result?.total ?? 0); setError(loadError?.message ?? null); setLoading(false);
  }, [companyId, page, query, status]);

  useEffect(() => { void Promise.resolve().then(loadContext); }, [loadContext]);
  useEffect(() => { const timer = window.setTimeout(() => void load(), 180); return () => window.clearTimeout(timer); }, [load]);

  const openDetail = useCallback(async (id: string) => {
    const { data, error: detailError } = await getSupabaseClient().rpc("get_sales_deposit_order_detail", { p_company_id: companyId, p_order_id: id });
    if (detailError || !data) toast({ title: "No se abrió el pedido", description: detailError?.message, tone: "error" }); else setDetail(data as OrderDetail);
  }, [companyId, toast]);
  useEffect(() => {
    const orderId = new URLSearchParams(window.location.search).get("order");
    if (!orderId) return;
    const timer = window.setTimeout(() => void openDetail(orderId), 0);
    return () => window.clearTimeout(timer);
  }, [openDetail]);
  function startPayment() {
    if (!detail) return;
    setPaymentAmount(String(detail.outstanding_amount));
    setPaymentReference("");
    setPaymentMethodId(detail.payments[0]?.payment_method_id ?? paymentMethods[0]?.id ?? "");
    setPaymentOpen(true);
  }
  async function recordPayment(event: FormEvent) {
    event.preventDefault();
    if (!detail || !paymentMethodId) return;
    const amount = Number(paymentAmount);
    if (!Number.isFinite(amount) || amount <= 0 || amount > detail.outstanding_amount) {
      toast({ title: "Importe no válido", description: `Captura un importe entre ${money(0.01, detail.currency_code)} y ${money(detail.outstanding_amount, detail.currency_code)}.`, tone: "error" });
      return;
    }
    const method = paymentMethods.find((item) => item.id === paymentMethodId);
    const fingerprint = JSON.stringify({ orderId: detail.id, paymentMethodId, amount, reference: paymentReference });
    setBusy(true);
    const { data, error: paymentError } = await getSupabaseClient().rpc("record_sales_deposit_order_payment", {
      p_company_id: companyId, p_order_id: detail.id, p_payment_method_id: paymentMethodId, p_amount: amount,
      p_cash_session_id: method?.settlement_kind === "cash_drawer" ? cashSession?.id ?? null : null,
      p_payment_reference: paymentReference.trim() || null,
      p_client_request_id: idempotency.get("sales-order-payment", fingerprint),
    });
    setBusy(false);
    if (paymentError || !data) { toast({ title: "No se registró el pago", description: paymentError?.message ?? "Verifica importe, caja y forma de pago.", tone: "error" }); return; }
    idempotency.clear("sales-order-payment"); setDetail(data as OrderDetail); setPaymentOpen(false); await load();
    toast({ title: "Pago registrado", description: "El expediente y el saldo de la orden fueron actualizados.", tone: "success" });
  }
  async function deliver() {
    if (!detail || detail.outstanding_amount > 0 || !cashSession) return;
    const fingerprint = JSON.stringify({ orderId: detail.id, cashSessionId: cashSession.id });
    setBusy(true);
    const { data, error: deliveryError } = await getSupabaseClient().rpc("deliver_sales_deposit_order", {
      p_company_id: companyId, p_order_id: detail.id, p_cash_session_id: cashSession.id,
      p_client_request_id: idempotency.get("sales-order-delivery", fingerprint),
    });
    setBusy(false);
    if (deliveryError || !data) { toast({ title: "No se confirmó la entrega", description: deliveryError?.message ?? "Revisa existencia y caja.", tone: "error" }); return; }
    idempotency.clear("sales-order-delivery"); setDetail(data as OrderDetail); await load();
    toast({ title: "Entrega confirmada", description: "Se generaron la venta, el ticket y la salida de inventario.", tone: "success" });
  }

  const selectedMethod = paymentMethods.find((item) => item.id === paymentMethodId) ?? null;
  const correctCashLocation = Boolean(detail && cashSession?.location_id === detail.location.id);

  return <div className="content-frame sales-orders">
    <div className="page-heading"><div><span className="eyebrow">Cumplimiento de pedidos</span><h1>Pedidos</h1><p>Administra anticipos, saldos y entregas de pedidos creados desde POS o cotizaciones aceptadas.</p></div><Link className="ui-button ui-button--primary ui-button--md" href="/satrapy/ventas/pos"><ShoppingCart size={16} /> Iniciar en POS</Link></div>
    <DataToolbar search={query} onSearchChange={(value) => { setQuery(value); setPage(1); }} placeholder="Buscar folio o cliente" results={total} activeFilters={status === "all" ? 0 : 1} onClear={() => { setStatus("all"); setPage(1); }} filters={<Select ariaLabel="Filtrar pedidos por entrega" value={status} onValueChange={(value) => { setStatus(value); setPage(1); }} options={[{ value: "all", label: "Todos los pedidos" }, { value: "open", label: "Pendientes de entrega" }, { value: "completed", label: "Entregados" }]} />} />
    <DataRefreshStatus loading={loading} hasData={rows.length} />
    <DataState loading={loading && !rows.length} error={error} hasData={rows.length} emptyTitle="Aún no hay pedidos." empty="Inicia una entrega posterior en POS o crea un pedido desde una cotización aceptada.">
      <Table><thead><tr><th>Pedido</th><th>Cliente</th><th>Entrega esperada</th><th>Pago</th><th>Entrega</th><th className="number-cell">Saldo</th></tr></thead><tbody>{rows.map((order) => <InteractiveTableRow key={order.id} label={"Abrir pedido " + order.folio} onActivate={() => void openDetail(order.id)}><td><strong className="mono">{order.folio}</strong><small>{order.location_name}</small></td><td>{order.customer_name}</td><td>{order.expected_delivery_date ? new Date(order.expected_delivery_date + "T12:00:00").toLocaleDateString("es-MX") : "Por acordar"}</td><td><Badge tone={order.outstanding_amount <= 0 ? "success" : order.paid_amount > 0 ? "info" : "neutral"}>{paymentLabel(order)}</Badge><small>{money(order.paid_amount, order.currency_code)} de {money(order.total_amount, order.currency_code)}</small></td><td><Badge tone={order.status === "completed" ? "success" : "warning"}>{order.status === "completed" ? "Entregada" : "Pendiente"}</Badge></td><td className="number-cell"><strong>{money(order.outstanding_amount, order.currency_code)}</strong></td></InteractiveTableRow>)}</tbody></Table>
      <DataPagination page={page} total={total} pageSize={PAGE_SIZE} onChange={setPage} />
    </DataState>

    <Drawer open={Boolean(detail)} onOpenChange={(open) => !open && !busy && setDetail(null)} title={detail?.folio ?? "Pedido"} className="sales-quote-detail">{detail && <div className="sales-order-detail">
      <header><div><span className="sales-order-badges"><Badge tone={detail.outstanding_amount <= 0 ? "success" : detail.paid_amount > 0 ? "info" : "neutral"}>{paymentLabel(detail)}</Badge><Badge tone={detail.status === "completed" ? "success" : "warning"}>{detail.status === "completed" ? "Entregada" : "Entrega pendiente"}</Badge></span><strong>{detail.customer.display_name}</strong><small>{detail.customer.code} · {detail.location.name}{detail.expected_delivery_date ? " · Esperada " + new Date(detail.expected_delivery_date + "T12:00:00").toLocaleDateString("es-MX") : ""}</small></div><span><small>Saldo</small><b>{money(detail.outstanding_amount, detail.currency_code)}</b></span></header>
      <section className="sales-order-balance"><article><small>Total</small><strong>{money(detail.total_amount, detail.currency_code)}</strong></article><article><small>Pagado</small><strong>{money(detail.paid_amount, detail.currency_code)}</strong></article><article><small>Pendiente</small><strong>{money(detail.outstanding_amount, detail.currency_code)}</strong></article></section>
      <section className="sales-order-context"><article><small>Origen</small>{detail.source?.kind === "quote" && detail.source.id && detail.source.folio ? <Link href={`/satrapy/ventas/cotizaciones?quote=${detail.source.id}`}>Cotización {detail.source.folio} <ExternalLink size={13} /></Link> : detail.source?.kind === "pos" ? <strong>POS</strong> : <strong>Disponible al actualizar</strong>}</article><article><small>Entrega esperada</small><strong>{detail.expected_delivery_date ? new Date(detail.expected_delivery_date + "T12:00:00").toLocaleDateString("es-MX") : "Por acordar"}</strong></article><article><small>Estado de entrega</small><strong>{detail.status === "completed" ? "Entregada" : "Pendiente"}</strong></article></section>
      <section><h3 className="sales-order-section-title">Productos</h3><Table><thead><tr><th>Producto</th><th className="number-cell">Cantidad</th><th className="number-cell">Precio</th><th className="number-cell">Importe</th></tr></thead><tbody>{detail.lines.map((line) => <tr key={line.product_id}><td><strong>{line.product_name}</strong><small>{line.product_code ?? "Sin código"}</small></td><td className="number-cell">{Number(line.quantity).toLocaleString("es-MX")}</td><td className="number-cell">{money(line.unit_total_amount, detail.currency_code)}</td><td className="number-cell">{money(line.line_total_amount, detail.currency_code)}</td></tr>)}</tbody></Table></section>
      <section className="sales-order-payments"><h3>Pagos a cuenta</h3>{detail.payments.length ? detail.payments.map((payment) => <article key={payment.id}><span>{payment.settlement_kind === "cash_drawer" ? <Banknote size={16} /> : <CreditCard size={16} />}<span><strong>{payment.payment_method_name}</strong><small>{dateTime(payment.received_at)}{payment.payment_reference ? " · " + payment.payment_reference : ""}</small></span></span><b>{money(payment.amount, detail.currency_code)}</b></article>) : <p>Esta orden todavía no tiene pagos.</p>}</section>
      <section className="sales-order-delivery"><span><PackageCheck size={18} /><span><strong>{detail.status === "completed" ? "Entrega confirmada" : "Entrega pendiente"}</strong><small>{detail.status === "completed" && detail.completed_at ? dateTime(detail.completed_at) : detail.outstanding_amount > 0 ? "Liquida el saldo antes de entregar." : "Pago completo; valida existencia para entregar."}</small></span></span>{detail.sale_id && <Link href="/satrapy/ventas/historial">Ver venta y ticket <ExternalLink size={13} /></Link>}</section>
      {detail.status === "open" && canManage && <footer>{detail.outstanding_amount > 0 && <Button variant="primary" onClick={startPayment}><CreditCard size={15} /> Registrar pago a cuenta</Button>}<Button variant={detail.outstanding_amount <= 0 ? "primary" : "secondary"} disabled={detail.outstanding_amount > 0 || !correctCashLocation || busy} loading={busy} onClick={() => void deliver()}><PackageCheck size={15} /> Confirmar entrega</Button><small>{detail.outstanding_amount > 0 ? "La entrega se habilita al liquidar el saldo." : !correctCashLocation ? "Abre caja en la sucursal de esta orden para entregar." : "Al confirmar se descuenta inventario y se genera el ticket final."}</small></footer>}
    </div>}</Drawer>

    <Modal open={paymentOpen && Boolean(detail)} onOpenChange={(open) => !open && !busy && setPaymentOpen(false)} eyebrow="Pedido" title="Registrar pago a cuenta" description={detail ? `Saldo disponible para aplicar: ${money(detail.outstanding_amount, detail.currency_code)}.` : ""} footer={<><Button disabled={busy} onClick={() => setPaymentOpen(false)}>Cancelar</Button><Button type="submit" form="sales-order-payment" variant="primary" loading={busy}>Registrar pago</Button></>}>
      <form id="sales-order-payment" className="sales-order-deposit-form" onSubmit={recordPayment}><Field label="Importe"><CurrencyInput required autoFocus value={paymentAmount} onValueChange={setPaymentAmount} currency={detail?.currency_code ?? "MXN"} aria-label="Importe del pago a cuenta" /></Field><Field label="Forma de pago"><Select ariaLabel="Forma del pago a cuenta" value={paymentMethodId} onValueChange={(value) => { setPaymentMethodId(value); setPaymentReference(""); }} disabled={Boolean(detail?.payments.length)} options={paymentMethods.map((method) => ({ value: method.id, label: method.name }))} /></Field>{selectedMethod?.settlement_kind === "external" && <Field label="Referencia"><Input required value={paymentReference} onChange={(event) => setPaymentReference(event.target.value)} placeholder="Transferencia, depósito o terminal" /></Field>}{selectedMethod?.settlement_kind === "cash_drawer" && <p className="sales-order-cash-note">{correctCashLocation ? "El pago se sumará a tu caja abierta." : "Debes abrir caja en la sucursal de la orden."}</p>}</form>
    </Modal>
  </div>;
}
