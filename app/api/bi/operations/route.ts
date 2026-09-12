import { NextRequest, NextResponse } from "next/server";
import { getRequestSupabaseClient } from "@/app/lib/supabase-server";
import {
  mergeLocations,
  metricPayload,
  type BiOperationalItem,
  type BiSummaryLocation,
  type BiSummaryMetric,
} from "@/app/lib/bi-operations";

export const dynamic = "force-dynamic";

const MAX_PAGE_SIZE = 50;
const MAX_PROFITABILITY_PAGE_SIZE = 10;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

type RpcResult = { data: unknown; error: { message: string } | null };

type OperationalTable = {
  items?: BiOperationalItem[];
  pagination?: Record<string, unknown>;
  scope?: Record<string, unknown>;
  partial?: boolean;
};

type ExecutiveSummary = {
  metrics?: BiSummaryMetric[];
  locations?: BiSummaryLocation[];
  currency_code?: string | null;
  period?: Record<string, unknown>;
  updated_at?: string;
};
type SummaryMetric = NonNullable<ExecutiveSummary["metrics"]>[number];

type ReplenishmentQueue = {
  total?: number;
  status_counts?: Record<string, number>;
  items?: unknown[];
};

type InventoryBalances = {
  items?: unknown[];
  total?: number;
  page?: number;
  page_size?: number;
};

type DependencyNetwork = {
  nodes?: Array<{
    type?: string;
    entity_id?: string;
    label?: string;
    secondary?: string | null;
    metrics?: { purchases?: number | null; sales?: number | null; inventory?: number | null; connections?: number | null };
  }>;
  truncated?: boolean;
  limits?: Record<string, unknown>;
  methodology?: Record<string, unknown>;
  period?: Record<string, unknown>;
};

