import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const accountingModule = readFileSync(new URL("../app/components/AccountingModule.tsx", import.meta.url), "utf8");

test("etapa 3 conserva el catálogo como bloque principal y compacta excepciones vacías", () => {
  assert.match(accountingModule, /accounting-catalog-block/);
  assert.match(accountingModule, /<h2>Catálogo<\/h2>/);
  assert.match(accountingModule, /Sin excepciones de clasificación/);
  assert.match(accountingModule, /action:"bulk_assign_expense_category"/);
});

test("periodos y pólizas muestran la siguiente acción sin exponer el detalle de forma permanente", () => {
  assert.match(accountingModule, /title="Crear periodo"/);
  assert.match(accountingModule, /Resolver diferencias antes de confirmar/);
  assert.doesNotMatch(accountingModule, /Vista \{run\.snapshot_sha256/);
  assert.match(accountingModule, /<details className="accounting-journal"/);
  assert.match(accountingModule, /Buscar póliza, fecha o descripción/);
  assert.match(accountingModule, /label="pólizas"/);
});

test("eventos, apertura y reportes priorizan atención y conservan las operaciones existentes", () => {
  assert.match(accountingModule, /Eventos pendientes de reproceso/);
  assert.match(accountingModule, /Historial contabilizado/);
  assert.match(accountingModule, /action:"reprocess_events"/);
  assert.match(accountingModule, /action:"promote"/);
  for (const label of ["Mes actual", "Mes anterior", "Año actual", "Periodo abierto"]) assert.match(accountingModule, new RegExp(label));
  assert.match(accountingModule, /Elegir fechas manualmente/);
});
