import { lstat, readFile, readdir, stat } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { NextRequest, NextResponse } from "next/server";
import { parseAlphaWorkbook } from "@/app/lib/alpha";
import { parseAlphaCustomerMigration } from "@/app/lib/alpha-customer-migration";
import { stagePurchasingAlphaUploads } from "@/app/lib/import-upload-staging";
import { buildStagingPayload } from "@/app/lib/import-staging";
import { validateReferencedProducts } from "@/app/lib/import-validation";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";
import type { ImportKind, ParsedAlphaFile } from "@/app/lib/types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

type FolderMode = "catalog" | "commercial" | "inventory" | "customers" | "purchasing";
type Candidate = { fileName: string; modifiedAt: number; parsed: ParsedAlphaFile };
// Historical sales evidence is deliberately accepted only through the visible
// Centro de Migración uploader; the development folder utility must not stage
// it implicitly.
type SupportedImportKind = Exclude<ImportKind, "unsupported" | "sales">;

const families: Record<SupportedImportKind, RegExp> = {
  products: /^cata_prd_.+\.xlsx?$/i,
  inventory: /^reexic2_.+\.xlsx?$/i,
  prices: /^rprecprd_.+\.xlsx?$/i,
  costs: /^rcostprd_.+\.xlsx?$/i,
};

/** Development-only folder reader. Files are read into memory and never copied,
 * converted, moved, opened in a spreadsheet app, or modified. */
export async function GET() {
  return NextResponse.json({ available: isAvailable() }, { headers: { "cache-control": "no-store" } });
}

export async function POST(request: NextRequest) {
  if (!isAvailable()) return response({ message: "La carpeta de importación no está configurada en este entorno." }, 404);
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return response({ message: "Sesión no válida." }, 401);
    const body = await request.json() as { companyId?: string; mode?: FolderMode };
    if (!body.companyId || !isMode(body.mode)) return response({ message: "Solicitud de importación local inválida." }, 400);
    if (body.mode === "customers") return stageCustomerMigrationFromFolder(body.companyId, supabase);
    if (body.mode === "purchasing") return stagePurchasingMigrationFromFolder(body.companyId, supabase);

    const candidates = await readCandidates(body.mode);
    if (!candidates.length) return response({ message: "No se encontraron archivos compatibles para esta operación." }, 404);

    const results = [] as Array<{ fileName: string; importType: ImportKind; status: string; batchId?: string; message?: string }>;
    for (const candidate of candidates) {
      const additionalIssues = await validateReferencedProducts(candidate.parsed, body.companyId, supabase);
      const payload = buildStagingPayload(candidate.parsed, additionalIssues);
      const { data, error } = await supabase.rpc("stage_alpha_import", {
        p_company_id: body.companyId,
        p_import_type: candidate.parsed.importKind,
        p_source: "local_development",
        p_file_name: candidate.parsed.fileName,
        p_file_type: extension(candidate.parsed.fileName),
        p_file_sha256: candidate.parsed.fileHash,
        p_snapshot_date: candidate.parsed.snapshotDate,
        p_rows: payload.rows,
        p_errors: payload.errors,
      });
      if (error) throw error;
      const staged = data as { status: string; batch_id?: string; message?: string };
      results.push({ fileName: candidate.fileName, importType: candidate.parsed.importKind, status: staged.status, batchId: staged.batch_id, message: staged.message });
    }
    return NextResponse.json({ results }, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return response({ message: "Sesión no válida." }, 401);
    return response({ message: "No se pudo preparar la importación desde la carpeta configurada." }, 422);
  }
}

function isAvailable() {
  return process.env.NODE_ENV === "development" && Boolean(process.env.ALPHA_ERP_IMPORT_DIR);
}

function isMode(value: unknown): value is FolderMode {
  return value === "catalog" || value === "commercial" || value === "inventory" || value === "customers" || value === "purchasing";
}

async function readCandidates(mode: Exclude<FolderMode, "customers">): Promise<Candidate[]> {
  const directory = process.env.ALPHA_ERP_IMPORT_DIR!;
  const wanted: SupportedImportKind[] = mode === "catalog" ? ["products"] : mode === "commercial" ? ["prices", "costs"] : ["inventory"];
  const entries = await readdir(directory, { withFileTypes: true });
  const byType = new Map<SupportedImportKind, Candidate[]>();

  for (const entry of entries) {
    if (!entry.isFile()) continue;
    const importType = wanted.find((kind) => families[kind].test(entry.name));
    if (!importType) continue;
    const path = resolve(directory, entry.name);
    const fileInfo = await lstat(path);
    if (!fileInfo.isFile() || fileInfo.isSymbolicLink() || basename(path) !== entry.name) continue;
    const bytes = await readFile(path);
    const parsed = await parseAlphaWorkbook(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), entry.name, "local_development");
    const metadata = await stat(path);
    const list = byType.get(importType) ?? [];
    list.push({ fileName: entry.name, modifiedAt: metadata.mtimeMs, parsed });
    byType.set(importType, list);
  }

  return wanted.map((kind) => selectSource(kind, byType.get(kind) ?? [])).filter((candidate): candidate is Candidate => Boolean(candidate));
}

