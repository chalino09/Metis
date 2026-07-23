import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const dynamic = "force-dynamic";

export async function POST(request: NextRequest, { params }: { params: Promise<{ batchId: string; externalCode: string }> }) {
  try {
    const { batchId, externalCode } = await params;
    const body = await request.json() as { decision?: string; targetCustomerId?: string | null; reason?: string };
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data, error } = await supabase.rpc("decide_alpha_customer_identity_conflict", {
      p_batch_id: batchId,
      p_customer_external_code: externalCode,
      p_decision: body.decision ?? "",
      p_target_customer_id: body.targetCustomerId ?? null,
      p_reason: body.reason ?? "",
    });
    if (error) return NextResponse.json({ message: error.message }, { status: 422, headers: { "cache-control": "no-store" } });
    return NextResponse.json(data, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    return NextResponse.json({ message: error instanceof Error ? error.message : "No se pudo registrar la decisión." }, { status: 422, headers: { "cache-control": "no-store" } });
  }
}
