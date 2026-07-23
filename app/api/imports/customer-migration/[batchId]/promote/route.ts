import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function POST(request: NextRequest, { params }: { params: Promise<{ batchId: string }> }) {
  const { batchId } = await params;
  const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
  const { data, error } = await supabase.rpc("promote_alpha_customer_migration_chunk", { p_batch_id: batchId, p_limit: 200 });
  if (error) return NextResponse.json({ message: error.message }, { status: 422, headers: { "cache-control": "no-store" } });
  const result = data as { status?: string; chunk_promoted?: number; promoted_customers?: number; blocked_customers?: number; remaining_customers?: number };
  if ((result.remaining_customers ?? 0) > 0 && (result.chunk_promoted ?? 0) === 0) {
    return NextResponse.json({ message: "La importación no avanzó; el lote permanece disponible para reintento.", ...result }, { status: 422, headers: { "cache-control": "no-store" } });
  }
  return NextResponse.json(result, { status: (result.remaining_customers ?? 0) > 0 ? 202 : 200, headers: { "cache-control": "no-store" } });
}
