import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { mergeLocations, metricPayload } from "../app/lib/bi-operations.ts";

const route = readFileSync(new URL("../app/api/bi/operations/route.ts", import.meta.url), "utf8");
const contract = readFileSync(new URL("../docs/bi-operations-contract.md", import.meta.url), "utf8");

test("el resumen operativo valida el periodo por días calendario y conserva el límite de 366", () => {
  assert.match(route, /if \(daysBetween\(dateFrom, dateTo\) > 365\)/);
  assert.match(route, /const MAX_PAGE_SIZE = 50/);
  assert.match(route, /const MAX_PROFITABILITY_PAGE_SIZE = 10/);
  assert.match(route, /profitabilityPageSize = boundedInteger\(params\.get\("profitability_page_size"\), 5, 1, MAX_PROFITABILITY_PAGE_SIZE\)/);
  assert.doesNotMatch(route, /dateToValue\(dateTo\) - dateToValue\(dateFrom\) > 365/);
});

test("las tablas y faltantes usan paginación server-side acotada", () => {
  assert.match(route, /p_page: page/);
  assert.match(route, /p_page_size: pageSize/);
  assert.match(route, /const inventoryToday = new Date\(\)\.toISOString\(\)\.slice\(0, 10\)/);
  assert.match(route, /p_date_from: inventoryToday/);
  assert.match(route, /p_date_to: inventoryToday/);
  assert.match(route, /p_page: 1,\s+p_page_size: 5/);
  assert.match(route, /purchase_signal_amount: node\.metrics\?\.purchases \?\? null/);
  assert.match(route, /p_node_limit: 50/);
  assert.match(route, /p_edge_limit: 100/);
  assert.match(route, /slice\(0, profitabilityPageSize\)/);
});

test("los filtros fuera del alcance se rechazan y los RPC secundarios degradan por bloque", () => {
  assert.match(route, /params\.has\("product_id"\)/);
  assert.match(route, /params\.has\("customer_id"\)/);
  assert.match(route, /params\.has\("supplier_id"\)/);
  assert.match(route, /optionalData\(inventoryResult\)/);
  assert.match(route, /reason: normalize\(inventoryResult\.error\?\.message/);
  assert.match(route, /unavailable\(networkResult\.error\?\.message\)/);
});

test("la ruta delega permisos y lecturas al JWT del solicitante", () => {
  assert.match(route, /getRequestSupabaseClient\(request\.headers\.get\("authorization"\)\)/);
  assert.match(route, /caller_jwt: true/);
  assert.doesNotMatch(route, /service_role/i);
  assert.doesNotMatch(route, /supabase\.from\(/);
  assert.match(contract, /No usa service role ni lecturas directas de tablas/);
});

test("metricPayload oculta valores y cobertura cuando la fuente declara la métrica no disponible", () => {
  assert.deepEqual(
    metricPayload({
      code: "inventory_value",
      value: 1200,
      previous_value: 900,
      available: false,
      coverage: 42,
      reason: "La fecha histórica no tiene inventario reconstruible.",
    }),
    {
      value: null,
      previous: null,
      available: false,
      reason: "La fecha histórica no tiene inventario reconstruible.",
      coverage: null,
    },
  );
});

test("mergeLocations conserva sólo la página de ventas y une margen por la misma identidad", () => {
  const first = mergeLocations(
    [{ location_id: "summary-only", location_name: "No debe aparecer", sales: 99 }],
    [
      { group_key: "location-a", group_label: "A", current_value: 402 },
      { group_key: "location-b", group_label: "B", current_value: 101 },
    ],
    [
      { group_key: "location-b", group_label: "B", current_value: 40 },
      { group_key: "location-c", group_label: "C", current_value: 900 },
    ],
  );
  assert.deepEqual(first.map((location) => location.location_id), ["location-a", "location-b"]);
  assert.equal(first[0].gross_margin, null);
  assert.deepEqual(first[1].gross_margin, {
    current: 40,
    previous: null,
    change: null,
    change_percent: null,
  });
  assert.deepEqual(mergeLocations([], [], []), []);
});
