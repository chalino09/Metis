import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { ROLE_PREVIEW_PERMISSIONS } from "../app/lib/navigation-access.ts";

const migration = readFileSync("supabase/migrations/202607250011_bi_phase1_foundation.sql", "utf8");
const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const ui = readFileSync("app/components/BiModule.tsx", "utf8");
const design = readFileSync("docs/bi-phase-1-design-20260725.md", "utf8");

test("BI tiene permiso propio y no se expone a roles operativos", () => {
  assert.ok(ROLE_PREVIEW_PERMISSIONS.direccion_admin.includes("view_bi"));
  for (const role of ["sucursal", "ingeniero_campo", "almacen", "punto_venta"] as const) {
    assert.equal(ROLE_PREVIEW_PERMISSIONS[role].includes("view_bi"), false, role);
  }
  assert.match(migration, /\('view_bi','Consultar indicadores/);
  assert.match(migration, /public\.has_company_permission\(p_company_id,'view_bi'\)/);
});

test("las áreas de BI conservan Resumen como portada y agregan Metas", () => {
  assert.match(app, /href: "\/satrapy\/bi"/);
  assert.match(app, /views: \["bi_summary", "bi_explorer", "bi_reports", "bi_budgets", "bi_network"\]/);
  assert.match(app, /<BiModule companyId=.*view="summary"/);
  assert.match(ui, /view !== "summary"/);
  assert.match(ui, /className="content-frame module-page bi-module"/);
  assert.match(ui, /className="content-frame module-page bi-roadmap"/);
});

test("las consultas son server-side, acotadas, auditadas y respetan ubicación", () => {
  assert.match(migration, /v_days>366/);
  assert.match(migration, /public\.can_access_location/);
  assert.match(migration, /p_page_size integer default 25/);
  assert.match(migration, /least\(greatest\(coalesce\(p_page_size,25\),1\),100\)/);
  assert.match(migration, /'bi\.executive_summary_queried'/);
  assert.match(migration, /'bi\.drilldown_queried'/);
  assert.match(
    migration,
    /generate_series\([\s\S]*p_date_from::timestamp[\s\S]*p_date_to::timestamp[\s\S]*interval '1 day'/,
  );
  assert.doesNotMatch(migration, /::date\s+day\b/);
  assert.doesNotMatch(migration, /\bd\.day\b/);
  assert.doesNotMatch(ui, /\.from\("sales"\)/);
  assert.match(ui, /\.rpc\("bi_get_executive_summary"/);
  assert.match(ui, /\.rpc\("bi_get_drilldown"/);
});

test("los filtros usan identidades canónicas y búsquedas paginadas", () => {
  assert.match(migration, /v_dimension not in \('product','customer','supplier'\)/);
  assert.match(migration, /from public\.products/);
  assert.match(migration, /from public\.customers/);
  assert.match(migration, /from public\.suppliers/);
  assert.match(ui, /p_product_id: next\.product\?\.id/);
  assert.match(ui, /p_customer_id: next\.customer\?\.id/);
  assert.match(ui, /p_supplier_id: next\.supplier\?\.id/);
});

test("el contrato distingue naturalezas y declara el margen bloqueado", () => {
  assert.match(ui, /kind: "Devengado"/);
  assert.match(ui, /kind: "Efectivo"/);
  assert.match(ui, /kind: "Operativo"/);
  assert.match(design, /KPI bloqueado: margen bruto histórico exacto/);
  assert.match(design, /no conserva el costo reconocido por partida y fecha/);
  assert.match(ui, /El margen histórico aún no se publica/);
});
