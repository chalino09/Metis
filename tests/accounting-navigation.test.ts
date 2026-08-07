import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";

const shell=readFileSync(new URL("../app/components/SatrapyApp.tsx",import.meta.url),"utf8");
const css=readFileSync(new URL("../app/globals.css",import.meta.url),"utf8");

test("la navegación contable restaura ocho accesos directos con icono",()=>{
  assert.match(shell,/context-nav--accounting/);
  assert.match(shell,/accounting_accounts: \{ label: "Catálogo de cuentas", icon: BookOpen/);
  assert.match(shell,/accounting_reports: \{ label: "Estados financieros", icon: BarChart3/);
  assert.match(css,/\.context-nav--accounting \.accounting-context-nav \{[^}]*grid-template-columns:repeat\(8/);
  assert.match(css,/\.context-nav--accounting \.accounting-context-nav \{[^}]*overflow:visible/);
  assert.match(css,/\.context-nav--accounting \.context-nav__item \{[^}]*flex-direction:row/);
  assert.match(css,/\.context-nav--accounting \.context-nav__item svg \{[^}]*flex:0 0 auto/);
  assert.doesNotMatch(css,/\.context-nav--accounting \.topbar__status \{ display:none/);
});
