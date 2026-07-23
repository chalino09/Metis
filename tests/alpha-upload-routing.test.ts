import assert from "node:assert/strict";
import test from "node:test";
import { alphaUploadLabel, classifyAlphaUpload, isCustomerAlphaUpload, isPurchasingAlphaUpload, isStandardAlphaUpload } from "../app/lib/alpha-upload-routing.ts";
import { purchasingUploadPackageState } from "../app/lib/purchasing-upload-package.ts";

test("clasifica todos los nombres de archivo Alpha admitidos", () => {
  assert.equal(classifyAlphaUpload("cata_prd_20260714.xls"), "products");
  assert.equal(classifyAlphaUpload("reexic2_CORTE.xlsx"), "inventory");
  assert.equal(classifyAlphaUpload("rprecprd_LISTAS.xls"), "prices");
  assert.equal(classifyAlphaUpload("rcostprd_COSTOS.xlsx"), "costs");
  assert.equal(classifyAlphaUpload("cata_cte_CLIENTES.xls"), "customers");
  assert.equal(classifyAlphaUpload("cat_ctee_CONDICIONES.xlsx"), "credit_terms");
  assert.equal(classifyAlphaUpload("lis_sal_SALDOS.xls"), "ledger");
  assert.equal(classifyAlphaUpload("cob_cte_COBRANZA.xlsx"), "collections");
  assert.equal(classifyAlphaUpload("cata_prv_PROVEEDORES.xls"), "suppliers");
  assert.equal(classifyAlphaUpload("rpcon2_ORDENES.xlsx"), "purchase_orders");
  assert.equal(classifyAlphaUpload("lfchvenc_CXP.xls"), "payable_documents");
  assert.equal(classifyAlphaUpload("pag_det_PAGOS.xlsx"), "supplier_payments");
});

test("separa archivos estándar, paquete de clientes y nombres desconocidos", () => {
  assert.equal(isStandardAlphaUpload(classifyAlphaUpload("rprecprd_LISTAS.xls")), true);
  assert.equal(isCustomerAlphaUpload(classifyAlphaUpload("lis_sal_SALDOS.xls")), true);
  assert.equal(isPurchasingAlphaUpload(classifyAlphaUpload("rpcon2_ORDENES.xls")), true);
  assert.equal(classifyAlphaUpload("productos-final.xlsx"), "unrecognized");
  assert.equal(alphaUploadLabel("unrecognized"), "Archivo no reconocido");
});

test("Compras/CxP solo queda completo con un archivo de cada tipo requerido", () => {
  const partial = purchasingUploadPackageState([
    "cata_prv_20260708.xls",
    "rpcon2_20260708.xls",
  ]);
  assert.equal(partial.complete, false);
  assert.equal(partial.detected, 2);
  assert.deepEqual(partial.missing, ["payable_documents", "supplier_payments"]);

  const complete = purchasingUploadPackageState([
    "cata_prv_20260708.xls",
    "rpcon2_20260708.xls",
    "lfchvenc_20260708.xls",
    "pag_det_20260708.xls",
  ]);
  assert.equal(complete.complete, true);
  assert.equal(complete.detected, 4);

  const duplicated = purchasingUploadPackageState([
    "cata_prv_20260708.xls",
    "cata_prv_20260709.xls",
    "rpcon2_20260708.xls",
    "lfchvenc_20260708.xls",
    "pag_det_20260708.xls",
  ]);
  assert.equal(duplicated.complete, false);
  assert.deepEqual(duplicated.duplicates, ["suppliers"]);
});
