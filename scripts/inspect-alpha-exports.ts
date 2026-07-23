import { readFile, readdir } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { parseAlphaWorkbook } from "../app/lib/alpha.ts";

const folder = process.argv[2] ?? process.env.ALPHA_ERP_IMPORT_DIR;

if (!folder) {
  throw new Error("Indica la carpeta Alpha como argumento o define ALPHA_ERP_IMPORT_DIR.");
}

const compatible = /^(cata_prd|reexic2|rprecprd|rcostprd)_.+\.xlsx?$/i;
const entries = await readdir(folder, { withFileTypes: true });
const files = entries.filter((entry) => entry.isFile() && compatible.test(entry.name)).map((entry) => entry.name).sort();

for (const file of files) {
  // This reads source bytes into memory only. It never writes to the folder.
  const bytes = await readFile(resolve(folder, file));
  const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const parsed = await parseAlphaWorkbook(buffer, basename(file), "local_development");
  console.log(JSON.stringify({
    file: parsed.fileName,
    type: parsed.importKind,
    products: parsed.products.length,
    taxConfigured: parsed.products.filter((product) => product.taxCategoryCode && product.taxRate !== null).length,
    inventory: parsed.inventory.length,
    prices: parsed.prices.length,
    costs: parsed.costs.length,
    locations: parsed.locations.length,
    errors: parsed.issues.filter((issue) => issue.severity === "error").length,
    warnings: parsed.issues.filter((issue) => issue.severity === "warning").length,
    issueCodes: [...new Set(parsed.issues.map((issue) => issue.code))].sort(),
  }));
}
