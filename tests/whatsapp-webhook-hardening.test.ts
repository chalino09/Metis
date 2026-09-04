import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const route = readFileSync("app/api/integrations/meta/whatsapp/webhook/[companyId]/route.ts", "utf8");
const intake = readFileSync("app/lib/whatsapp-intake.ts", "utf8");
const migration = readFileSync("supabase/migrations/202608250001_whatsapp_webhook_recovery.sql", "utf8");
const baseMigration = readFileSync("supabase/migrations/202608220005_integration_center.sql", "utf8");

test("Meta webhook verifies signatures before parsing or processing", () => {
  assert.match(route, /x-hub-signature-256/);
  assert.match(route, /const appSecret=process\.env\.META_APP_SECRET\?\.trim\(\)\|\|secretsFor\(connections\[0\]\)\.app_secret/);
  assert.match(route, /createHmac\("sha256",appSecret\)/);
  assert.match(route, /timingSafeEqual/);
  assert.ok(route.indexOf("timingSafeEqual") < route.indexOf("JSON.parse(raw)"));
});

test("webhook receipt is persisted and atomically claimed before AI", () => {
  assert.match(migration, /payload jsonb not null/);
  assert.match(migration, /status='processing'/);
  assert.match(migration, /for update/);
  assert.match(intake, /register_integration_webhook/);
  assert.ok(intake.indexOf("admin.rpc(\"register_integration_webhook\"") < intake.indexOf("const prepared=await extractQuoteRequest"));
});

test("failed Meta deliveries can retry without duplicating quote intake", () => {
  assert.match(migration, /v_receipt\.status='retry_pending'/);
  assert.match(migration, /v_request\.status='failed'/);
  assert.match(migration, /set status='processing',error_message=null/);
  assert.match(route, /Promise\.allSettled/);
  assert.match(route, /status:503/);
  assert.match(baseMigration, /unique\(connection_id,provider_event_id\)/);
});
