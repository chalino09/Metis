import { createHash, randomUUID } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import * as XLSX from "xlsx";

export const BUDGET_IMPORT_COLUMNS = [
  "name", "description", "metric_code", "period_type", "period_start", "scope_type",
  "location_code", "responsible_code", "category_code", "value", "unit_code",
] as const;

export type BudgetImportStageResult = {
  batch_id: string;
  status: string;
  row_count: number;
  valid_count: number;
  error_count: number;
  idempotent: boolean;
};

export function parseBudgetImportRows(name: string, bytes: Uint8Array) {
  if (!/\.(csv|xlsx)$/i.test(name)) return null;
  const workbook = XLSX.read(bytes, { type: "array", cellDates: false, raw: false });
  if (!workbook.SheetNames.length) return null;
  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  const rows = XLSX.utils.sheet_to_json<Record<string, unknown>>(sheet, { defval: "", raw: false });
  if (!rows.length) return null;
  const headers = Object.keys(rows[0]);
  const signatureMatches = BUDGET_IMPORT_COLUMNS.filter((column) => headers.includes(column)).length;
  if (signatureMatches < 4) return null;
  const missing = BUDGET_IMPORT_COLUMNS.filter((column) => !headers.includes(column));
  if (missing.length) throw new Error(`La plantilla de presupuestos está incompleta. Faltan: ${missing.join(", ")}.`);
  return rows.map((row) => Object.fromEntries(BUDGET_IMPORT_COLUMNS.map((column) => [column, String(row[column] ?? "").trim()])));
}

export async function detectAndStageBudgetImport(
  supabase: SupabaseClient,
  companyId: string,
  file: Pick<File, "name" | "size" | "arrayBuffer">,
) {
  if (file.size > 15 * 1024 * 1024) throw new Error("El archivo de presupuestos excede 15 MB.");
  const bytes = new Uint8Array(await file.arrayBuffer());
  const rows = parseBudgetImportRows(file.name, bytes);
  if (!rows) return null;
  if (rows.length > 50_000) throw new Error("El archivo de presupuestos excede 50,000 filas.");
  const { data, error } = await supabase.rpc("bi_stage_budget_import", {
    p_company_id: companyId,
    p_client_request_id: randomUUID(),
    p_file_name: file.name,
    p_file_sha256: createHash("sha256").update(bytes).digest("hex"),
    p_rows: rows,
  });
  if (error) throw new Error(error.message);
  return data as BudgetImportStageResult;
}
