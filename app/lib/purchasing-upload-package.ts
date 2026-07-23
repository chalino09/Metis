import { classifyAlphaUpload, isPurchasingAlphaUpload, type AlphaPurchasingFileKind } from "./alpha-upload-routing.ts";

export const REQUIRED_PURCHASING_UPLOAD_KINDS: AlphaPurchasingFileKind[] = [
  "suppliers",
  "purchase_orders",
  "payable_documents",
  "supplier_payments",
];

export function purchasingUploadPackageState(fileNames: string[]) {
  const detected = fileNames
    .map((fileName) => classifyAlphaUpload(fileName))
    .filter((kind): kind is AlphaPurchasingFileKind => isPurchasingAlphaUpload(kind));
  const unique = new Set(detected);
  return {
    complete: REQUIRED_PURCHASING_UPLOAD_KINDS.every((kind) => unique.has(kind)) && detected.length === REQUIRED_PURCHASING_UPLOAD_KINDS.length,
    detected: unique.size,
    missing: REQUIRED_PURCHASING_UPLOAD_KINDS.filter((kind) => !unique.has(kind)),
    duplicates: [...unique].filter((kind) => detected.filter((candidate) => candidate === kind).length > 1),
  };
}
