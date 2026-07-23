import { createHash } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import * as XLSX from "xlsx";

export type AccountingImportType = "chart_of_accounts" | "trial_balance";
type SheetRow = Record<string, unknown>;
type Evidence = { sheet: string; cell: string; raw: string };
type Detection<T> = { status: "detected" | "missing" | "conflict"; value: T | null; evidence: Evidence[] };

const aliases = {
  code: ["codigo", "cuenta", "accountcode", "code"], name: ["nombre", "descripcion", "accountname", "name"],
  parent: ["cuentapadre", "codigopadre", "parentaccount", "parentcode"], type: ["tipo", "accounttype", "type"],
  nature: ["naturaleza", "normalbalance", "nature"], posting: ["aceptamovimientos", "afectable", "acceptsposting", "posting"],
  debit: ["debe", "debito", "cargos", "debit"], credit: ["haber", "credito", "abonos", "credit"],
} as const;

function normalized(value: string) { return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[^a-zA-Z0-9]/g, "").toLowerCase(); }
function matchingKey(row: SheetRow, keys: readonly string[]) { return Object.keys(row).find((key) => keys.includes(normalized(key))); }
function cell(row: SheetRow, keys: readonly string[]) { const key = matchingKey(row, keys); return key ? row[key] : undefined; }
function text(value: unknown) { return value == null ? "" : String(value).trim(); }
function amount(value: unknown) { const parsed = typeof value === "number" ? value : Number(text(value).replace(/[$,\s]/g, "")); return Number.isFinite(parsed) ? parsed : 0; }
function accountType(value: unknown) { const key = normalized(text(value)); return ({ activo: "asset", asset: "asset", pasivo: "liability", liability: "liability", capital: "equity", patrimonio: "equity", equity: "equity", ingresos: "revenue", ingreso: "revenue", revenue: "revenue", gastos: "expense", gasto: "expense", expense: "expense", orden: "memorandum", memorandum: "memorandum" } as Record<string, string>)[key] ?? key; }
function normalBalance(value: unknown) { const key = normalized(text(value)); return ["deudora", "deudor", "debit", "debito"].includes(key) ? "debit" : ["acreedora", "acreedor", "credit", "credito"].includes(key) ? "credit" : key; }
function bool(value: unknown) { return value == null || text(value) === "" || !["0", "no", "false", "n"].includes(normalized(text(value))); }
function address(row: number, column: number) { return XLSX.utils.encode_cell({ r: row, c: column }); }

function isoDate(value: unknown): string | null {
  if (value instanceof Date && !Number.isNaN(value.valueOf())) return value.toISOString().slice(0, 10);
  if (typeof value === "number" && value > 20000 && value < 80000) { const parts = XLSX.SSF.parse_date_code(value); return parts ? `${parts.y}-${String(parts.m).padStart(2, "0")}-${String(parts.d).padStart(2, "0")}` : null; }
  const source = text(value);
  const iso = source.match(/\b(20\d{2})[-/]([01]?\d)[-/]([0-3]?\d)\b/);
  const local = source.match(/\b([0-3]?\d)[-/]([01]?\d)[-/](20\d{2})\b/);
  const parts = iso ? [iso[1], iso[2], iso[3]] : local ? [local[3], local[2], local[1]] : null;
  if (!parts) return null;
  const result = `${parts[0]}-${parts[1].padStart(2, "0")}-${parts[2].padStart(2, "0")}`;
  return Number.isNaN(Date.parse(`${result}T00:00:00Z`)) ? null : result;
}

function detection<T>(candidates: Array<{ value: T; evidence: Evidence }>): Detection<T> {
  const unique = [...new Map(candidates.map((item) => [JSON.stringify(item.value), item.value])).values()];
  return { status: unique.length === 0 ? "missing" : unique.length === 1 ? "detected" : "conflict", value: unique.length === 1 ? unique[0] : null, evidence: candidates.map((item) => item.evidence) };
}

function inferCatalogStructure(codes: string[]): Detection<{ format: string; segments: number[] }> {
  const usable = codes.filter(Boolean); if (!usable.length) return detection([]);
  const patterns = usable.map((code) => code.split(/[-.]/).map((part) => part.length));
  const unique = [...new Set(patterns.map((parts) => parts.join("-")))];
  if (unique.length !== 1) return { status: "conflict", value: null, evidence: [] };
  const segments = patterns[0]; return { status: "detected", value: { format: segments.join("-"), segments }, evidence: [] };
}

function detectMetadata(workbook: XLSX.WorkBook, importType: AccountingImportType, dataSheet: string, codes: string[]) {
  const dates: Array<{ value: string; evidence: Evidence }> = []; const currencies: Array<{ value: string; evidence: Evidence }> = [];
  for (const sheetName of workbook.SheetNames) {
    const matrix = XLSX.utils.sheet_to_json<unknown[]>(workbook.Sheets[sheetName], { header: 1, defval: null, raw: true });
    matrix.slice(0, 80).forEach((row, rowIndex) => row.slice(0, 24).forEach((value, columnIndex) => {
      const label = normalized(text(value)); const next = row[columnIndex + 1];
      if (["fechadecorte", "corte", "asofdate"].includes(label)) { const parsed = isoDate(next); if (parsed) dates.push({ value: parsed, evidence: { sheet: sheetName, cell: address(rowIndex, columnIndex + 1), raw: text(next) } }); }
      const titled = text(value).match(/(?:balanza|saldos|corte).*?\bal\s+(.+)$/i); const titledDate = titled ? isoDate(titled[1]) : null;
      if (titledDate) dates.push({ value: titledDate, evidence: { sheet: sheetName, cell: address(rowIndex, columnIndex), raw: text(value) } });
      if (["moneda", "monedabase", "currency"].includes(label)) { const raw = normalized(text(next)); const code = raw === "pesos" || raw === "pesosmexicanos" ? "MXN" : text(next).toUpperCase(); if (/^[A-Z]{3}$/.test(code)) currencies.push({ value: code, evidence: { sheet: sheetName, cell: address(rowIndex, columnIndex + 1), raw: text(next) } }); }
    }));
  }
  const structure = importType === "chart_of_accounts" ? inferCatalogStructure(codes) : detection<{ format: string; segments: number[] }>([]);
  if (structure.value) structure.evidence = [{ sheet: dataSheet, cell: "(códigos)", raw: `${codes.length} códigos analizados` }];
  return { cutoffDate: detection(dates), currency: detection(currencies), catalogStructure: structure };
}

