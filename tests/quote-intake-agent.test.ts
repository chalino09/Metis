import assert from "node:assert/strict";
import test from "node:test";
import { quoteIntakeExtractionSchema } from "../app/lib/quote-intake-agent.ts";

test("quote intake accepts a bounded structured quotation request", () => {
  const parsed = quoteIntakeExtractionSchema.parse({
    intent: "quotation_request",
    confidence: 0.98,
    customer_hint: null,
    items: [{ raw_text: "10 sacos de Calcinit", quantity: 10, unit: "sacos", brand: null, presentation: null }],
  });
  assert.equal(parsed.items[0].quantity, 10);
});

test("quote intake rejects invented or invalid quantities", () => {
  assert.throws(() => quoteIntakeExtractionSchema.parse({
    intent: "quotation_request",
    confidence: 1,
    customer_hint: null,
    items: [{ raw_text: "Calcinit", quantity: 0, unit: null, brand: null, presentation: null }],
  }));
});