async function stageCustomerMigrationFromFolder(companyId: string, supabase: ReturnType<typeof getRequestSupabaseClient>) {
  const directory = process.env.ALPHA_ERP_IMPORT_DIR!;
  const entries = await readdir(directory, { withFileTypes: true });
  const allowed = /^(?:cata_cte|cat_ctee|lis_sal|cob_cte)_.+\.xlsx?$/i;
  const files: File[] = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (!entry.isFile() || !allowed.test(entry.name)) continue;
    const path = resolve(directory, entry.name);
    const fileInfo = await lstat(path);
    if (!fileInfo.isFile() || fileInfo.isSymbolicLink() || basename(path) !== entry.name) continue;
    const bytes = await readFile(path);
    files.push(new File([bytes], entry.name));
  }
  if (!files.length) return response({ message: "No se encontraron archivos de Clientes/CxC en la carpeta de importación." }, 404);

  let startedBatchId: string | null = null;
  try {
    const payload = await parseAlphaCustomerMigration(files);
    const { data: begun, error: beginError } = await supabase.rpc("begin_alpha_customer_migration", {
      p_company_id: companyId,
      p_cutoff_date: payload.cutoffDate,
      p_content_sha256: payload.contentHash,
      p_files: payload.files,
    });
    if (beginError) throw beginError;
    const begin = begun as { status: string; batch_id: string };
    if (begin.status === "duplicate") return NextResponse.json(begin, { headers: { "cache-control": "no-store" } });
    startedBatchId = begin.batch_id;
    for (const [kind, rows] of [["customers", payload.customers], ["documents", payload.documents], ["collections", payload.collections]] as const) {
      for (let index = 0; index < rows.length; index += 400) {
        const { error } = await supabase.rpc("stage_alpha_customer_migration_rows", { p_batch_id: begin.batch_id, p_kind: kind, p_rows: rows.slice(index, index + 400) });
        if (error) throw new Error(`No se pudo guardar el bloque ${kind}: ${error.message}`);
      }
    }
    const operation = payload.isComplete ? "reconcile_alpha_customer_migration" : "finish_alpha_customer_migration_staging";
    const { data, error } = await supabase.rpc(operation, { p_batch_id: begin.batch_id });
    if (error) throw error;
    return NextResponse.json(data, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    const text = error instanceof Error ? error.message : "No se pudo recuperar Clientes/CxC desde la carpeta de importación.";
    if (startedBatchId) await supabase.rpc("fail_alpha_customer_migration", { p_batch_id: startedBatchId, p_reason: text });
    return response({ message: text }, 422);
  }
}

async function stagePurchasingMigrationFromFolder(companyId: string, supabase: ReturnType<typeof getRequestSupabaseClient>) {
  const directory = process.env.ALPHA_ERP_IMPORT_DIR!;
  const entries = await readdir(directory, { withFileTypes: true });
  const allowed = /^(?:cata_prv|rpcon2|lfchvenc|pag_det)_.+\.xlsx?$/i;
  const files: File[] = [];
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (!entry.isFile() || !allowed.test(entry.name)) continue;
    const path = resolve(directory, entry.name);
    const fileInfo = await lstat(path);
    if (!fileInfo.isFile() || fileInfo.isSymbolicLink() || basename(path) !== entry.name) continue;
    files.push(new File([await readFile(path)], entry.name));
  }
  if (!files.length) return response({ message: "No se encontraron archivos de Compras/CxP en la carpeta de importación." }, 404);
  try {
    const result = await stagePurchasingAlphaUploads(supabase, companyId, files);
    return NextResponse.json(result, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    return response({ message: error instanceof Error ? error.message : "No se pudo preparar Compras/CxP desde la carpeta de importación." }, 422);
  }
}

function selectSource(kind: SupportedImportKind, candidates: Candidate[]) {
  return [...candidates].sort((left, right) => {
    const effectiveDate = (candidate: Candidate) => candidate.parsed.snapshotDate ? new Date(candidate.parsed.snapshotDate).getTime() : 0;
    const count = (candidate: Candidate) => kind === "products" ? candidate.parsed.products.length : kind === "inventory" ? candidate.parsed.inventory.length : kind === "prices" ? candidate.parsed.prices.length : candidate.parsed.costs.length;
    return effectiveDate(right) - effectiveDate(left) || count(right) - count(left) || right.modifiedAt - left.modifiedAt || right.fileName.localeCompare(left.fileName);
  })[0];
}

function extension(fileName: string) {
  return fileName.split(".").pop()?.toLowerCase() ?? "xls";
}

function response(payload: { message: string }, status: number) {
  return NextResponse.json(payload, { status, headers: { "cache-control": "no-store" } });
}
