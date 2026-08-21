import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const sales = readFileSync("app/components/SalesModule.tsx", "utf8");
const customerMaster = readFileSync("supabase/migrations/202607130011_customer_master_canonical.sql", "utf8");

test("clientes separa condición de venta de saldo pendiente", () => {
  assert.match(sales, /<th>Condición de venta<\/th>/);
  assert.match(sales, /<th className="number-cell">Saldo pendiente<\/th>/);
  assert.match(sales, /<th className="number-cell">Crédito disponible<\/th>/);
  assert.match(sales, /Crédito · \$\{row\.credit_term_days\} días/);
  assert.match(sales, /<Badge>Solo contado<\/Badge>/);
  assert.match(customerMaster, /sum\(r\.outstanding_amount\).*outstanding/);
  assert.match(customerMaster, /'credit_enabled',p\.credit_enabled/);
});

test("el crédito requiere límite y plazo válidos", () => {
  assert.match(customerMaster, /p_credit_enabled and \(coalesce\(p_credit_limit,0\)<=0 or coalesce\(p_credit_term_days,0\)<=0\)/);
  assert.match(customerMaster, /El crédito requiere límite y plazo mayores a cero\./);
});
