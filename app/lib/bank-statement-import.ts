import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import * as XLSX from "xlsx";

type Row = Record<string, unknown>;
type Evidence = { sheet: string; cell: string; raw: string };

const aliases = {
  date: ["fecha", "fechamovimiento", "transactiondate", "date"],
  valueDate: ["fechavalor", "valuedate"],
  reference: ["referencia", "reference", "folio", "movimiento"],
  description: ["descripcion", "concepto", "description", "memo", "detalle"],
  credit: ["abono", "abonos", "credito", "credit", "deposito", "deposit"],
  debit: ["cargo", "cargos", "debito", "debit", "retiro", "withdrawal"],
  balance: ["saldo", "saldodisponible", "balance", "runningbalance"],
} as const;

function normalized(value: unknown) { return String(value ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-zA-Z0-9]/g, "").toLowerCase(); }
function text(value: unknown) { return value == null ? "" : String(value).trim(); }
function key(row: Row, candidates: readonly string[]) { return Object.keys(row).find((item) => candidates.includes(normalized(item))); }
function cell(row: Row, candidates: readonly string[]) { const found = key(row, candidates); return found ? row[found] : undefined; }
function amount(value: unknown) { if (value == null || text(value) === "") return 0; const result = typeof value === "number" ? value : Number(text(value).replace(/[\s$,]/g, "").replace(/^\((.*)\)$/, "-$1")); return Number.isFinite(result) ? Math.abs(result) : 0; }
function address(row: number, column: number) { return XLSX.utils.encode_cell({ r: row, c: column }); }
function isoDate(value: unknown): string | null {
  if (value instanceof Date && !Number.isNaN(value.valueOf())) return value.toISOString().slice(0, 10);
  if (typeof value === "number" && value > 20000 && value < 80000) { const parsed = XLSX.SSF.parse_date_code(value); return parsed ? `${parsed.y}-${String(parsed.m).padStart(2, "0")}-${String(parsed.d).padStart(2, "0")}` : null; }
  const source = text(value); const iso = source.match(/\b(20\d{2})[-/]([01]?\d)[-/]([0-3]?\d)\b/); const local = source.match(/\b([0-3]?\d)[-/]([01]?\d)[-/](20\d{2})\b/); const parts = iso ? [iso[1], iso[2], iso[3]] : local ? [local[3], local[2], local[1]] : null;
  if (!parts) return null; const result = `${parts[0]}-${parts[1].padStart(2, "0")}-${parts[2].padStart(2, "0")}`; return Number.isNaN(Date.parse(`${result}T00:00:00Z`)) ? null : result;
}

function detected<T>(items: Array<{ value: T; evidence: Evidence }>) {
  const unique = [...new Map(items.map((item) => [JSON.stringify(item.value), item.value])).values()];
  return { status: unique.length === 1 ? "detected" : unique.length ? "conflict" : "missing", value: unique.length === 1 ? unique[0] : null, evidence: items.map((item) => item.evidence) };
}

