import assert from"node:assert/strict";
import{readFileSync}from"node:fs";
import test from"node:test";

const sql=readFileSync("supabase/migrations/202607270004_collaborator_positions_and_access.sql","utf8");
const collaborators=readFileSync("app/components/CollaboratorsModule.tsx","utf8");
const users=readFileSync("app/components/CompanyUsersView.tsx","utf8");

test("separa colaborador, puesto laboral, cuenta y perfil de acceso",()=>{
  assert.match(sql,/create table if not exists public\.collaborator_positions/);
  assert.match(sql,/alter table public\.collaborators add column if not exists position_id/);
  assert.match(sql,/\('ingeniero_campo','Ingeniero de campo'\)/);
  assert.match(collaborators,/puesto laboral no concede permisos por sí solo/i);
  assert.match(users,/Perfil de acceso/);
});

test("no reclasifica puestos importados ni deduce identidades",()=>{
  assert.doesNotMatch(sql,/update public\.collaborators\s+set\s+position_id/is);
  assert.match(sql,/siguen sin puesto hasta que[\s\S]*una persona autorizada las clasifique explícitamente/i);
  assert.match(sql,/nunca se usa para permisos/i);
});

test("el acceso nace desde el expediente y se vincula de forma auditada e idempotente",()=>{
  assert.match(sql,/provision_collaborator_user_access/);
  assert.match(sql,/collaborator\.access_provisioned/);
  assert.match(sql,/p_client_request_id/);
  assert.match(sql,/company_user_invitations add column if not exists collaborator_id/);
  assert.match(sql,/Vínculo activado al completar el registro/);
  assert.match(collaborators,/Dar acceso a Satrapy/);
  assert.match(collaborators,/La cuenta queda vinculada a este expediente/);
});

test("BI sólo ofrece responsables que sean ingenieros activos con cuenta y perfil vigentes",()=>{
  assert.match(sql,/p\.code='ingeniero_campo'/);
  assert.match(sql,/collaborator_user_links l join public\.user_roles/);
  assert.match(sql,/El responsable debe ser un Ingeniero de Campo activo con cuenta y perfil vigentes/);
  assert.match(sql,/bi_search_budget_scope_options/);
});

test("Usuarios y accesos conserva la administración sin duplicar personas",()=>{
  assert.match(sql,/create or replace function public\.list_company_users/);
  assert.match(sql,/jsonb_build_object\('id',c\.id,'code',c\.code,'name',c\.display_name\)collaborator/);
  assert.match(users,/El acceso de un Ingeniero de Campo se crea desde su expediente/);
  assert.match(users,/Sin vínculo/);
});
