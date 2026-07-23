import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";

export const dynamic = "force-dynamic";

export async function GET(request: NextRequest) {
  const companyId = request.nextUrl.searchParams.get("companyId");
  const page = positiveInteger(request.nextUrl.searchParams.get("page"), 1);
  const pageSize = Math.min(positiveInteger(request.nextUrl.searchParams.get("pageSize"), 20), 100);
  if (!companyId) return NextResponse.json({ message: "Empresa requerida." }, { status: 400 });
  const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
  const { data, error } = await supabase.rpc("list_alpha_purchasing_import_batches", { p_company_id: companyId, p_page: page, p_page_size: pageSize });
  if (error) return NextResponse.json({ message: error.message }, { status: 403 });
  return NextResponse.json(data ?? { items: [], pagination: { page, page_size: pageSize, total: 0 } }, { headers: { "cache-control": "no-store" } });
}

function positiveInteger(raw: string | null, fallback: number) {
  const value = Number(raw);
  return Number.isInteger(value) && value > 0 ? value : fallback;
}