export async function GET(request: NextRequest) {
  const generatedAt = new Date().toISOString();

  try {
    const params = request.nextUrl.searchParams;
    const companyId = params.get("company_id")?.trim() ?? "";
    const dateFrom = params.get("date_from")?.trim() ?? "";
    const dateTo = params.get("date_to")?.trim() ?? "";
    const locationId = emptyToNull(params.get("location_id"));
    const page = boundedInteger(params.get("page"), 1, 1, 100_000);
    const pageSize = boundedInteger(params.get("page_size"), 25, 1, MAX_PAGE_SIZE);
    const profitabilityPageSize = boundedInteger(params.get("profitability_page_size"), 5, 1, MAX_PROFITABILITY_PAGE_SIZE);
    const comparisonMode = emptyToNull(params.get("comparison_mode")) ?? "previous_period";

    if (!UUID_RE.test(companyId)) return response({ error: "company_id inválido." }, 400);
    if (!validDate(dateFrom) || !validDate(dateTo) || dateFrom > dateTo) {
      return response({ error: "date_from y date_to deben ser fechas válidas." }, 400);
    }
    if (daysBetween(dateFrom, dateTo) > 365) {
      return response({ error: "El periodo admite hasta 366 días." }, 400);
    }
    if (locationId && !UUID_RE.test(locationId)) return response({ error: "location_id inválido." }, 400);
    if (comparisonMode !== "previous_period" && comparisonMode !== "previous_year") {
      return response({ error: "comparison_mode inválido." }, 400);
    }
    if (params.has("product_id") || params.has("customer_id") || params.has("supplier_id")) {
      return response({ error: "El resumen operativo sólo admite alcance de empresa o sucursal." }, 400);
    }

    const supabase = getRequestSupabaseClient(request.headers.get("authorization"));
    const { data: auth } = await supabase.auth.getUser();
    if (!auth.user) return response({ error: "Sesión no válida." }, 401);

    const [summaryResult, salesResult, marginResult, inventoryResult, inventoryBalancesResult, networkResult] = await Promise.all([
      supabase.rpc("bi_get_executive_summary_compared", {
        p_company_id: companyId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
        p_location_id: locationId,
        p_product_id: null,
        p_customer_id: null,
        p_supplier_id: null,
        p_comparison_mode: comparisonMode,
      }),
      supabase.rpc("bi_get_operational_table", {
        p_company_id: companyId,
        p_metric_code: "net_sales",
        p_dimension: "location",
        p_date_from: dateFrom,
        p_date_to: dateTo,
        p_location_id: locationId,
        p_product_id: null,
        p_customer_id: null,
        p_supplier_id: null,
        p_search: null,
        // Keep membership stable across both metric tables; net sales owns
        // the requested page and gross margin is joined by location id.
        p_sort_by: "entity",
        p_sort_direction: "asc",
        p_page: page,
        p_page_size: pageSize,
        p_comparison_mode: comparisonMode,
      }),
      supabase.rpc("bi_get_operational_table", {
        p_company_id: companyId,
        p_metric_code: "gross_margin",
        p_dimension: "location",
        p_date_from: dateFrom,
        p_date_to: dateTo,
        p_location_id: locationId,
        p_product_id: null,
        p_customer_id: null,
        p_supplier_id: null,
        p_search: null,
        p_sort_by: "entity",
        p_sort_direction: "asc",
        p_page: page,
        p_page_size: pageSize,
        p_comparison_mode: comparisonMode,
      }),
      supabase.rpc("list_inventory_replenishment_work_queue", {
        p_company_id: companyId,
        p_location_id: locationId,
        p_query: null,
        p_below_minimum_only: true,
        p_work_status: "all",
        p_page: 1,
        p_page_size: 5,
      }),
      supabase.rpc("search_inventory_balances", {
        p_company_id: companyId,
        p_location_id: locationId,
        p_query: null,
        // Inventory is a current operational snapshot, independent from the
        // historical location table page.
        p_page: 1,
        p_page_size: 5,
      }),
      supabase.rpc("bi_dependency_network_query", {
        p_company_id: companyId,
        p_date_from: dateFrom,
        p_date_to: dateTo,
        p_location_id: locationId,
        p_category_id: null,
        p_supplier_id: null,
        p_product_id: null,
        p_relation_types: ["supplier_product"],
        p_operational_state: null,
        p_concentration_level: null,
        p_size_metric: "purchases",
        p_color_metric: "node_type",
        p_edge_metric: "amount",
        p_perspective: "supplier_dependency",
        p_anchor_type: null,
        p_anchor_id: null,
        p_expansion_levels: 0,
        p_node_limit: 50,
        p_edge_limit: 100,
      }),
    ]);

    if (summaryResult.error) return response({ error: normalize(summaryResult.error.message) }, statusFor(summaryResult.error.message));

    const summary = (summaryResult.data ?? {}) as ExecutiveSummary;
    const inventoryToday = new Date().toISOString().slice(0, 10);
    const inventorySummaryResult: RpcResult = dateTo === inventoryToday
      ? summaryResult
      : await supabase.rpc("bi_get_executive_summary_compared", {
          p_company_id: companyId,
          p_date_from: inventoryToday,
          p_date_to: inventoryToday,
          p_location_id: locationId,
          p_product_id: null,
          p_customer_id: null,
          p_supplier_id: null,
          p_comparison_mode: comparisonMode,
        });
    const inventorySummary = optionalData(inventorySummaryResult) as ExecutiveSummary | null;
    const sales = optionalData(salesResult) as OperationalTable | null;
    const margin = optionalData(marginResult) as OperationalTable | null;
    const inventoryQueue = optionalData(inventoryResult) as ReplenishmentQueue | null;
    const inventoryBalances = optionalData(inventoryBalancesResult) as InventoryBalances | null;
    const network = optionalData(networkResult) as DependencyNetwork | null;
    const metric = (code: string) => summary.metrics?.find((item) => item.code === code) ?? null;

    const locations = mergeLocations(summary.locations ?? [], sales?.items ?? [], margin?.items ?? []);
    const profitabilityIds = locations
      .slice(0, profitabilityPageSize)
      .map((location) => String(location.location_id ?? ""))
      .filter((value) => UUID_RE.test(value));
    const profitabilityResults = await Promise.all(
      profitabilityIds.map(async (locationIdForProfitability) => ({
        locationId: locationIdForProfitability,
        result: await supabase.rpc("get_location_profitability", {
          p_company_id: companyId,
          p_location_id: locationIdForProfitability,
          p_date_from: dateFrom,
          p_date_to: dateTo,
        }),
      })),
    );
    const profitabilityByLocation = new Map(profitabilityResults.map(({ locationId: id, result }) => [
      id,
      result.error
        ? { available: false, reason: normalize(result.error.message) }
        : { available: true, data: result.data },
    ]));
    for (const location of locations) {
      const id = String(location.location_id ?? "");
      location.profitability = profitabilityByLocation.get(id) ?? {
        available: false,
        reason: "La rentabilidad por sucursal está limitada a la primera página operativa.",
      };
    }
    const inventoryMetric = inventorySummary?.metrics?.find((item) => item.code === "inventory_value") ?? null;
    const receivablesMetric = metric("receivables");
    const overdueReceivablesMetric = metric("overdue_receivables");

    return response({
      contract: {
        name: "satrapy.bi.operations",
        version: "1.0.0",
        read_only: true,
        generated_at: generatedAt,
      },
      period: {
        from: dateFrom,
        to: dateTo,
        days: daysBetween(dateFrom, dateTo) + 1,
        comparison: comparisonMode,
        comparison_from: summary.period?.previous_from ?? null,
        comparison_to: summary.period?.previous_to ?? null,
      },
      currency_code: summary.currency_code ?? null,
      locations: {
        items: locations,
        pagination: sales?.pagination ?? margin?.pagination ?? { page, page_size: pageSize, total: locations.length },
        partial: Boolean(sales?.partial || margin?.partial),
        note: "Las sucursales sin ventas en el periodo pueden no aparecer en las tablas operativas; usa el módulo de ubicaciones para el catálogo completo.",
      },
      inventory: {
        valuation_as_of: generatedAt,
        valuation_as_of_kind: "current_at_query_time_from_bi_summary",
        valuation_source_period: { from: inventoryToday, to: inventoryToday },
        replenishment_as_of: generatedAt,
        replenishment_as_of_kind: "current_at_query_time",
        value: metricPayload(inventoryMetric),
        positions: inventoryBalances
          ? {
              items: inventoryBalances.items ?? [],
              pagination: {
                page: inventoryBalances.page ?? 1,
                page_size: inventoryBalances.page_size ?? 5,
                total: inventoryBalances.total ?? 0,
              },
              source_rpc: "search_inventory_balances",
            }
          : unavailable(inventoryBalancesResult.error?.message),
        replenishment: inventoryQueue
          ? {
              available: true,
              total_below_minimum: inventoryQueue.total ?? 0,
              status_counts: inventoryQueue.status_counts ?? {},
              items: inventoryQueue.items ?? [],
              pagination: { page: 1, page_size: 5 },
              source_rpc: "list_inventory_replenishment_work_queue",
            }
          : {
              available: false,
              total_below_minimum: null,
              status_counts: {},
              items: [],
              reason: normalize(inventoryResult.error?.message ?? "Fuente no disponible para este acceso."),
              pagination: { page: 1, page_size: 5 },
              source_rpc: "list_inventory_replenishment_work_queue",
            },
      },
      receivables: {
        as_of: dateTo,
        as_of_kind: "historical_reconstruction_from_receivable_applications",
        open: metricPayload(receivablesMetric),
        overdue: metricPayload(overdueReceivablesMetric),
        note: "La antigüedad detallada por cliente se consulta en CxC; este bloque sólo publica los totales que el resumen canónico puede reconstruir.",
        source_rpc: "bi_get_executive_summary_compared",
      },
      supplier_signals: network
        ? {
            as_of_period: { from: dateFrom, to: dateTo },
            signal: "committed_or_observed_purchase_amount",
            items: (network.nodes ?? [])
              .filter((node) => node.type === "supplier")
              .map((node) => ({
                supplier_id: node.entity_id,
                supplier_name: node.label,
                supplier_code: node.secondary ?? null,
                purchase_signal_amount: node.metrics?.purchases ?? null,
                connections: node.metrics?.connections ?? null,
              })),
            bounded: true,
            truncated: Boolean(network.truncated),
            methodology: network.methodology?.supplier_product ?? "Importes y cantidades de compras canónicas dentro del periodo.",
            source_rpc: "bi_dependency_network_query",
          }
        : unavailable(networkResult.error?.message),
      quality: {
        partial: Boolean(
          sales?.partial ||
            margin?.partial ||
            inventoryResult.error ||
            inventoryBalancesResult.error ||
            inventorySummaryResult.error ||
            networkResult.error ||
            profitabilityResults.some(({ result }) => Boolean(result.error)) ||
            metricUnavailable(inventoryMetric) ||
            metricUnavailable(receivablesMetric),
        ),
        sources: {
          executive_summary: sourceStatus(summaryResult),
          net_sales_by_location: sourceStatus(salesResult),
          gross_margin_by_location: sourceStatus(marginResult),
          inventory_replenishment: sourceStatus(inventoryResult),
          inventory_positions: sourceStatus(inventoryBalancesResult),
          inventory_current_summary: sourceStatus(inventorySummaryResult),
          location_profitability: {
            available: profitabilityResults.length > 0 && profitabilityResults.every(({ result }) => !result.error),
            partial: profitabilityResults.some(({ result }) => Boolean(result.error)),
            page_size: profitabilityPageSize,
          },
          supplier_network: sourceStatus(networkResult),
        },
      },
      trace: {
        server_side: true,
        caller_jwt: true,
        composed_rpcs: [
          "bi_get_executive_summary_compared",
          "bi_get_operational_table",
          "get_location_profitability",
          "list_inventory_replenishment_work_queue",
          "search_inventory_balances",
          "bi_dependency_network_query",
        ],
      },
    }, 200);
  } catch (error) {
    if (error instanceof Error && error.message === "UNAUTHORIZED") return response({ error: "Sesión no válida." }, 401);
    return response({ error: "No se pudo consultar el resumen operativo." }, 500);
  }
}

