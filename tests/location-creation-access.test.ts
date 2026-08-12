import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const access = readFileSync(new URL("../app/lib/navigation-access.ts", import.meta.url), "utf8");
const locations = readFileSync(new URL("../app/components/CompanyLocationsView.tsx", import.meta.url), "utf8");
const shell = readFileSync(new URL("../app/components/SatrapyApp.tsx", import.meta.url), "utf8");
const sql = readFileSync(new URL("../supabase/migrations/202608070002_location_operating_foundation.sql", import.meta.url), "utf8");

test("Administrador y Superadmin pueden crear sucursales desde el núcleo", () => {
  assert.match(access, /"manage_location_operating_profiles"/);
  assert.match(sql, /r\.code in\('super_admin','direccion_admin'\)/);
  assert.match(locations, /const can=\(code:string\)=>isSuperAdmin\|\|permissions\.includes\("\*"\)/);
  assert.match(locations, /can\("manage_location_operating_profiles"\)\?<Button variant="primary" onClick=\{openNew\}/);
  assert.match(shell, /permissions=\{effectivePermissions\}/);
});
