export function presentImportedSourceText(value: string) {
  return value
    .replace(/\bCliente Alpha\b/gi, "Cliente importado")
    .replace(/\bclientes Alpha\b/gi, "clientes importados")
    .replace(/\bProveedor Alpha\b/gi, "Proveedor importado")
    .replace(/\bproveedores Alpha\b/gi, "proveedores importados")
    .replace(/\bOrden Alpha\b/gi, "Orden importada")
    .replace(/\bórdenes Alpha\b/gi, "órdenes importadas")
    .replace(/\bSKU Alpha\b/gi, "SKU de origen")
    .replace(/\bRFC Alpha\b/gi, "RFC de origen")
    .replace(/\bclave Alpha\b/gi, "código de origen")
    .replace(/\bfuente Alpha\b/gi, "fuente importada")
    .replace(/\bAlpha ERP\b/gi, "origen de datos")
    .replace(/\bAlpha\b/gi, "origen de datos");
}
