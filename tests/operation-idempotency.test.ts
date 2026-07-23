import assert from "node:assert/strict";
import test from "node:test";
import { OperationIdempotencyKeys } from "../app/lib/operation-idempotency.ts";

test("reutiliza la clave mientras la operación conserve la misma huella", () => {
  let sequence = 0;
  const keys = new OperationIdempotencyKeys(() => `key-${++sequence}`);
  assert.equal(keys.get("receivable-payment", "customer-1:100"), "key-1");
  assert.equal(keys.get("receivable-payment", "customer-1:100"), "key-1");
  assert.equal(sequence, 1);
});

test("renueva la clave cuando cambian los datos o la operación termina", () => {
  let sequence = 0;
  const keys = new OperationIdempotencyKeys(() => `key-${++sequence}`);
  assert.equal(keys.get("sale", "cart-1:revision-1"), "key-1");
  assert.equal(keys.get("sale", "cart-1:revision-2"), "key-2");
  keys.clear("sale");
  assert.equal(keys.get("sale", "cart-1:revision-2"), "key-3");
});
