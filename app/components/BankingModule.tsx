"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { AlertTriangle, ArrowDownLeft, ArrowUpRight, CheckCircle2, Landmark, RefreshCw, Unlink, UploadCloud } from "lucide-react";
import { Badge, Button, Input, Select, useToast } from "@/app/components/ui/primitives";
import { DataState, PageHeading, Table } from "@/app/components/ui/data";
import { getSupabaseClient } from "@/app/lib/supabase";

type Account = { id: string; alias: string; institution_name: string; currency_code: string; masked_ending: string; is_active: boolean };
type Batch = { id: string; original_name: string; period_start: string; period_end: string; currency_code: string; opening_balance: number; closing_balance: number; total_credits: number; total_debits: number; calculated_closing_balance: number; balance_difference: number; balance_valid: boolean; status: string; row_count: number };
type Transaction = { id: string; transaction_date: string; reference: string; description: string | null; direction: "credit" | "debit"; amount: number; currency_code: string; active_reconciliation_id: string | null };
type Candidate = { id: string; bank_transaction_id: string; source_type: "receivable_payment" | "supplier_payment"; source_id: string; match_quality: "exact" | "possible"; amount_difference: number; date_difference_days: number; reference_matches: boolean; evidence: Record<string, unknown> };
type Exception = { id: string; exception_code: string; message: string; bank_transaction_id: string | null };
type Workspace = { accounts: Account[]; selected_account_id: string | null; batches: Batch[]; transactions: Transaction[]; candidates: Candidate[]; exceptions: Exception[]; pagination: { page: number; pages: number; total: number } };

const empty: Workspace = { accounts: [], selected_account_id: null, batches: [], transactions: [], candidates: [], exceptions: [], pagination: { page: 1, pages: 0, total: 0 } };

