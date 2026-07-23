import { readFile } from "node:fs/promises";
import { basename, resolve, sep } from "node:path";
import { NextRequest, NextResponse } from "next/server";
import { parseAlphaCustomerMigration } from "@/app/lib/alpha-customer-migration";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

type RepairSource = { original_name: string; file_sha256: string };

export async function POST(request: NextRequest, { params }: { params: Promise<{ batchId: string }> }) {
  try {
    const { batchId } = await params;
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const body = await request.json().catch(() => ({})) as { mode?: "preview" | "apply" };
    const { data: sourceData, error: sourceError } = await supabase.rpc("get_alpha_receivable_repair_source", { p_batch_id: batchId });
    if (sourceError) return message(sourceError.message, 403);
    const source = sourceData as RepairSource;
    const folder = process.env.ALPHA_ERP_IMPORT_DIR;
    if (!folder) return message("La fuente importada no está disponible en el servidor para recalcularla.", 409);
    const root = resolve(folder);
    const sourcePath = resolve(root, basename(source.original_name));
    if (!sourcePath.startsWith(`${root}${sep}`)) return message("La ruta del archivo fuente no es válida.", 409);
    const bytes = await readFile(sourcePath);
    const file = new File([bytes], source.original_name);
    const payload = await parseAlphaCustomerMigration([file]);
    const ledger = payload.files.find((entry) => entry.report_type === "ledger");
    if (!ledger || ledger.file_sha256 !== source.file_sha256) return message("El lis_sal conservado no coincide byte por byte con el archivo importado.", 409);
    const rpc = body.mode === "apply" ? "apply_promoted_alpha_receivable_ledger_repair" : "preview_promoted_alpha_receivable_ledger_repair";
    const { data, error } = await supabase.rpc(rpc, { p_batch_id: batchId, p_ledger_file_sha256: ledger.file_sha256, p_documents: payload.documents });
    if (error) return message(error.message, 422);
    return NextResponse.json(data, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    return message(error instanceof Error ? error.message : "No se pudo recalcular CxC desde lis_sal.", 422);
  }
}

function message(text: string, status: number) {
  return NextResponse.json({ message: text }, { status, headers: { "cache-control": "no-store" } });
}