export function parseBankStatement(buffer: Buffer) {
  const workbook = XLSX.read(buffer, { type: "buffer", cellDates: true, codepage: 65001 });
  const currencies: Array<{ value: string; evidence: Evidence }> = []; const endings: Array<{ value: string; evidence: Evidence }> = [];
  const starts: Array<{ value: string; evidence: Evidence }> = []; const ends: Array<{ value: string; evidence: Evidence }> = [];
  const openings: Array<{ value: number; evidence: Evidence }> = []; const closings: Array<{ value: number; evidence: Evidence }> = [];
  for (const sheetName of workbook.SheetNames) {
    const matrix = XLSX.utils.sheet_to_json<unknown[]>(workbook.Sheets[sheetName], { header: 1, defval: null, raw: true });
    matrix.slice(0, 60).forEach((row, r) => row.slice(0, 20).forEach((value, c) => {
      const label = normalized(value); const next = row[c + 1]; const evidence = { sheet: sheetName, cell: address(r, c + 1), raw: text(next) };
      if (["moneda", "currency"].includes(label) && /^[A-Z]{3}$/.test(text(next).toUpperCase())) currencies.push({ value: text(next).toUpperCase(), evidence });
      if (["terminacioncuenta", "ultimos4", "accountlast4", "accountending"].includes(label) && /^[0-9A-Z]{4}$/.test(text(next).toUpperCase())) endings.push({ value: text(next).toUpperCase(), evidence });
      if (["periodoinicio", "fechainicial", "periodstart", "fromdate"].includes(label)) { const date = isoDate(next); if (date) starts.push({ value: date, evidence }); }
      if (["periodofin", "fechafinal", "periodend", "todate"].includes(label)) { const date = isoDate(next); if (date) ends.push({ value: date, evidence }); }
      if (["saldoinicial", "openingbalance"].includes(label) && text(next) !== "") openings.push({ value: typeof next === "number" ? next : Number(text(next).replace(/[\s$,]/g, "")), evidence });
      if (["saldofinal", "closingbalance"].includes(label) && text(next) !== "") closings.push({ value: typeof next === "number" ? next : Number(text(next).replace(/[\s$,]/g, "")), evidence });
    }));
  }
  for (const sheetName of workbook.SheetNames) {
    const matrix = XLSX.utils.sheet_to_json<unknown[]>(workbook.Sheets[sheetName], { header: 1, defval: null, raw: true });
    for (let headerIndex = 0; headerIndex < Math.min(matrix.length, 60); headerIndex += 1) {
      const headers = matrix[headerIndex].map(text); const sample = Object.fromEntries(headers.map((header, index) => [header || `_${index}`, null]));
      if (!key(sample, aliases.date) || !key(sample, aliases.reference) || (!key(sample, aliases.credit) && !key(sample, aliases.debit))) continue;
      const source = matrix.slice(headerIndex + 1).map((values) => Object.fromEntries(headers.map((header, index) => [header || `_${index}`, values[index]]))).filter((row) => isoDate(cell(row, aliases.date)) || text(cell(row, aliases.reference)));
      const rows = source.map((row, index) => {
        const transactionDate = isoDate(cell(row, aliases.date)); const reference = text(cell(row, aliases.reference)); const credit = amount(cell(row, aliases.credit)); const debit = amount(cell(row, aliases.debit));
        const canonical = { transaction_date: transactionDate, value_date: isoDate(cell(row, aliases.valueDate)), reference, description: text(cell(row, aliases.description)), credit, debit, running_balance: text(cell(row, aliases.balance)) === "" ? null : Number(text(cell(row, aliases.balance)).replace(/[\s$,]/g, "")) };
        return { row_number: headerIndex + index + 2, ...canonical, row_sha256: createHash("sha256").update(JSON.stringify(canonical)).digest("hex"), raw_data: row };
      });
      const rowDates = rows.map((row) => row.transaction_date).filter((value): value is string => Boolean(value)).sort();
      const metadata = { currency: detected(currencies), accountLast4: detected(endings), periodStart: starts.length ? detected(starts) : detected(rowDates.length ? [{ value: rowDates[0], evidence: { sheet: sheetName, cell: "(movimientos)", raw: "Primera fecha" } }] : []), periodEnd: ends.length ? detected(ends) : detected(rowDates.length ? [{ value: rowDates.at(-1)!, evidence: { sheet: sheetName, cell: "(movimientos)", raw: "Última fecha" } }] : []), openingBalance: detected(openings.filter((item) => Number.isFinite(item.value))), closingBalance: detected(closings.filter((item) => Number.isFinite(item.value))) };
      return { sheetName, rows, metadata };
    }
  }
  return null;
}

export async function detectAndStageBankStatement(supabase: SupabaseClient, companyId: string, file: Pick<File, "name" | "arrayBuffer">) {
  const buffer = Buffer.from(await file.arrayBuffer()); const parsed = parseBankStatement(buffer); if (!parsed) return null;
  const missing = Object.entries(parsed.metadata).filter(([, item]) => item.status !== "detected");
  if (missing.length) throw new Error(`El estado parece bancario, pero no pudo detectar de forma única: ${missing.map(([field]) => field).join(", ")}. Usa la plantilla neutral sin seleccionar un tipo de archivo.`);
  const metadata = parsed.metadata; const hash = createHash("sha256").update(buffer).digest("hex");
  const { data: created, error: createError } = await supabase.rpc("create_bank_statement_staging", { p_company_id: companyId, p_account_last4: metadata.accountLast4.value, p_currency_code: metadata.currency.value, p_original_name: file.name, p_content_sha256: hash, p_period_start: metadata.periodStart.value, p_period_end: metadata.periodEnd.value, p_opening_balance: metadata.openingBalance.value, p_closing_balance: metadata.closingBalance.value, p_detection_evidence: metadata });
  if (createError) throw new Error(createError.message); const batch = created as { id: string; idempotent?: boolean; status?: string };
  if (batch.idempotent) return { kind: "bank_statement", label: "Estado bancario", status: "duplicate", batch_id: batch.id, message: "Este archivo ya fue recibido para la misma cuenta; no se duplicó." };
  for (let index = 0; index < parsed.rows.length; index += 2000) { const { error } = await supabase.rpc("stage_bank_statement_rows", { p_batch_id: batch.id, p_rows: parsed.rows.slice(index, index + 2000) }); if (error) throw new Error(error.message); }
  const { data, error } = await supabase.rpc("finalize_bank_statement_staging", { p_batch_id: batch.id }); if (error) throw new Error(error.message); const result = data as { status: string; balance_difference?: number };
  return { kind: "bank_statement", label: "Estado bancario", status: result.status === "ready" ? "staged" : "validation_failed", batch_id: batch.id, message: result.status === "ready" ? `${parsed.rows.length} movimientos preparados; el saldo está explicado.` : `El lote quedó conservado con diferencias. Diferencia de saldo: ${result.balance_difference ?? 0}.` };
}
