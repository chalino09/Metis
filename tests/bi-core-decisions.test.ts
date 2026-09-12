import assert from "node:assert/strict";
import test from "node:test";
import {
  classifyBiMetric,
  getBiPeriodRange,
  inferBiPeriodPreset,
  presentBiKpi,
} from "../app/lib/bi-core-decisions.ts";

test("separa un cero real de un cero neutral y de la ausencia de datos", () => {
  const realZero = classifyBiMetric({ code: "tickets", value: 0, available: true });
  assert.equal(realZero.state, "value");
  assert.equal(realZero.isZero, true);

  const neutralZero = classifyBiMetric({ code: "tickets", value: null, value_state: "zero_no_operations", available: true });
  assert.equal(neutralZero.state, "zero_no_operations");
  assert.equal(neutralZero.value, 0);

  const partial = classifyBiMetric({ code: "gross_margin", value: 120, available: true, coverage: 72, reason: "Faltan costos." });
  assert.equal(partial.state, "partial");
  assert.equal(partial.isPartial, true);

  const unavailable = classifyBiMetric({ code: "inventory_value", value: 9999, available: false, coverage: 100, reason: "Sin permiso." });
  assert.equal(unavailable.state, "unavailable");
  assert.equal(unavailable.value, null);
});

test("presenta KPI sin convertir ausencia en cero ni adivinar la moneda", () => {
  assert.equal(presentBiKpi({ code: "net_sales", value: 1234.5, available: true }).text, "1,235");
  assert.equal(presentBiKpi({ code: "tickets", value: 0, available: true }, { unit: "count" }).text, "0");
  assert.equal(presentBiKpi({ code: "net_sales", value: 0, available: true }, { unit: "currency", currencyCode: "MXN" }).text, "$0");
  assert.equal(presentBiKpi({ code: "net_sales", value: 1234, available: false }, { unit: "currency", currencyCode: "MXN" }).text, "No disponible");
  assert.equal(presentBiKpi({ code: "gross_margin", value: 2500, available: true, coverage: 80 }, { unit: "currency", currencyCode: "MXN" }).text, "$2,500 · Dato parcial");
});

test("la última semana completa es lunes a domingo usando fechas locales", () => {
  assert.deepEqual(getBiPeriodRange("lastCompletedWeek", "2026-09-11"), { dateFrom: "2026-08-31", dateTo: "2026-09-06" });
  assert.deepEqual(getBiPeriodRange("lastCompletedWeek", "2026-09-13"), { dateFrom: "2026-08-31", dateTo: "2026-09-06" });
  assert.deepEqual(getBiPeriodRange("lastCompletedWeek", "2026-09-14"), { dateFrom: "2026-09-07", dateTo: "2026-09-13" });
  assert.equal(inferBiPeriodPreset({ dateFrom: "2026-08-31", dateTo: "2026-09-06" }, "2026-09-11"), "lastCompletedWeek");
});

test("los presets de mes respetan cambios de año y bisiestos", () => {
  assert.deepEqual(getBiPeriodRange("previousMonth", "2024-03-15"), { dateFrom: "2024-02-01", dateTo: "2024-02-29" });
  assert.deepEqual(getBiPeriodRange("previousMonth", "2025-01-10"), { dateFrom: "2024-12-01", dateTo: "2024-12-31" });
  assert.deepEqual(getBiPeriodRange("thisMonth", "2026-09-11"), { dateFrom: "2026-09-01", dateTo: "2026-09-11" });
});
