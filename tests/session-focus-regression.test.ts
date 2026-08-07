import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const provider = readFileSync("app/components/SatrapyProvider.tsx", "utf8");
const route = readFileSync("app/components/SatrapyApp.tsx", "utf8");

test("recuperar la misma sesión al volver a foco no reinicia el espacio de trabajo", () => {
  assert.match(provider, /const appStateRef = useRef<SatrapyAppState \| null>\(null\);/);
  assert.match(provider, /if \(event === "SIGNED_IN" && session\?\.user\.id === appStateRef\.current\?\.userId\) return;/);
  assert.doesNotMatch(provider, /void loadSession\(event === "SIGNED_IN" \|\| event === "SIGNED_OUT"\)/);
});

test("la ruta permanece montada mientras una identidad válida se revalida", () => {
  assert.match(route, /if \(!appState\) return null;/);
  assert.doesNotMatch(route, /if \(loading \|\| !appState\) return null;/);
});

test("un cierre de sesión todavía elimina la identidad local", () => {
  assert.match(provider, /if \(event === "SIGNED_OUT"\) \{\s*clearIdentity\(\);\s*setAccessIssue\(null\);\s*setLoading\(false\);/);
});
