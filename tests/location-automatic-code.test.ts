import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const view = readFileSync(new URL("../app/components/CompanyLocationsView.tsx", import.meta.url), "utf8");
const migration = readFileSync(new URL("../supabase/migrations/202608080002_automatic_location_codes.sql", import.meta.url), "utf8");

test("el alta de sucursal delega el código al núcleo", () => {
  assert.match(view, /p_external_code:form\.code/);
  assert.match(view, /editing\?form\.code\.trim\(\):true/);
  assert.doesNotMatch(view, /Se asignará al guardar/);
  assert.match(view, /!creating&&<Field label="Código"/);
  assert.match(view, /Asignado por Satrapy/);
  assert.match(migration, /pg_advisory_xact_lock/);
  assert.match(migration, /v_external_code:=v_code_prefix\|\|'-'\|\|lpad/);
  assert.match(migration, /v_external_code:=v_location\.external_code/);
});

test("el resumen no muestra el aviso de cargas masivas", () => {
  assert.doesNotMatch(view, /Para crear muchas ubicaciones/);
  assert.doesNotMatch(view, /Abrir Centro de Migración/);
});

test("la terminología visible describe costos de operación", () => {
  assert.doesNotMatch(view, /Economía vigente/);
  assert.match(view, /Costos de operación/);
});
