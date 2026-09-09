type ReceiptLot = {
  lot_code: string;
  expiration_date: string;
  quantity: string;
};
type ReceiptLine = {
  name: string;
  quantity: string;
  unit_cost: string;
  lot_controlled: boolean;
  lots: ReceiptLot[];
};
type ReceiptDraft = {
  supplierId: string;
  locationId: string;
  receiptDate: string;
  lines: ReceiptLine[];
};
export type ReceiptIssue = { field: string; message: string };

export function receiptToday(now = new Date()): string {
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}

function validDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T12:00:00Z`);
  return (
    Number.isFinite(parsed.getTime()) &&
    parsed.toISOString().slice(0, 10) === value
  );
}

function validNumber(value: string, minimum: number): boolean {
  return (
    value.trim() !== "" &&
    Number.isFinite(Number(value)) &&
    Number(value) >= minimum
  );
}

/** The same checks protect review and confirmation; missing purchase history is not an error. */
export function validatePurchaseReceipt(
  draft: ReceiptDraft,
  today = receiptToday(),
): ReceiptIssue[] {
  const issues: ReceiptIssue[] = [];
  const add = (field: string, message: string) => {
    issues.push({ field, message });
  };
  if (!draft.supplierId)
    add("supplierId", "Selecciona un proveedor de la lista.");
  if (!draft.locationId)
    add(
      "locationId",
      "Selecciona la sucursal o almacén que recibirá los insumos.",
    );
  if (!validDate(draft.receiptDate))
    add("receiptDate", "Ingresa una fecha de recepción válida.");
  else if (draft.receiptDate > today)
    add("receiptDate", "La fecha de recepción no puede estar en el futuro.");
  if (!draft.lines.length)
    add("lines", "Agrega al menos un insumo a la entrada.");
  else if (draft.lines.length > 100)
    add(
      "lines",
      "Una entrada admite hasta 100 partidas. Divide esta entrega o usa el Centro de Migración.",
    );
  draft.lines.forEach((line, index) => {
    if (!validNumber(line.quantity, 0.000001))
      add(`quantity-${index}`, "Ingresa una cantidad mayor que cero.");
    if (!validNumber(line.unit_cost, 0))
      add(
        `price-${index}`,
        "Ingresa el precio de esta compra; puede ser cero.",
      );
    if (!line.lot_controlled) return;
    if (!line.lots.length)
      add(`lots-${index}`, `Agrega el lote y la caducidad de ${line.name}.`);
    line.lots.forEach((lot, lotIndex) => {
      if (!lot.lot_code.trim())
        add(
          `lot-code-${index}-${lotIndex}`,
          `Ingresa el código del lote ${lotIndex + 1}.`,
        );
      if (!validDate(lot.expiration_date))
        add(
          `lot-date-${index}-${lotIndex}`,
          `Ingresa la caducidad del lote ${lotIndex + 1}.`,
        );
      if (!validNumber(lot.quantity, 0.000001))
        add(
          `lot-quantity-${index}-${lotIndex}`,
          `Ingresa una cantidad mayor que cero para el lote ${lotIndex + 1}.`,
        );
    });
    if (
      line.lots.length &&
      validNumber(line.quantity, 0.000001) &&
      line.lots.every((lot) => validNumber(lot.quantity, 0.000001)) &&
      Math.abs(
        line.lots.reduce((sum, lot) => sum + Number(lot.quantity), 0) -
          Number(line.quantity),
      ) > 0.000001
    ) {
      add(
        `lot-quantity-${index}-0`,
        `Los lotes deben sumar ${line.quantity}, la cantidad recibida de ${line.name}.`,
      );
    }
  });
  return issues;
}
