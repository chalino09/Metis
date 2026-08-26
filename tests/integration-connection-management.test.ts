import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const component=readFileSync("app/components/IntegrationCenter.tsx","utf8");
const route=readFileSync("app/api/integrations/connections/route.ts","utf8");

test("administrar una conexión conserva su configuración no sensible",()=>{
  assert.match(component,/function draftForItem/);
  assert.match(component,/configuration\.waba_id/);
  assert.match(component,/configuration\.phone_number_id/);
  assert.match(component,/configuration\.location_id/);
  assert.match(component,/setDraft\(draftForItem\(item,locations\)\)/);
});

test("los secretos existentes permanecen ocultos y no se reemplazan con vacíos",()=>{
  assert.match(component,/Guardado de forma segura\. Déjalo vacío para conservarlo\./);
  assert.match(component,/preserve_existing_secret:draft\.isExisting/);
  assert.match(route,/preserve_existing_secret\?:boolean/);
  assert.match(route,/select\("secret_ciphertext,nango_connection_id"\)/);
  assert.match(route,/Para reemplazar las credenciales, captura todos los campos secretos\./);
  assert.doesNotMatch(component,/secret_ciphertext/);
});
