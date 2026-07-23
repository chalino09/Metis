import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";
import { createAccountingExcel, createAccountingPdf, type AccountingReportExport } from "@/app/lib/accounting-report-export";
import { accountingReportLabel, isAccountingReportType } from "@/app/lib/accounting-report";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const PAGE_SIZE = 200;
const MAX_EXPORT_ROWS = 50_000;

export async function GET(request: NextRequest) {
  try {
    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: authData } = await supabase.auth.getUser();
    if (!authData.user) return message("Sesión no válida.", 401);
    const params = request.nextUrl.searchParams;
    const companyId = params.get("companyId") ?? "";
    const reportType = params.get("reportType") ?? "";
    const startsOn = params.get("startsOn") ?? "";
    const endsOn = params.get("endsOn") ?? "";
    const accountId = params.get("accountId") || null;
    const locationId = params.get("locationId") || null;
    const unassigned = params.get("unassigned") === "true";
    const format = params.get("format");
    if (!companyId || !isAccountingReportType(reportType) || !/^\d{4}-\d{2}-\d{2}$/.test(startsOn) || !/^\d{4}-\d{2}-\d{2}$/.test(endsOn) || startsOn > endsOn || !["xlsx", "pdf"].includes(format ?? "")) return message("Solicitud de exportación inválida.", 400);

    const [{ data: company }, { data: config }, first] = await Promise.all([
      supabase.from("companies").select("display_name").eq("id", companyId).maybeSingle(),
      supabase.from("accounting_config_versions").select("base_currency").eq("company_id", companyId).eq("status", "approved").maybeSingle(),
      reportType === "enterprise_consolidated" || locationId || unassigned
        ? supabase.rpc("list_financial_report", { p_company_id: companyId, p_report_type: reportType, p_starts_on: startsOn, p_ends_on: endsOn, p_location_id: locationId, p_unassigned: unassigned, p_page: 1, p_page_size: PAGE_SIZE })
        : supabase.rpc("list_accounting_report", { p_company_id: companyId, p_report_type: reportType, p_starts_on: startsOn, p_ends_on: endsOn, p_account_id: accountId, p_page: 1, p_page_size: PAGE_SIZE }),
    ]);
    if (first.error) throw new Error(first.error.message);
    const initial = first.data as AccountingReportExport & { page_size: number };
    if (initial.total > MAX_EXPORT_ROWS) return message(`El reporte contiene ${initial.total.toLocaleString("es-MX")} renglones. Reduce el periodo para exportar un máximo de ${MAX_EXPORT_ROWS.toLocaleString("es-MX")}.`, 413);
    const rows = [...(initial.rows ?? [])];
    const pages = Math.ceil(initial.total / PAGE_SIZE);
    for (let page = 2; page <= pages; page++) {
      const next = await (reportType === "enterprise_consolidated" || locationId || unassigned
        ? supabase.rpc("list_financial_report", { p_company_id: companyId, p_report_type: reportType, p_starts_on: startsOn, p_ends_on: endsOn, p_location_id: locationId, p_unassigned: unassigned, p_page: page, p_page_size: PAGE_SIZE })
        : supabase.rpc("list_accounting_report", { p_company_id: companyId, p_report_type: reportType, p_starts_on: startsOn, p_ends_on: endsOn, p_account_id: accountId, p_page: page, p_page_size: PAGE_SIZE }));
      if (next.error) throw new Error(next.error.message);
      rows.push(...((next.data as AccountingReportExport).rows ?? []));
    }
    const report: AccountingReportExport = { ...initial, rows, total: initial.total };
    const companyName = company?.display_name ?? "Empresa";
    const currency = config?.base_currency ?? "MXN";
    const bytes = format === "xlsx" ? await createAccountingExcel(report, companyName, currency) : await createAccountingPdf(report, companyName, currency);
    const filename = `${slug(accountingReportLabel(reportType))}_${startsOn}_${endsOn}.${format}`;
    return new NextResponse(bytes as BodyInit, { status: 200, headers: { "content-type": format === "xlsx" ? "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" : "application/pdf", "content-disposition": `attachment; filename="${filename}"`, "cache-control": "no-store, max-age=0", "x-content-type-options": "nosniff" } });
  } catch (error) {
    return message(error instanceof Error ? error.message : "No se pudo generar la descarga.", 400);
  }
}

function message(value: string, status: number) { return NextResponse.json({ message: value }, { status, headers: { "cache-control": "no-store, max-age=0" } }); }
function slug(value: string) { return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, ""); }