export function BankingModule({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const { toast } = useToast();
  const [data, setData] = useState<Workspace>(empty);
  const [accountId, setAccountId] = useState("");
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [justifications, setJustifications] = useState<Record<string, string>>({});
  const [disconnectReason, setDisconnectReason] = useState("");
  const [selectedLinks, setSelectedLinks] = useState<string[]>([]);

  const load = useCallback(async (requestedAccount = accountId, requestedPage = page) => {
    setLoading(true); setError(null);
    const { data: result, error: rpcError } = await getSupabaseClient().rpc("list_banking_workspace", { p_company_id: companyId, p_account_id: requestedAccount || null, p_page: requestedPage, p_page_size: 50 });
    if (rpcError) setError(rpcError.message);
    else {
      const workspace = result as Workspace;
      setData(workspace);
      if (!requestedAccount && workspace.selected_account_id) setAccountId(workspace.selected_account_id);
    }
    setLoading(false);
  }, [accountId, companyId, page]);

  useEffect(() => { window.scrollTo({ top: 0 }); }, [companyId]);
  useEffect(() => { void Promise.resolve().then(() => load()); }, [load]);

  async function run(name: string, args: Record<string, unknown>, success: string) {
    setBusy(true);
    const { error: rpcError } = await getSupabaseClient().rpc(name, args);
    if (rpcError) toast({ title: "No se pudo completar", description: rpcError.message, tone: "error" });
    else {
      toast({ title: success, tone: "success" });
      setSelected([]); setSelectedLinks([]); setJustifications({}); setDisconnectReason("");
      await load();
    }
    setBusy(false);
  }

  const byTransaction = useMemo(() => Object.fromEntries(data.transactions.map((item) => [item.id, item])), [data.transactions]);
  const selectedAccount = data.accounts.find((item) => item.id === accountId);
  const exactCount = data.candidates.filter((item) => item.match_quality === "exact").length;
  const activeLinks = data.transactions.filter((item) => item.active_reconciliation_id);
  const canReconcile = permissions.includes("reconcile_banking");
  const canDisconnect = permissions.includes("unreconcile_banking");

  return <div className="content-frame banking-module">
    <PageHeading eyebrow="Tesorería" title="Bancos y conciliación" description="Explica estados completos y confirma coincidencias contra cobros bancarios y pagos registrados." action={<Button variant="secondary" loading={loading} onClick={() => void load()}><RefreshCw size={15} />Actualizar</Button>} />
    <DataState loading={loading} error={error} hasData={1} empty="" errorAction={<Button size="sm" onClick={() => void load()}>Reintentar</Button>}>
      <section className="banking-toolbar">
        <div><span className="eyebrow">Cuenta financiera</span><Select ariaLabel="Cuenta financiera" value={accountId} onValueChange={(value) => { setAccountId(value); setPage(1); void load(value, 1); }} placeholder="Cuenta financiera" options={data.accounts.map((item) => ({ value: item.id, label: `${item.alias} · ${item.currency_code} · ${item.masked_ending}` }))} /></div>
        {selectedAccount && <p><strong>{selectedAccount.institution_name}</strong><span>{selectedAccount.currency_code} · {selectedAccount.masked_ending}</span></p>}
        <Link className="ui-button ui-button--secondary ui-button--md" href="/satrapy/configuracion/importaciones"><UploadCloud size={15} />Cargar otro estado</Link>
      </section>

      {!data.accounts.length ? <section className="accounting-readiness"><span className="accounting-readiness__icon"><Landmark size={22} /></span><div><strong>No hay cuentas financieras</strong><p>Las cuentas pagadoras existentes se convierten automáticamente. Administra el catálogo bancario antes de cargar un estado.</p></div></section> : <>
        <section className="banking-kpis">
          <article><span><Landmark size={16} />Movimientos</span><strong>{data.pagination.total.toLocaleString("es-MX")}</strong><small>incorporados e inmutables</small></article>
          <article><span><CheckCircle2 size={16} />Por confirmar</span><strong>{exactCount}</strong><small>coincidencias exactas</small></article>
          <article className={data.exceptions.length ? "has-warning" : ""}><span><AlertTriangle size={16} />Excepciones</span><strong>{data.exceptions.length}</strong><small>{data.exceptions.length ? "requieren revisión" : "sin pendientes"}</small></article>
        </section>

        <section className="banking-statements">{data.batches.map((batch) => <article className="bank-statement-card" key={batch.id}>
          <header><div><span className="eyebrow">Estado bancario</span><h2>{batch.original_name}</h2><p>{formatDate(batch.period_start)}–{formatDate(batch.period_end)} · {batch.row_count.toLocaleString("es-MX")} movimientos</p></div><Badge tone={batch.balance_valid ? "success" : "danger"}>{batch.balance_valid ? "Saldo explicado" : "Diferencia de saldo"}</Badge></header>
          <div className="bank-balance-flow">
            <BalancePart label="Saldo inicial" value={batch.opening_balance} currency={batch.currency_code ?? selectedAccount?.currency_code} />
            <b aria-hidden="true">+</b>
            <BalancePart label="Abonos" value={batch.total_credits} currency={batch.currency_code ?? selectedAccount?.currency_code} tone="credit" />
            <b aria-hidden="true">−</b>
            <BalancePart label="Cargos" value={batch.total_debits} currency={batch.currency_code ?? selectedAccount?.currency_code} tone="debit" />
            <b aria-hidden="true">=</b>
            <BalancePart label="Saldo final" value={batch.closing_balance} currency={batch.currency_code ?? selectedAccount?.currency_code} emphasized />
          </div>
          {batch.status === "ready" && <footer><span>Se incorporarán todos los movimientos en una sola transacción.</span><Button variant="primary" disabled={busy || !permissions.includes("import_bank_statements")} onClick={() => void run("promote_bank_statement", { p_batch_id: batch.id, p_client_request_id: crypto.randomUUID() }, "Estado bancario incorporado")}>Incorporar movimientos</Button></footer>}
        </article>)}</section>

        <section className="accounting-panel banking-movements"><header><div><h2>Movimientos del estado</h2><p>Consulta la evidencia incorporada y su situación de conciliación.</p></div><Badge>{data.pagination.total}</Badge></header>
          <DataState loading={false} error={null} hasData={data.transactions.length} empty="No hay movimientos incorporados para esta cuenta."><Table><thead><tr><th>Fecha</th><th>Referencia</th><th>Descripción</th><th>Tipo</th><th>Importe</th><th>Conciliación</th></tr></thead><tbody>{data.transactions.map((item) => <tr key={item.id}><td>{formatDate(item.transaction_date)}</td><td className="mono"><strong>{item.reference}</strong></td><td>{item.description ?? "—"}</td><td><span className={`bank-direction is-${item.direction}`}>{item.direction === "credit" ? <ArrowDownLeft size={14} /> : <ArrowUpRight size={14} />}{item.direction === "credit" ? "Abono" : "Cargo"}</span></td><td className="number-cell"><strong>{formatMoney(item.amount, item.currency_code)}</strong></td><td><Badge tone={item.active_reconciliation_id ? "success" : "neutral"}>{item.active_reconciliation_id ? "Conciliado" : "Pendiente"}</Badge></td></tr>)}</tbody></Table></DataState>
        </section>

        <section className="accounting-panel banking-candidates"><header><div><h2>Candidatos por confirmar</h2><p>Satrapy compara cuenta, moneda, importe, fecha y referencia; nunca confirma por sí solo.</p></div><Badge tone={data.candidates.length ? "warning" : "neutral"}>{data.candidates.length}</Badge></header>
          {data.candidates.length === 0 ? <CompactEmpty icon={<CheckCircle2 size={18} />} title="Sin candidatos pendientes" detail="Los movimientos sin evidencia suficiente permanecen en Excepciones." /> : <Table><thead><tr><th></th><th>Movimiento</th><th>Origen</th><th>Resultado</th><th>Diferencia</th><th>Justificación</th></tr></thead><tbody>{data.candidates.map((candidate) => { const transaction = byTransaction[candidate.bank_transaction_id]; return <tr key={candidate.id}><td><input aria-label="Seleccionar candidato" type="checkbox" checked={selected.includes(candidate.id)} onChange={() => setSelected(selected.includes(candidate.id) ? selected.filter((id) => id !== candidate.id) : [...selected, candidate.id])} /></td><td><strong>{transaction?.reference ?? "—"}</strong><small>{transaction ? `${formatDate(transaction.transaction_date)} · ${formatMoney(transaction.amount, transaction.currency_code)}` : "Movimiento fuera de esta página"}</small></td><td>{candidate.source_type === "supplier_payment" ? "Pago confirmado" : "Cobro bancario"}</td><td><Badge tone={candidate.match_quality === "exact" ? "success" : "warning"}>{candidate.match_quality === "exact" ? "Exacto" : "Revisar"}</Badge></td><td>{formatMoney(candidate.amount_difference, selectedAccount?.currency_code)}</td><td>{candidate.match_quality === "possible" ? <Input aria-label="Justificación de diferencia" value={justifications[candidate.id] ?? ""} onChange={(event) => setJustifications({ ...justifications, [candidate.id]: event.target.value })} placeholder="Motivo obligatorio" /> : "Sin diferencia"}</td></tr>; })}</tbody></Table>}
          {data.candidates.length > 0 && <footer><span>Selecciona hasta 500 candidatos.</span><Button variant="primary" disabled={busy || !canReconcile || !selected.length || selected.some((id) => data.candidates.find((item) => item.id === id)?.match_quality === "possible" && !justifications[id]?.trim())} onClick={() => void run("confirm_bank_reconciliations", { p_company_id: companyId, p_candidate_ids: selected, p_justifications: justifications, p_client_request_id: crypto.randomUUID() }, "Conciliaciones confirmadas")}>Confirmar seleccionados</Button></footer>}
        </section>

        {data.exceptions.length > 0 && <section className="accounting-panel banking-exceptions"><header><div><h2>Excepciones por resolver</h2><p>Estos movimientos no coinciden con un cobro o pago registrado.</p></div><Badge tone="warning">{data.exceptions.length}</Badge></header><div>{data.exceptions.map((item) => <article key={item.id}><AlertTriangle size={16} /><span><strong>{exceptionLabel(item.exception_code)}</strong><small>{item.message}</small></span></article>)}</div></section>}

        {activeLinks.length > 0 && <section className="accounting-panel banking-disconnect"><header><div><h2>Desconciliación autorizada</h2><p>La evidencia original y el historial siempre se conservan.</p></div><Unlink size={18} /></header><div className="bank-active-links">{activeLinks.map((item) => <label key={item.id}><input type="checkbox" checked={selectedLinks.includes(item.active_reconciliation_id!)} onChange={() => setSelectedLinks(selectedLinks.includes(item.active_reconciliation_id!) ? selectedLinks.filter((id) => id !== item.active_reconciliation_id) : [...selectedLinks, item.active_reconciliation_id!])} /><span><strong>{item.reference}</strong><small>{formatDate(item.transaction_date)} · {formatMoney(item.amount, item.currency_code)}</small></span></label>)}</div><footer><Input aria-label="Motivo de desconciliación" value={disconnectReason} onChange={(event) => setDisconnectReason(event.target.value)} placeholder="Motivo obligatorio" /><Button variant="danger" disabled={busy || !canDisconnect || !selectedLinks.length || !disconnectReason.trim()} onClick={() => void run("disconnect_bank_reconciliations", { p_company_id: companyId, p_reconciliation_ids: selectedLinks, p_reason: disconnectReason, p_client_request_id: crypto.randomUUID() }, "Movimientos desconciliados")}>Desconciliar seleccionados</Button></footer></section>}

        {data.pagination.pages > 1 && <div className="data-pagination"><span>Página {data.pagination.page} de {data.pagination.pages}</span><div><Button variant="secondary" disabled={page <= 1} onClick={() => { const next = page - 1; setPage(next); void load(accountId, next); }}>Anterior</Button><Button variant="secondary" disabled={page >= data.pagination.pages} onClick={() => { const next = page + 1; setPage(next); void load(accountId, next); }}>Siguiente</Button></div></div>}
      </>}
    </DataState>
  </div>;
}

function BalancePart({ label, value, currency, tone, emphasized }: { label: string; value: number; currency?: string; tone?: "credit" | "debit"; emphasized?: boolean }) {
  return <span className={`${tone ? `is-${tone}` : ""} ${emphasized ? "is-emphasized" : ""}`}><small>{label}</small><strong>{formatMoney(value, currency)}</strong></span>;
}

function CompactEmpty({ icon, title, detail }: { icon: React.ReactNode; title: string; detail: string }) {
  return <div className="bank-compact-empty">{icon}<span><strong>{title}</strong><small>{detail}</small></span></div>;
}

function exceptionLabel(value: string) { return value === "NO_CANDIDATE" ? "Sin coincidencia" : value === "AMBIGUOUS_CANDIDATE" ? "Coincidencia ambigua" : value === "STATEMENT_BALANCE_MISMATCH" ? "Diferencia de saldo" : value; }
function formatDate(value: string) { const [year, month, day] = value.slice(0, 10).split("-"); return `${day}/${month}/${year}`; }
function formatMoney(value: number, currency = "MXN") { return Number(value).toLocaleString("es-MX", { style: "currency", currency, minimumFractionDigits: 2 }); }
