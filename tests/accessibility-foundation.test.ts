import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { AccessCheckTimeoutError, withAccessTimeout } from "../app/lib/access-loading.ts";
import { isKeyboardActivationKey } from "../app/lib/keyboard-activation.ts";

const provider = readFileSync("app/components/SatrapyProvider.tsx", "utf8");
const shell = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const styles = readFileSync("app/globals.css", "utf8");
const tableFoundation = readFileSync("app/components/ui/data.tsx", "utf8");
const operationalTables = [
  "app/components/SatrapyApp.tsx",
  "app/components/PurchaseOrdersModule.tsx",
  "app/components/PurchaseReceiptsModule.tsx",
  "app/components/SupplierInvoicesModule.tsx",
].map((path) => readFileSync(path, "utf8"));

test("la validación de acceso termina si el servicio no responde", async () => {
  const pending = new Promise<never>(() => undefined);
  await assert.rejects(withAccessTimeout(pending, 5), AccessCheckTimeoutError);
  assert.equal(await withAccessTimeout(Promise.resolve("ok"), 50), "ok");
});

test("todas las consultas de identidad comparten recuperación y límite de espera", () => {
  assert.match(provider, /withAccessTimeout\(supabase\.auth\.getUser\(\)\)/);
  assert.match(provider, /withAccessTimeout\(supabase\s*\.from\("user_roles"\)/);
  assert.match(provider, /withAccessTimeout\(supabase\.from\("companies"\)/);
  assert.match(provider, /withAccessTimeout\(supabase\.from\("profiles"\)/);
  assert.match(provider, /withAccessTimeout\(supabase\s*\.from\("locations"\)/);
  assert.match(shell, /Reintentar acceso/);
  assert.match(shell, /Validando acceso…/);
});

test("las filas operativas son enfocables y se activan con Enter o espacio", () => {
  assert.equal(isKeyboardActivationKey("Enter"), true);
  assert.equal(isKeyboardActivationKey(" "), true);
  assert.equal(isKeyboardActivationKey("Tab"), false);
  assert.match(tableFoundation, /role="button" tabIndex=\{0\}/);
  assert.match(tableFoundation, /aria-label=\{label\}/);
  assert.match(tableFoundation, /interactiveTarget !== event\.currentTarget/);
  for (const source of operationalTables) {
    assert.doesNotMatch(source, /<tr[^>]*\bonClick=/, "queda una fila operativa accesible solo por puntero");
  }
});

test("los formularios laterales reservan espacio para mostrar completo el foco", () => {
  assert.match(
    styles,
    /\.ui-drawer__body \{[^}]*margin:14px -4px -4px;[^}]*padding:4px 6px 4px 4px;/,
  );
  assert.match(
    styles,
    /\.customer-drawer > \.ui-drawer__body \{[^}]*margin:14px -4px -4px;[^}]*padding:4px 6px 4px 4px;/,
  );
  assert.match(
    styles,
    /\.sales-quote-detail > \.ui-drawer__body \{[^}]*margin:14px -4px -4px;[^}]*padding:4px 6px 4px 4px;/,
  );
  assert.match(
    styles,
    /\.payroll-detail > \.ui-drawer__body \{[^}]*margin:12px -4px -4px;[^}]*padding:4px 6px 4px 4px;/,
  );
});
