import assert from "node:assert/strict";
import test from "node:test";
import { receiptToday, validatePurchaseReceipt } from "../app/lib/restaurant/purchase-receipt-validation.ts";

const valid = () => ({ supplierId: "supplier", locationId: "location", receiptDate: "2026-09-08", lines: [{ name: "Aceite", quantity: "5", unit_cost: "42", lot_controlled: false, lots: [] as { lot_code: string; expiration_date: string; quantity: string }[] }] });
const check = (draft: ReturnType<typeof valid>) => validatePurchaseReceipt(draft, "2026-09-08");

test("5 L at $42 can be confirmed without a previous purchase, reference or notes", () => {
  assert.deepEqual(check(valid()), []);
  const draft = valid();
  draft.lines[0].unit_cost = "0";
  assert.deepEqual(check(draft), []);
});

test("an incomplete header identifies supplier and destination before line errors", () => {
  const draft = valid();
  draft.supplierId = ""; draft.locationId = "";
  assert.deepEqual(check(draft).map(issue => issue.field), ["supplierId", "locationId"]);
  draft.supplierId = "supplier";
  assert.equal(check(draft)[0].field, "locationId");
});

test("blank, nonfinite and negative amounts never reach confirmation", () => {
  for (const value of ["", " ", "NaN", "Infinity", "-1"]) {
    const draft = valid(); draft.lines[0].unit_cost = value;
    assert.equal(check(draft)[0].field, "price-0", value);
  }
  for (const value of ["", " ", "NaN", "Infinity", "-1", "0"]) {
    const draft = valid(); draft.lines[0].quantity = value;
    assert.equal(check(draft)[0].field, "quantity-0", value);
  }
});

test("invalid and future receipt dates are visible validation errors", () => {
  for (const value of ["", "2026-02-30", "2026-09-09"]) {
    const draft = valid(); draft.receiptDate = value;
    assert.equal(check(draft)[0].field, "receiptDate", value);
  }
});

test("today uses the local calendar after UTC midnight", () => {
  const prior = process.env.TZ;
  try {
    process.env.TZ = "America/Mexico_City";
    assert.equal(receiptToday(new Date("2026-09-09T03:00:00Z")), "2026-09-08");
  } finally { if (prior === undefined) delete process.env.TZ; else process.env.TZ = prior; }
});

test("receipt size follows the RPC's 1–100 line boundary", () => {
  const draft = valid(); draft.lines = [];
  assert.equal(check(draft)[0].field, "lines");
  draft.lines = Array.from({ length: 100 }, () => valid().lines[0]);
  assert.deepEqual(check(draft), []);
  draft.lines.push(valid().lines[0]);
  assert.equal(check(draft)[0].field, "lines");
});

test("lot errors point to the specific missing data and enforce the received total", () => {
  const draft = valid(); const line = draft.lines[0]; line.lot_controlled = true;
  line.lots = [{ lot_code: "", expiration_date: "", quantity: "5" }];
  assert.deepEqual(check(draft).map(issue => issue.field), ["lot-code-0-0", "lot-date-0-0"]);
  line.lots = [{ lot_code: "A", expiration_date: "2027-01-01", quantity: "3" }, { lot_code: "B", expiration_date: "2027-02-01", quantity: "2" }];
  assert.deepEqual(check(draft), []);
  line.lots[1].quantity = "1";
  assert.match(check(draft)[0].message, /sumar 5/);
  line.lots[1].quantity = "NaN";
  assert.equal(check(draft)[0].field, "lot-quantity-0-1");
});
