import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const experience=readFileSync("app/lib/product-experience.ts","utf8");
const collaborators=readFileSync("app/components/CollaboratorsModule.tsx","utf8");
const schedule=readFileSync("app/components/payroll/CollaboratorWeeklyScheduleModal.tsx","utf8");
const migration=readFileSync("supabase/migrations/202608230006_restaurant_collaborator_weekly_schedules.sql","utf8");
const exportsFile=readFileSync("app/lib/payroll-report-export.ts","utf8");

test("Restaurant expone el flujo completo de colaboradores, nómina y recibos",()=>{
  assert.match(experience,/"collaborators_directory"/);
  assert.match(experience,/"payroll"/);
  assert.match(experience,/Nómina y recibos/);
  assert.match(collaborators,/createPayrollReceiptExcel/);
  assert.match(collaborators,/record_payroll_payment_batch/);
  assert.match(exportsFile,/Recibo de nómina/);
});

test("el horario individual es semanal, versionado, autorizado y auditable",()=>{
  for(const weekday of ["Lunes","Martes","Miércoles","Jueves","Viernes","Sábado","Domingo"]) assert.match(schedule,new RegExp(weekday));
  assert.match(schedule,/type="time"/);
  assert.match(schedule,/breakMinutes/);
  assert.match(schedule,/Guardar nueva vigencia/);
  assert.match(migration,/version_number/);
  assert.match(migration,/has_company_permission\(p_company_id,'manage_collaborators'\)/);
  assert.match(migration,/collaborator\.weekly_schedule_created/);
  assert.match(migration,/pg_advisory_xact_lock/);
});

test("los puestos faltantes se crean sin convertirlos en permisos",()=>{
  assert.match(collaborators,/create_collaborator_position/);
  assert.match(collaborators,/El puesto clasifica la función laboral; no concede permisos/);
  assert.match(migration,/collaborator\.position_created/);
});
