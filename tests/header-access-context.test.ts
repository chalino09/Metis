import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const app = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const provider = readFileSync("app/components/SatrapyProvider.tsx", "utf8");
const css = readFileSync("app/globals.css", "utf8");

test("el selector muestra todas las empresas al superadmin y sólo las membresías al usuario multiempresa", () => {
  assert.match(app, /isSuperAdmin \|\| companies\.length > 1 \? <div className="global-session-switchers"/);
  assert.match(provider, /const isSuperAdmin = allAssignedRoles\.some/);
  assert.match(provider, /const availableCompanies = isSuperAdmin \? normalizedCompanies : normalizedCompanies\.filter\(\(company\) => companyIds\.includes\(company\.id\)\)/);
  assert.match(provider, /setIsSuperAdmin\(isSuperAdmin\)/);
  assert.match(app, /\{isSuperAdmin && <RolePreview/);
  assert.match(app, /: <div className="global-company-context"/);
  assert.match(app, /global-role-badge/);
});

test("el encabezado muestra un contexto compacto", () => {
  assert.match(css, /\.global-header \{[^}]*min-height: 60px/);
  assert.match(css, /\.global-session-switchers/);
  assert.match(css, /\.global-company-context/);
});

test("Superadmin conserva acceso a las vistas permitidas por Restaurant", () => {
  assert.match(app, /\(!previewRole && isSuperAdmin\) \|\| matchesNavigationRequirement/);
  assert.match(app, /getAllowedNavigation\(appState\.membership\.permissions, previewRole, experience, isSuperAdmin\)/);
});
