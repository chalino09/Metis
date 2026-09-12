export type BiSummaryMetric = {
  code?: string;
  value?: number | null;
  previous_value?: number | null;
  available?: boolean;
  reason?: string | null;
  coverage?: number | null;
};

export type BiOperationalItem = {
  group_key?: string;
  group_label?: string;
  current_value?: number | null;
  previous_value?: number | null;
  change_value?: number | null;
  change_percent?: number | null;
  available?: boolean;
  reason?: string | null;
};

export type BiSummaryLocation = {
  location_id?: string;
  location_name?: string;
  sales?: number | null;
  tickets?: number | null;
};

export function metricPayload(metric: BiSummaryMetric | null) {
  const available = Boolean(metric) && metric?.available !== false;
  return {
    value: available ? metric?.value ?? null : null,
    previous: available ? metric?.previous_value ?? null : null,
    available,
    reason: metric?.reason ?? (!metric ? "Métrica no publicada por el RPC fuente." : null),
    coverage: available ? metric?.coverage ?? null : null,
  };
}

export function mergeLocations(
  summary: BiSummaryLocation[],
  sales: BiOperationalItem[],
  margin: BiOperationalItem[],
) {
  const summaryById = new Map(
    summary.filter((location) => location.location_id).map((location) => [location.location_id as string, location]),
  );
  const marginById = new Map(
    margin.filter((item) => item.group_key).map((item) => [item.group_key as string, item]),
  );

  // Net sales is the canonical page and ordering. Never fall back to the
  // executive summary when that page is empty: page 2 must remain empty.
  return sales.filter((item) => item.group_key).map((item) => {
    const id = item.group_key as string;
    const fallback = summaryById.get(id);
    const marginItem = marginById.get(id);
    const location: Record<string, unknown> = {
      location_id: id,
      location_name: item.group_label ?? fallback?.location_name ?? id,
      net_sales: metricRow(item),
      tickets: fallback?.tickets ?? null,
      net_sales_quality: item.available === false ? "partial" : "complete",
      gross_margin: marginItem?.available === false ? null : marginItem ? metricRow(marginItem) : null,
      gross_margin_quality: marginItem ? (marginItem.available === false ? "partial" : "complete") : "unavailable",
    };
    if (item.reason) location.net_sales_reason = item.reason;
    if (marginItem?.reason) location.gross_margin_reason = marginItem.reason;
    return location;
  });
}

function metricRow(item: BiOperationalItem) {
  return {
    current: item.current_value ?? null,
    previous: item.previous_value ?? null,
    change: item.change_value ?? null,
    change_percent: item.change_percent ?? null,
  };
}
