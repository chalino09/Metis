import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const companyId = request.nextUrl.searchParams.get("companyId");
  if (!companyId) return NextResponse.json({ message: "Empresa requerida." }, { status: 400 });
  const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
  const { data, error } = await supabase.rpc("list_alpha_customer_identity_conflicts", { p_company_id: companyId });
  if (error) return NextResponse.json({ message: error.message }, { status: 403, headers: { "cache-control": "no-store" } });
  return NextResponse.json({ conflicts: data ?? [] }, { headers: { "cache-control": "no-store" } });
}
