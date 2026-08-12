import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

const shell=readFileSync(new URL("../app/components/SatrapyApp.tsx",import.meta.url),"utf8");
const home=readFileSync(new URL("../app/components/ConfigurationHome.tsx",import.meta.url),"utf8");
const view=readFileSync(new URL("../app/components/CompanyUsersView.tsx",import.meta.url),"utf8");
const provider=readFileSync(new URL("../app/components/SatrapyProvider.tsx",import.meta.url),"utf8");
const route=readFileSync(new URL("../app/api/admin/users/route.ts",import.meta.url),"utf8");
const registrationRoute=readFileSync(new URL("../app/api/auth/register/route.ts",import.meta.url),"utf8");
const access=readFileSync(new URL("../app/lib/navigation-access.ts",import.meta.url),"utf8");
const styles=readFileSync(new URL("../app/globals.css",import.meta.url),"utf8");
const sql=readFileSync(new URL("../supabase/migrations/202607220003_user_access_administration.sql",import.meta.url),"utf8");
const pendingSql=readFileSync(new URL("../supabase/migrations/202607220004_pending_user_registration.sql",import.meta.url),"utf8");

test("Usuarios y accesos vive dentro de Configuración",()=>{
  assert.match(shell,/users_access:[\s\S]*href: "\/satrapy\/configuracion\/usuarios"[\s\S]*area: "settings"/);
  assert.match(home,/Usuarios y accesos/);
  assert.match(view,/title="Usuarios y accesos"/);
  assert.doesNotMatch(shell,/display_name: "Supervisor de Sucursal"/);
  assert.doesNotMatch(shell,/display_name: "Punto de Venta"/);
  assert.match(shell,/display_name: "Operador de Sucursal"/);
});

test("la administración reutiliza identidad y membresías con seguridad server-side",()=>{
  assert.match(sql,/alter table public\.user_roles add column if not exists is_active/);
  assert.match(sql,/access\.role_consolidated/);
  assert.match(sql,/manage_company_users/);
  assert.match(sql,/create or replace function public\.list_company_users/);
  assert.match(sql,/create or replace function public\.save_company_user_access/);
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/p_expected_updated_at/);
  assert.match(sql,/company\.user_access_saved/);
  assert.match(provider,/\.eq\("is_active", true\)/);
});

test("Superadmin recibe el catálogo real de permisos para operar cualquier empresa",()=>{
  assert.match(provider,/if \(isSuperAdmin\) \{[\s\S]*\.from\("permissions"\)[\s\S]*\.select\("code"\)/);
  assert.match(provider,/permissions = \(permissionCatalog \?\? \[\]\)\.map/);
});

test("el admin autoriza el correo sin enviar invitación ni crear credenciales",()=>{
  assert.match(route,/save_company_user_invitation/);
  assert.doesNotMatch(route,/inviteUserByEmail|createUser/);
  assert.match(registrationRoute,/prepare_pending_user_registration/);
  assert.match(registrationRoute,/auth\.admin\.createUser/);
  assert.match(registrationRoute,/complete_pending_user_registration/);
  assert.match(registrationRoute,/SUPABASE_SERVICE_ROLE_KEY/);
  assert.match(view,/Autorizar correo/);
  assert.match(view,/p_location_ids:scoped\?form\.locationIds:\[\]/);
  assert.match(view,/No se enviará correo/);
  assert.match(shell,/Crear cuenta/);
  assert.match(pendingSql,/company_user_invitations/);
});

test("Dirección concentra usuarios y aprobaciones; los roles anteriores quedan sin asignación",()=>{
  for(const permission of ["manage_company_users","approve_inventory_adjustments","approve_cash_variance"])assert.equal(access.includes(`\"${permission}\"`),true,permission);
  assert.match(sql,/r\.code='supervisor_sucursal'[\s\S]*approve_inventory_adjustments','approve_cash_variance/);
  assert.match(sql,/is_assignable=false where code in \('super_admin','supervisor_sucursal','punto_venta'\)/);
});

test("la vista conserva tarjetas, jerarquía visual y protege el acceso global",()=>{
  assert.match(styles,/\.company-users \{ width:100%; min-width:0; \}/);
  assert.match(styles,/\.user-access-summary \{ display:grid;/);
  assert.match(styles,/\.company-users > \.data-toolbar/);
  assert.match(view,/disabled=\{protectedAccess\}/);
  assert.match(view,/Acceso global protegido/);
  assert.match(view,/Editar acceso/);
});
