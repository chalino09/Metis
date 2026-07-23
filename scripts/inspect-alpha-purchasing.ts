import { readFile, readdir } from "node:fs/promises";
import { resolve } from "node:path";
import { parseAlphaPurchasingMigration } from "../app/lib/alpha-purchasing-migration.ts";

const directory = process.env.ALPHA_ERP_IMPORT_DIR;
if (!directory) throw new Error("ALPHA_ERP_IMPORT_DIR no está configurado.");

const allowed = /^(?:cata_prv|rpcon2|lfchvenc|pag_det)_.+\.xlsx?$/i;
const names = (await readdir(directory)).filter((name) => allowed.test(name)).sort();
const files = await Promise.all(names.map(async (name) => new File([await readFile(resolve(directory, name))], name)));
const payload = await parseAlphaPurchasingMigration(files);

console.log(JSON.stringify({
  cutoffDate: payload.cutoffDate,
  files: payload.files,
  summary: payload.summary,
  distributions: {
    purchase_order_statuses: Object.fromEntries([...new Set(payload.purchaseOrders.map((row) => row.source_status))].sort().map((status) => [status, payload.purchaseOrders.filter((row) => row.source_status === status).length])),
    purchase_approval_statuses: Object.fromEntries([...new Set(payload.purchaseOrders.map((row) => row.source_approval_status))].sort().map((status) => [status, payload.purchaseOrders.filter((row) => row.source_approval_status === status).length])),
    purchase_currencies: Object.fromEntries([...new Set(payload.purchaseOrders.map((row) => row.source_currency ?? ""))].sort().map((currency) => [currency, payload.purchaseOrders.filter((row) => (row.source_currency ?? "") === currency).length])),
    payable_currencies: Object.fromEntries([...new Set(payload.payableDocuments.map((row) => row.source_currency ?? ""))].sort().map((currency) => [currency, payload.payableDocuments.filter((row) => (row.source_currency ?? "") === currency).length])),
    non_positive_payables: payload.payableDocuments.filter((row) => row.outstanding_amount <= 0).map((row) => ({ folio: row.folio, supplier_external_code: row.supplier_external_code, outstanding_amount: row.outstanding_amount })),
  },
  differences: payload.differences.reduce<Record<string, number>>((totals, difference) => {
    totals[difference.difference_code] = (totals[difference.difference_code] ?? 0) + 1;
    return totals;
  }, {}),
}));
