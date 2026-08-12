import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const sourcePath = new URL("../app/components/SatrapyApp.tsx", import.meta.url);
const migrationPath = new URL("../supabase/migrations/202608080001_company_product_experience.sql", import.meta.url);

test("la alta de empresa queda reservada a Superadmin y empieza en core", async () => {
  const [source, migration] = await Promise.all([readFile(sourcePath, "utf8"), readFile(migrationPath, "utf8")]);

  assert.match(source, /isSuperAdmin && <CreateCompanyAction/);
  assert.match(source, /rpc\("create_company"/);
  assert.match(source, /La empresa inicia vacía y en Satrapy completo/);
  assert.match(source, /idempotencyKeys\.get\("create_company"/);
  assert.match(migration, /create or replace function public\.create_company/);
  assert.match(migration, /not public\.is_super_admin\(\)/);
  assert.match(migration, /'core'/);
  assert.match(migration, /'company\.created'/);
});
