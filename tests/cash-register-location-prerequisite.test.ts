import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sales = readFileSync(new URL("../app/components/SalesModule.tsx", import.meta.url), "utf8");

test("una caja exige una sucursal activa antes de llamar al servidor", () => {
  const submit = sales.slice(sales.indexOf("async function submitRegister"), sales.indexOf("async function submitDenomination"));
  assert.match(submit, /if \(!registerLocationId\)/);
  assert.ok(submit.indexOf("if (!registerLocationId)") < submit.indexOf('rpc("upsert_cash_register"'));
  assert.match(sales, /Crea una sucursal antes de agregar la caja/);
  assert.match(sales, /href="\/satrapy\/configuracion\/empresa\/sucursales"/);
  assert.match(sales, /disabled=\{!registerLocationId\}>Guardar caja/);
});