function unavailable(message?: string | null) {
  return { available: false, value: null, reason: normalize(message ?? "Fuente no disponible para este acceso.") };
}

function optionalData(result: RpcResult) {
  return result.error ? null : result.data;
}

function sourceStatus(result: RpcResult) {
  return result.error ? { available: false, reason: normalize(result.error.message) } : { available: true };
}

function metricUnavailable(metric: SummaryMetric | null) {
  return !metric || metric.available === false;
}

function emptyToNull(value: string | null) {
  const trimmed = value?.trim() ?? "";
  return trimmed ? trimmed : null;
}

function validDate(value: string) {
  if (!ISO_DATE_RE.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value;
}

function dateToValue(value: string) {
  return Date.parse(`${value}T00:00:00Z`);
}

function daysBetween(from: string, to: string) {
  return Math.round((dateToValue(to) - dateToValue(from)) / 86_400_000);
}

function boundedInteger(value: string | null, fallback: number, min: number, max: number) {
  if (!value) return fallback;
  const parsed = Number(value);
  return Number.isInteger(parsed) ? Math.max(min, Math.min(max, parsed)) : fallback;
}

function statusFor(message: string) {
  return /no autorizado|no disponible|permission|access/i.test(message) ? 403 : 400;
}

function normalize(message: string) {
  if (/no autorizado|permission|access/i.test(message)) return "Fuente no disponible para este acceso.";
  if (/invalid input syntax|periodo|fecha|ubicación inválida/i.test(message)) return "La consulta operativa contiene filtros inválidos.";
  return message;
}

function response(body: unknown, status: number) {
  return NextResponse.json(body, {
    status,
    headers: {
      "cache-control": "private, no-store",
      vary: "authorization",
      "x-content-type-options": "nosniff",
    },
  });
}
