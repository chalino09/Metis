import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const migrationsDirectory = "supabase/migrations";
const migrationFiles = readdirSync(migrationsDirectory)
  .filter((file) => file.endsWith(".sql"))
  .sort();

const tableRls = new Map<string, boolean>();

for (const file of migrationFiles) {
  const sql = readFileSync(`${migrationsDirectory}/${file}`, "utf8");

  for (const match of sql.matchAll(
    /create\s+table\s+(?:if\s+not\s+exists\s+)?public\.([a-z_][a-z0-9_]*)/gi,
  )) {
    if (!tableRls.has(match[1])) tableRls.set(match[1], false);
  }

  for (const match of sql.matchAll(
    /alter\s+table\s+(?:if\s+exists\s+)?public\.([a-z_][a-z0-9_]*)\s+enable\s+row\s+level\s+security/gi,
  )) {
    tableRls.set(match[1], true);
  }

  for (const match of sql.matchAll(
    /alter\s+table\s+(?:if\s+exists\s+)?public\.([a-z_][a-z0-9_]*)\s+disable\s+row\s+level\s+security/gi,
  )) {
    tableRls.set(match[1], false);
  }
}

test("toda tabla creada en public termina con RLS habilitado", () => {
  const unprotected = [...tableRls]
    .filter(([, enabled]) => !enabled)
    .map(([table]) => table)
    .sort();

  assert.deepEqual(
    unprotected,
    [],
    `Tablas public sin RLS: ${unprotected.join(", ")}`,
  );
});