export function parseAccountingWorkbook(buffer: Buffer) {
  const workbook = XLSX.read(buffer, { type: "buffer", cellDates: true });
  for (const sheetName of workbook.SheetNames) {
    const matrix = XLSX.utils.sheet_to_json<unknown[]>(workbook.Sheets[sheetName], { header: 1, defval: null, raw: true });
    for (let headerIndex = 0; headerIndex < Math.min(matrix.length, 40); headerIndex += 1) {
      const headers = matrix[headerIndex].map(text); const sample = Object.fromEntries(headers.map((header, index) => [header || `_${index}`, null]));
      const hasCode = Boolean(matchingKey(sample, aliases.code)); const hasDebit = Boolean(matchingKey(sample, aliases.debit)); const hasCredit = Boolean(matchingKey(sample, aliases.credit));
      const hasName = Boolean(matchingKey(sample, aliases.name)); const hasType = Boolean(matchingKey(sample, aliases.type)); const hasNature = Boolean(matchingKey(sample, aliases.nature));
      const importType: AccountingImportType | null = hasCode && hasDebit && hasCredit ? "trial_balance" : hasCode && hasName && hasType && hasNature ? "chart_of_accounts" : null;
      if (!importType) continue;
      const source = matrix.slice(headerIndex + 1).map((values) => Object.fromEntries(headers.map((header, index) => [header || `_${index}`, values[index]]))).filter((row) => text(cell(row, aliases.code)));
      const rows = source.map((row, index) => ({ row_number: headerIndex + index + 2, external_account_code: text(cell(row, aliases.code)), account_name: text(cell(row, aliases.name)) || null, parent_external_code: text(cell(row, aliases.parent)) || null, account_type: importType === "chart_of_accounts" ? accountType(cell(row, aliases.type)) : null, normal_balance: importType === "chart_of_accounts" ? normalBalance(cell(row, aliases.nature)) : null, accepts_posting: importType === "chart_of_accounts" ? bool(cell(row, aliases.posting)) : null, debit: importType === "trial_balance" ? amount(cell(row, aliases.debit)) : 0, credit: importType === "trial_balance" ? amount(cell(row, aliases.credit)) : 0, raw_data: row }));
      return { importType, sheetName, rows, metadata: detectMetadata(workbook, importType, sheetName, rows.map((row) => row.external_account_code)) };
    }
  }
  return null;
}

export async function detectAndStageAccountingUpload(supabase: SupabaseClient, companyId: string, file: Pick<File, "name" | "arrayBuffer">) {
  const buffer = Buffer.from(await file.arrayBuffer()); const parsed = parseAccountingWorkbook(buffer); if (!parsed) return null;
  const hash = createHash("sha256").update(buffer).digest("hex");
  const metadataIssues = Object.entries(parsed.metadata).filter(([field, value]) => value.status !== "detected" && !(parsed.importType === "trial_balance" && field === "catalogStructure")).map(([field, value]) => ({ field, status: value.status, evidence: value.evidence }));
  const { data: created, error: createError } = await supabase.rpc("create_accounting_import_staging", { p_company_id: companyId, p_import_type: parsed.importType, p_cutoff_date: parsed.metadata.cutoffDate.value, p_currency_code: parsed.metadata.currency.value, p_catalog_structure: parsed.metadata.catalogStructure.value ?? {}, p_detection_evidence: parsed.metadata, p_metadata_issues: metadataIssues, p_original_name: file.name, p_content_sha256: hash });
  if (createError) throw new Error(createError.message); const batchId = String((created as { id: string }).id);
  if (!(created as { idempotent?: boolean }).idempotent) for (let index = 0; index < parsed.rows.length; index += 2000) { const { error } = await supabase.rpc("stage_accounting_import_rows", { p_batch_id: batchId, p_rows: parsed.rows.slice(index, index + 2000) }); if (error) throw new Error(error.message); }
  const { data, error } = await supabase.rpc("finalize_accounting_staging", { p_batch_id: batchId, p_source_system: "external" }); if (error) throw new Error(error.message);
  const result = data as { status: string }; const needsReview = result.status === "awaiting_metadata" || result.status === "awaiting_configuration";
  return { kind: parsed.importType, label: parsed.importType === "chart_of_accounts" ? "Catálogo contable" : "Balanza de apertura", status: result.status, batch_id: batchId, message: needsReview ? "Archivo contable guardado. Revisa la detección automática en Contabilidad → Configuración." : result.status === "staged" ? "Archivo contable detectado y validado automáticamente." : "Archivo contable detectado con excepciones por revisar." };
}
