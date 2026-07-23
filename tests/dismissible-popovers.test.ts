import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const hook = readFileSync("app/components/ui/use-dismissible-popover.ts", "utf8");
const inventory = readFileSync("app/components/SatrapyApp.tsx", "utf8");
const sales = readFileSync("app/components/SalesModule.tsx", "utf8");

test("los selectores flotantes se cierran con Escape y clic fuera", () => {
  assert.match(hook, /event\.key === "Escape"/);
  assert.match(hook, /!container\.contains\(event\.target\)/);
  assert.match(hook, /document\.addEventListener\("pointerdown"/);
});

test("reabastecimiento, transferencias y clientes usan el cierre compartido", () => {
  assert.equal((inventory.match(/useDismissiblePopover\(productPickerRef, productPickerOpen/g) ?? []).length, 2);
  assert.match(sales, /useDismissiblePopover\(customerPickerRef, customerPickerOpen/);
  assert.match(inventory, /aria-controls="inventory-replenishment-product-options"/);
  assert.match(inventory, /aria-controls="inventory-transfer-product-options"/);
  assert.match(sales, /aria-controls="pos-customer-options"/);
});
