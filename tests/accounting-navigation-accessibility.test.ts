import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { isKeyboardActivationKey } from "../app/lib/keyboard-activation.ts";
import { matchesNavigationRequirement } from "../app/lib/navigation-access.ts";

const shell = readFileSync(new URL("../app/components/SatrapyApp.tsx", import.meta.url), "utf8");
const accounting = readFileSync(new URL("../app/components/AccountingModule.tsx", import.meta.url), "utf8");
const data = readFileSync(new URL("../app/components/ui/data.tsx", import.meta.url), "utf8");

test("Contabilidad recupera sus ocho destinos directos sin selectores agrupados", () => {
  for (const href of ["/satrapy/contabilidad", "/satrapy/contabilidad/catalogo", "/satrapy/contabilidad/estados-financieros", "/satrapy/contabilidad/periodos", "/satrapy/contabilidad/polizas", "/satrapy/contabilidad/eventos", "/satrapy/contabilidad/bancos", "/satrapy/contabilidad/apertura"]) assert.match(shell, new RegExp(`href: "${href}"`));
  assert.match(shell, /accounting-context-nav/);
  assert.match(shell, /<Link className=\{`context-nav__item/);
  assert.doesNotMatch(shell, /AccountingNavigationMenu/);
  assert.doesNotMatch(shell, /Configuración y apertura/);
  assert.doesNotMatch(shell, /Operación contable/);
});

test("Bancos conserva su permiso y la ruta activa usa aria-current", () => {
  assert.match(shell, /accounting_banking: \{ label: "Bancos"[\s\S]*requirement: \{ all: \["view_banking"\] \}/);
  assert.match(shell, /aria-current=\{activeView === name \? "page" : undefined\}/);
  assert.equal(matchesNavigationRequirement(["view_accounting"], { all: ["view_banking"] }), false);
  assert.equal(matchesNavigationRequirement(["view_accounting", "view_banking"], { all: ["view_banking"] }), true);
});

test("cuentas y categorías conservan filas accesibles sin cambiar su edición", () => {
  assert.match(accounting, /InteractiveTableRow/);
  assert.match(accounting, /label=\{`Editar cuenta \$\{account\.code\}/);
  assert.match(accounting, /label=\{`Editar categoría \$\{category\.code\}/);
  assert.match(accounting, /setDraft\(\{\.\.\.account\}\)/);
  assert.match(accounting, /setCategoryDraft\(\{categoryId:category\.category_id/);
  assert.match(data, /role="button" tabIndex=\{0\}/);
  assert.match(data, /onKeyDown=\{handleKeyDown\}/);
  assert.equal(isKeyboardActivationKey("Enter"), true);
  assert.equal(isKeyboardActivationKey(" "), true);
  assert.equal(isKeyboardActivationKey("Tab"), false);
});

test("el alta de cuenta conserva el formulario compacto y agrupado", () => {
  const css = readFileSync(new URL("../app/globals.css", import.meta.url), "utf8");
  assert.match(accounting, /className="accounting-account-drawer"/);
  assert.match(accounting, /accounting-account-form__identity/);
  assert.match(accounting, /accounting-account-form__classification/);
  assert.match(accounting, /<legend>Disponibilidad<\/legend>/);
  assert.match(css, /\.ui-drawer\.accounting-account-drawer \{[^}]*height:auto/);
});
