import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

const shell=readFileSync(new URL("../app/components/SatrapyApp.tsx",import.meta.url),"utf8");
const home=readFileSync(new URL("../app/components/ConfigurationHome.tsx",import.meta.url),"utf8");
const journey=readFileSync(new URL("../app/components/InitialMigrationView.tsx",import.meta.url),"utf8");
const locations=readFileSync(new URL("../app/components/CompanyLocationsView.tsx",import.meta.url),"utf8");
const sql=readFileSync(new URL("../supabase/migrations/202607220001_configuration_modules_locations.sql",import.meta.url),"utf8");
const coverageSql=readFileSync(new URL("../supabase/migrations/202607220002_configuration_coverage_accounting_revision.sql",import.meta.url),"utf8");
const accounting=readFileSync(new URL("../app/components/AccountingModule.tsx",import.meta.url),"utf8");

test("Configuración se organiza por módulos y conserva las rutas anteriores",()=>{
  assert.match(shell,/settings_home/);assert.match(shell,/initial_migration/);assert.match(shell,/\/satrapy\/configuracion\/empresa\/sucursales/);assert.match(shell,/pathname === "\/satrapy\/inventario\/ubicaciones"/);
  assert.match(shell,/accounting_settings: \{ label: "Configuración contable"[^}]*href: "\/satrapy\/configuracion\/contabilidad"[^}]*area: "settings"/);
  assert.match(shell,/pathname === "\/satrapy\/contabilidad\/configuracion"/);
  assert.match(home,/href:\s*"\/satrapy\/configuracion\/contabilidad"/);
  for(const moduleName of ["Empresa y acceso","Puesta en marcha","Operación comercial","Finanzas","Auditoría"])assert.match(home,new RegExp(`label:\\s*"${moduleName}`));
});

test("Migración inicial reutiliza el Centro principal sin crear otro cargador",()=>{
  assert.match(journey,/get_initial_migration_readiness/);assert.match(journey,/Centro de Migración/);assert.doesNotMatch(journey,/type=\"file\"/);assert.doesNotMatch(sql,/create table public\.import/);
  assert.match(shell,/!isRestaurant && <section className="migration-specialized"/);
  assert.match(shell,/!isRestaurant \|\| visibleCustomerMigrationBatches\.length > 0/);
  assert.match(shell,/!isRestaurant \|\| visiblePurchasingMigrationBatches\.length > 0 \|\| pendingPurchasingFileCount > 0/);
});

test("Sucursales usa operaciones server-side, idempotentes y auditadas",()=>{
  assert.match(locations,/list_company_locations/);assert.match(locations,/save_company_location/);assert.match(locations,/OperationIdempotencyKeys/);assert.match(sql,/company\.location_saved/);assert.match(sql,/pg_advisory_xact_lock/);assert.match(sql,/quantity_on_hand<>0/);assert.match(sql,/p_expected_updated_at/);
});

test("Configuración y Migración muestran cobertura granular",()=>{
  assert.match(shell,/settings_home:\s*\{\s*label:\s*"Configuración"/);assert.match(home,/<h1>Configuración<\/h1>/);assert.match(journey,/Cobertura detectada/);assert.match(journey,/Cobertura por módulo/);assert.match(coverageSql,/total_checks/);assert.match(coverageSql,/bank_reconciliations/);
});

test("Contabilidad edita mediante una nueva versión sin mutar la vigente",()=>{
  assert.match(accounting,/Crear nueva versión/);assert.match(accounting,/Aprobar nueva versión/);assert.match(accounting,/save_config_revision/);assert.match(coverageSql,/start_accounting_config_revision/);assert.match(coverageSql,/save_accounting_config_revision/);assert.match(coverageSql,/status<>'draft'/);
});
