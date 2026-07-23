import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: NextRequest, context: { params: Promise<{ batchId: string }> }) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData, error: authError } = await supabase.auth.getUser();
    if (authError || !authData.user) return response("Sesión no válida.", 401);

    const { batchId } = await context.params;
    const page = positiveInteger(request.nextUrl.searchParams.get("page"), 1);
    const pageSize = Math.min(positiveInteger(request.nextUrl.searchParams.get("pageSize"), 50), 200);
    const status = request.nextUrl.searchParams.get("status") || null;
    const errorCode = request.nextUrl.searchParams.get("errorCode") || null;
    const { data, error } = await supabase.rpc("get_import_staging_preview", {
      p_import_batch_id: batchId,
      p_page: page,
      p_page_size: pageSize,
      p_status: status,
      p_error_code: errorCode,
    });
    if (error) return response(error.message || "No se pudo recuperar el preview.", 422);
    const preview = data as { batch?: { import_type?: string } };
    if (["prices", "costs"].includes(preview.batch?.import_type ?? "")) {
      const { data: requirements, error: requirementsError } = await supabase.rpc("get_commercial_import_requirements", { p_import_batch_id: batchId });
      if (requirementsError) return response(requirementsError.message || "No se pudo recuperar la revisión comercial.", 422);
      return NextResponse.json({ ...preview, commercial_requirements: requirements }, { headers: { "cache-control": "no-store" } });
    }
    if (preview.batch?.import_type === "products") {
      const { data: taxSummary, error: taxSummaryError } = await supabase.rpc("get_staged_product_tax_summary", { p_import_batch_id: batchId });
      if (taxSummaryError) return response(taxSummaryError.message || "No se pudo recuperar el resumen fiscal.", 422);
      return NextResponse.json({ ...preview, tax_summary: taxSummary }, { headers: { "cache-control": "no-store" } });
    }
    return NextResponse.json(preview, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return response("Sesión no válida.", 401);
    return response("No se pudo recuperar el preview persistente.", 422);
  }
}

function positiveInteger(value: string | null, fallback: number) {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function response(message: string, status: number) {
  return NextResponse.json({ message }, { status, headers: { "cache-control": "no-store" } });
}
