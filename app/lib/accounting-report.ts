export const accountingReportTypes = ["general_ledger", "auxiliaries", "trial_balance", "income_statement", "balance_sheet", "cash_flow", "enterprise_consolidated"] as const;
export type AccountingReportType = (typeof accountingReportTypes)[number];

const labels: Record<AccountingReportType, string> = {
  general_ledger: "Mayor por cuenta",
  auxiliaries: "Auxiliares",
  trial_balance: "Balanza de comprobación",
  income_statement: "Estado de resultados",
  balance_sheet: "Balance general",
  cash_flow: "Entradas y salidas de efectivo",
  enterprise_consolidated: "Consolidado empresarial",
};

const descriptions: Record<AccountingReportType, string> = {
  general_ledger: "Movimientos y saldo acumulado por cuenta.",
  auxiliaries: "Compara cada cuenta de control con su operación.",
  trial_balance: "Saldos iniciales, cargos, abonos y saldo final.",
  income_statement: "Ingresos y gastos del periodo seleccionado.",
  balance_sheet: "Activos, pasivos y capital a la fecha final.",
  cash_flow: "Entradas y salidas agrupadas por cuenta y origen.",
  enterprise_consolidated: "Reporte oficial de toda la empresa; no aplica filtro por ubicación.",
};

const columnLabels: Record<string, string> = {
  entry_date: "Fecha", entry_number: "Póliza", entry_description: "Concepto", line_number: "Partida",
  code: "Cuenta", name: "Nombre", description: "Descripción", debit: "Debe", credit: "Haber",
  opening_balance: "Saldo anterior", running_balance: "Saldo", account_type: "Tipo", normal_balance: "Naturaleza", opening: "Inicial",
  ending_balance: "Saldo final", period_amount: "Importe del periodo", control_key: "Auxiliar", ledger_amount: "Contabilidad",
  auxiliary_amount: "Operación", difference: "Diferencia", category: "Categoría", source_type: "Origen",
  inflows: "Entradas", outflows: "Salidas", revenue: "Ingresos", expense: "Gastos", net_income: "Resultado del ejercicio",
  assets: "Activo", liabilities: "Pasivo", equity: "Capital y resultado", liabilities_and_equity: "Pasivo + capital",
  net_cash_flow: "Flujo neto", opening_debit: "Saldo inicial deudor", opening_credit: "Saldo inicial acreedor",
  ending_debit: "Saldo final deudor", ending_credit: "Saldo final acreedor",
};

const amountKeys = new Set(["debit", "credit", "opening_balance", "running_balance", "opening", "ending_balance", "period_amount", "ledger_amount", "auxiliary_amount", "difference", "inflows", "outflows", "revenue", "expense", "net_income", "assets", "liabilities", "equity", "liabilities_and_equity", "net_cash_flow", "opening_debit", "opening_credit", "ending_debit", "ending_credit"]);

export function isAccountingReportType(value: string): value is AccountingReportType { return accountingReportTypes.includes(value as AccountingReportType); }
export function accountingReportLabel(value: string) { return isAccountingReportType(value) ? labels[value] : "Estado financiero"; }
export function accountingReportDescription(value: string) { return isAccountingReportType(value) ? descriptions[value] : "Cifras calculadas desde el libro contable."; }
export function accountingReportColumnLabel(value: string) { return columnLabels[value] ?? value.replaceAll("_", " "); }
export function isAccountingAmountKey(value: string) { return amountKeys.has(value); }
export function accountingReportKeys(rows: Array<Record<string, unknown>>) { return rows.length ? Object.keys(rows[0]).filter((key) => !["account_id", "detail"].includes(key)) : []; }
