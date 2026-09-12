import type { NeutralValueState } from "./neutral-start";

/**
 * Small, pure presentation helpers for the executive BI surface.
 *
 * Values, comparisons, formulas, coverage and permission decisions come from
 * the BI RPCs. This module only classifies and presents those supplied fields.
 */

export type BiMetricDataState = "value" | "zero_no_operations" | "partial" | "unavailable";
export type BiMetricUnit = "currency" | "count" | "quantity" | "percent" | "days" | "number";
export type BiMetricFormat = "currency" | "integer" | "percent" | "number";

export type BiDecisionMetric = {
  code: string;
  label?: string;
  value?: number | null;
  available?: boolean;
  reason?: string | null;
  coverage?: number | null;
  value_state?: NeutralValueState;
  valueState?: NeutralValueState;
  unit?: BiMetricUnit;
  format?: BiMetricFormat;
};

export type BiMetricClassification = {
  state: BiMetricDataState;
  /** Whether the numeric value is safe to present. */
  available: boolean;
  /** True for both an explicit neutral zero and an ordinary available zero. */
  isZero: boolean;
  isPartial: boolean;
  value: number | null;
  coverage: number | null;
  reason: string | null;
};

function finite(value: number | null | undefined): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

/**
 * Separates a real zero from missing data. An explicit neutral state is the
 * only way to call a metric `zero_no_operations`; an ordinary available zero
 * remains a real `value` and is marked with `isZero`.
 *
 * `available: false` wins over coverage and value. This prevents a numeric
 * payload attached to a forbidden or unavailable metric from reaching UI.
 */
export function classifyBiMetric(metric: BiDecisionMetric): BiMetricClassification {
  const explicitState = metric.value_state ?? metric.valueState;
  const coverage = finite(metric.coverage) ? Math.max(0, Math.min(100, metric.coverage)) : null;
  const reason = metric.reason ?? null;

  if (metric.available === false || explicitState === "unavailable") {
    return { state: "unavailable", available: false, isZero: false, isPartial: false, value: null, coverage, reason };
  }
  if (explicitState === "zero_no_operations") {
    return { state: "zero_no_operations", available: true, isZero: true, isPartial: false, value: 0, coverage, reason };
  }

  const value = finite(metric.value) ? metric.value : null;
  if (value === null) {
    return { state: "unavailable", available: false, isZero: false, isPartial: false, value: null, coverage, reason };
  }
  if (coverage !== null && coverage < 100) {
    return { state: "partial", available: true, isZero: value === 0, isPartial: true, value, coverage, reason };
  }
  return { state: "value", available: true, isZero: value === 0, isPartial: false, value, coverage, reason };
}

export type BiKpiFormatOptions = {
  locale?: string;
  currencyCode?: string | null;
  unit?: BiMetricUnit;
  format?: BiMetricFormat;
  maximumFractionDigits?: number;
  /** Include “· Dato parcial” in the text when coverage is incomplete. */
  includeQualityLabel?: boolean;
};

export type BiKpiPresentation = {
  text: string;
  state: BiMetricDataState;
  value: number | null;
  coverage: number | null;
  reason: string | null;
  /** A useful label for aria-label/title, including the data state. */
  accessibleLabel: string;
};

function metricUnit(metric: BiDecisionMetric, options: BiKpiFormatOptions): BiMetricUnit {
  if (options.unit) return options.unit;
  if (metric.unit) return metric.unit;
  if (options.format === "integer" || metric.format === "integer") return "count";
  if (options.format === "percent" || metric.format === "percent") return "percent";
  return "currency";
}

function formatNumber(value: number, unit: BiMetricUnit, options: BiKpiFormatOptions): string {
  const locale = options.locale ?? "es-MX";
  const currencyCode = options.currencyCode && /^[A-Za-z]{3}$/.test(options.currencyCode)
    ? options.currencyCode.toUpperCase()
    : null;
  const maximumFractionDigits = options.maximumFractionDigits ?? (
    unit === "count" ? 0 : unit === "percent" ? 1 : unit === "quantity" ? 2 : unit === "days" ? 1 : 0
  );
  const numberOptions: Intl.NumberFormatOptions = { maximumFractionDigits };
  if (unit === "currency" && currencyCode) {
    return new Intl.NumberFormat(locale, { ...numberOptions, style: "currency", currency: currencyCode }).format(value);
  }
  const text = new Intl.NumberFormat(locale, numberOptions).format(value);
  return unit === "percent" ? `${text}%` : text;
}

/**
 * Presents a KPI without turning null/forbidden data into zero. A missing
 * currency code intentionally produces a plain number rather than a guessed
 * currency symbol.
 */
