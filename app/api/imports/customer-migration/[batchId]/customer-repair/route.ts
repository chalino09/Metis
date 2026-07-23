import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function POST(request: NextRequest, { params }: { params: Promise<{ batchId: string }> }) {
  try {
    const { batchId } = await params;
    const body = await request.json().catch(() => ({})) as { mode?: "preview" | "apply" };
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const rpc = body.mode === "apply"
      ? "apply_alpha_customer_identity_repair"
      : "preview_alpha_customer_identity_repair";
    const { data, error } = await supabase.rpc(rpc, { p_batch_id: batchId });
    if (error) return NextResponse.json({ message: error.message }, { status: 422, headers: { "cache-control": "no-store" } });
    return NextResponse.json(data, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    return NextResponse.json(
      { message: error instanceof Error ? error.message : "No se pudo reparar la identidad de clientes importados." },
      { status: 422, headers: { "cache-control": "no-store" } },
    );
  }
}