export function presentBiKpi(metric: BiDecisionMetric, options: BiKpiFormatOptions = {}): BiKpiPresentation {
  const classification = classifyBiMetric(metric);
  const unit = metricUnit(metric, options);
  const includeQualityLabel = options.includeQualityLabel ?? true;
  let text = "No disponible";
  if (classification.available && classification.value !== null) {
    text = formatNumber(classification.value, unit, options);
    if (classification.isPartial && includeQualityLabel) text = `${text} · Dato parcial`;
  }
  const label = metric.label ?? metric.code;
  const accessibleLabel = classification.state === "unavailable"
    ? `${label}: No disponible${classification.reason ? `. ${classification.reason}` : ""}`
    : `${label}: ${text}`;
  return {
    text,
    state: classification.state,
    value: classification.value,
    coverage: classification.coverage,
    reason: classification.reason,
    accessibleLabel,
  };
}

export type BiPeriodPreset =
  | "today"
  | "last7"
  | "last30"
  | "last90"
  | "lastCompletedWeek"
  | "thisMonth"
  | "previousMonth"
  | "thisQuarter";

export type BiPeriodPresetWithCustom = BiPeriodPreset | "custom";
export type BiPeriodRange = { dateFrom: string; dateTo: string };

function localDay(value: Date | string): Date {
  if (typeof value === "string") {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
    if (match) return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]), 12);
    const parsed = new Date(value);
    if (Number.isNaN(parsed.getTime())) throw new RangeError(`Invalid date: ${value}`);
    return new Date(parsed.getFullYear(), parsed.getMonth(), parsed.getDate(), 12);
  }
  if (Number.isNaN(value.getTime())) throw new RangeError("Invalid date");
  return new Date(value.getFullYear(), value.getMonth(), value.getDate(), 12);
}

function addLocalDays(value: Date, amount: number): Date {
  const result = new Date(value.getFullYear(), value.getMonth(), value.getDate(), 12);
  result.setDate(result.getDate() + amount);
  return result;
}

function localIsoDate(value: Date): string {
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
}

/**
 * Resolves local calendar ranges. `lastCompletedWeek` is always the Monday
 * through Sunday immediately before the current local week.
 */
export function getBiPeriodRange(preset: BiPeriodPreset, anchor: Date | string = new Date()): BiPeriodRange {
  const today = localDay(anchor);
  let from = today;
  let to = today;
  switch (preset) {
    case "today":
      break;
    case "last7":
      from = addLocalDays(today, -6);
      break;
    case "last30":
      from = addLocalDays(today, -29);
      break;
    case "last90":
      from = addLocalDays(today, -89);
      break;
    case "lastCompletedWeek": {
      const daysSinceMonday = (today.getDay() + 6) % 7;
      const currentWeekMonday = addLocalDays(today, -daysSinceMonday);
      to = addLocalDays(currentWeekMonday, -1);
      from = addLocalDays(to, -6);
      break;
    }
    case "thisMonth":
      from = new Date(today.getFullYear(), today.getMonth(), 1, 12);
      break;
    case "previousMonth":
      from = new Date(today.getFullYear(), today.getMonth() - 1, 1, 12);
      to = new Date(today.getFullYear(), today.getMonth(), 0, 12);
      break;
    case "thisQuarter":
      from = new Date(today.getFullYear(), Math.floor(today.getMonth() / 3) * 3, 1, 12);
      break;
    default: {
      const exhaustive: never = preset;
      throw new RangeError(`Unsupported period preset: ${String(exhaustive)}`);
    }
  }
  return { dateFrom: localIsoDate(from), dateTo: localIsoDate(to) };
}

export function inferBiPeriodPreset(range: BiPeriodRange, anchor: Date | string = new Date()): BiPeriodPresetWithCustom {
  const presets: BiPeriodPreset[] = ["today", "last7", "last30", "last90", "lastCompletedWeek", "thisMonth", "previousMonth", "thisQuarter"];
  return presets.find(preset => {
    const candidate = getBiPeriodRange(preset, anchor);
    return candidate.dateFrom === range.dateFrom && candidate.dateTo === range.dateTo;
  }) ?? "custom";
}

export const BI_PERIOD_PRESETS: ReadonlyArray<{ value: BiPeriodPresetWithCustom; label: string }> = [
  { value: "today", label: "Hoy" },
  { value: "last7", label: "Últimos 7 días" },
  { value: "lastCompletedWeek", label: "Última semana completa" },
  { value: "last30", label: "Últimos 30 días" },
  { value: "last90", label: "Últimos 90 días" },
  { value: "thisMonth", label: "Este mes" },
  { value: "previousMonth", label: "Mes anterior" },
  { value: "thisQuarter", label: "Este trimestre" },
  { value: "custom", label: "Periodo personalizado" },
];
