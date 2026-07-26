import "server-only";

type AlphaFileInput = Pick<File, "name" | "arrayBuffer">;
type Cell = string | number | Date | null | undefined;

export type CollaboratorStagingRow = {
  row_number: number;
  source_file: string;
  detected_type: "collaborators";
  raw_data: { cells: Cell[] };
  normalized_data: Record<string, unknown>;
  validation_status: "valid" | "warning" | "error";
};

export type CollaboratorStagingError = {
  severity: "error" | "warning";
  error_code: string;
  message: string;
  row_number: number | null;
  alpha_sku: null;
  location_code: null;
  context_key: string | null;
};

export type AlphaCollaboratorMigrationPayload = {
  recognized: boolean;
  fileName: string;
  fileHash: string;
  snapshotDate: string | null;
  rows: CollaboratorStagingRow[];
  errors: CollaboratorStagingError[];
};

type Header = {
  rowIndex: number;
  externalId?: number;
  displayName?: number;
  jobTitle?: number;
  employmentStatus?: number;
  hiredAt?: number;
  terminatedAt?: number;
  paymentFrequency?: number;
  basePay?: number;
  effectiveFrom?: number;
  paymentMethod?: number;
};

const collaboratorFileName = /^(?:cata|cat)_(?:emp|emple|empleado|colab|colaborador)_.+\.(?:xlsx?|csv)$/i;

const aliases: Record<Exclude<keyof Header, "rowIndex">, string[]> = {
  externalId: ["codigo empleado", "clave empleado", "cve empleado", "id empleado", "no empleado", "numero empleado", "num empleado", "empleado id", "cve emp", "num emp", "no emp", "codigo", "clave"],
  displayName: ["nombre completo", "nombre empleado", "nombre colaborador", "nom empleado", "nom emp", "nombre"],
  jobTitle: ["puesto", "cargo", "departamento"],
  employmentStatus: ["estatus", "estado", "situacion", "status"],
  hiredAt: ["fecha de ingreso", "fecha ingreso", "fecha de alta", "f ingreso", "feingreso", "fingreso", "f alta", "ingreso", "alta"],
  terminatedAt: ["fecha de baja", "f baja", "fbaja", "baja"],
  paymentFrequency: ["periodicidad de pago", "periodicidad", "frecuencia de pago", "frecuencia"],
  basePay: ["pago base", "sueldo base", "sueldo semanal", "salario semanal", "importe pago", "salario", "sueldo"],
  effectiveFrom: ["vigente desde", "vigencia de pago", "fecha vigencia", "fecha salario", "fecha sueldo"],
  paymentMethod: ["forma de pago", "metodo de pago", "método de pago"],
};

export async function parseAlphaCollaboratorMigration(file: AlphaFileInput): Promise<AlphaCollaboratorMigrationPayload> {
  const bytes = await file.arrayBuffer();
  const fileHash = await hash(bytes);
  const empty = (): AlphaCollaboratorMigrationPayload => ({ recognized: collaboratorFileName.test(file.name), fileName: file.name, fileHash, snapshotDate: null, rows: [], errors: [] });
  try {
    const XLSX = await import("xlsx");
    const workbook = XLSX.read(bytes, { type: "array", raw: false, cellDates: true });
    const sheet = workbook.Sheets[workbook.SheetNames[0]];
    if (!sheet) return withError(empty(), "FORMATO_NO_COMPATIBLE", "El archivo no contiene una hoja legible.");
    const rows = XLSX.utils.sheet_to_json<Cell[]>(sheet, { header: 1, raw: false, defval: "" });
    const header = findHeader(rows);
    const snapshotDate = extractSnapshotDate(rows);
    const payload = empty();
    payload.snapshotDate = snapshotDate;
    payload.recognized = payload.recognized || Boolean(header);
    if (!header) return withError(payload, "ENCABEZADOS_COLABORADORES_FALTANTES", "No se identificó un catálogo de colaboradores: se requieren al menos código y nombre, junto con datos laborales o de pago.");

    const missing = [
      header.externalId === undefined ? "Código de origen" : null,
      header.displayName === undefined ? "Nombre" : null,
      header.hiredAt === undefined ? "Fecha de ingreso" : null,
      header.basePay === undefined ? "Pago base" : null,
    ].filter(Boolean);
    if (missing.length) return withError(payload, "CAMPOS_COLABORADORES_FALTANTES", `Faltan columnas obligatorias: ${missing.join(", ")}.`);

    const seenExternalIds = new Set<string>();
    for (let index = header.rowIndex + 1; index < rows.length; index += 1) {
      const row = rows[index] ?? [];
      const externalId = text(valueAt(row, header.externalId));
      const displayName = text(valueAt(row, header.displayName));
      const hiredAt = parseDate(valueAt(row, header.hiredAt));
      const basePay = parseAmount(valueAt(row, header.basePay));
      if (!externalId && !displayName && !hiredAt && basePay === null) continue;

      const rowNumber = index + 1;
      const rowIssues: CollaboratorStagingError[] = [];
      const addError = (errorCode: string, message: string) => rowIssues.push(issue("error", errorCode, message, rowNumber, externalId || null));
      if (!externalId) addError("CODIGO_COLABORADOR_FALTANTE", "El colaborador no tiene código de origen.");
      if (!displayName) addError("NOMBRE_COLABORADOR_FALTANTE", "El colaborador no tiene nombre.");
      if (!hiredAt) addError("FECHA_INGRESO_INVALIDA", "El colaborador requiere una fecha de ingreso válida.");
      if (basePay === null || basePay < 0) addError("PAGO_BASE_INVALIDO", "El pago base debe ser un importe igual o mayor a cero.");
      if (externalId && seenExternalIds.has(externalId)) addError("CODIGO_COLABORADOR_DUPLICADO", `El código de origen ${externalId} aparece más de una vez en el archivo.`);
      if (externalId) seenExternalIds.add(externalId);

      const status = parseEmploymentStatus(valueAt(row, header.employmentStatus));
      if (!status) addError("ESTADO_COLABORADOR_INVALIDO", "El estado debe ser activo o inactivo.");
      const terminatedAt = parseDate(valueAt(row, header.terminatedAt));
      if (status === "inactive" && !terminatedAt) addError("FECHA_BAJA_FALTANTE", "Un colaborador inactivo requiere fecha de baja.");
      if (hiredAt && terminatedAt && terminatedAt < hiredAt) addError("FECHA_BAJA_INVALIDA", "La fecha de baja no puede ser anterior al ingreso.");

      const frequency = parseFrequency(valueAt(row, header.paymentFrequency));
      if (header.paymentFrequency !== undefined && text(valueAt(row, header.paymentFrequency)) && !frequency) {
        addError("PERIODICIDAD_INVALIDA", "La periodicidad debe ser semanal, quincenal o mensual.");
      }
      const explicitEffectiveFrom = parseDate(valueAt(row, header.effectiveFrom));
      if (header.effectiveFrom !== undefined && text(valueAt(row, header.effectiveFrom)) && !explicitEffectiveFrom) {
        addError("VIGENCIA_PAGO_INVALIDA", "La vigencia del pago no tiene una fecha válida.");
      }

      const paymentMethod = parsePaymentMethod(valueAt(row, header.paymentMethod));
      if (header.paymentMethod !== undefined && text(valueAt(row, header.paymentMethod)) && !paymentMethod) {
        addError("FORMA_PAGO_INVALIDA", "La forma de pago debe ser transferencia, efectivo u otro.");
      }

      payload.rows.push({
        row_number: rowNumber,
        source_file: file.name,
        detected_type: "collaborators",
        raw_data: { cells: row },
        normalized_data: {
          sourceRowNumber: rowNumber,
          alphaExternalId: externalId || null,
          displayName: displayName || null,
          jobTitle: nullable(text(valueAt(row, header.jobTitle))),
          employmentStatus: status ?? "active",
          hiredAt,
          terminatedAt: status === "inactive" ? terminatedAt : null,
          paymentFrequency: frequency,
          basePayAmount: basePay,
          effectiveFrom: explicitEffectiveFrom,
          paymentMethod,
        },
        validation_status: rowIssues.some((entry) => entry.severity === "error") ? "error" : rowIssues.length ? "warning" : "valid",
      });
      payload.errors.push(...rowIssues);
    }
    if (!payload.rows.length) payload.errors.push(issue("error", "SIN_COLABORADORES", "No se encontraron colaboradores en el archivo.", null, null));
    return payload;
  } catch {
    return withError(empty(), "FORMATO_NO_COMPATIBLE", "No se pudo leer el archivo. Verifica que sea un CSV, XLS o XLSX compatible.");
  }
}

function findHeader(rows: Cell[][]): Header | null {
  for (let rowIndex = 0; rowIndex < Math.min(rows.length, 30); rowIndex += 1) {
    const cells = rows[rowIndex] ?? [];
    const normalizedCells = cells.map((cell) => normalized(text(cell)));
    const header: Header = { rowIndex };
    for (const [key, values] of Object.entries(aliases) as Array<[Exclude<keyof Header, "rowIndex">, string[]]>) {
      const column = normalizedCells.findIndex((cell) => values.some((alias) => matchesAlias(cell, alias)));
      if (column >= 0) header[key] = column;
    }
    const hasIdentity = header.externalId !== undefined && header.displayName !== undefined;
    const hasCollaboratorContext = header.hiredAt !== undefined || header.basePay !== undefined || header.paymentFrequency !== undefined || header.employmentStatus !== undefined || header.jobTitle !== undefined;
    if (hasIdentity && hasCollaboratorContext) return header;
  }
  return null;
}

function matchesAlias(candidate: string, alias: string) {
  const normalizedAlias = normalized(alias);
  if (!normalizedAlias.includes(" ")) return candidate === normalizedAlias;
  return candidate === normalizedAlias || candidate.startsWith(`${normalizedAlias} `) || candidate.endsWith(` ${normalizedAlias}`);
}

function parseEmploymentStatus(value: Cell): "active" | "inactive" | null {
  const normalizedValue = normalized(text(value));
  if (!normalizedValue || ["activo", "activa", "alta", "1", "si", "true"].includes(normalizedValue)) return "active";
  if (["inactivo", "inactiva", "baja", "0", "no", "false"].includes(normalizedValue)) return "inactive";
  return null;
}

function parseFrequency(value: Cell): "weekly" | "biweekly" | "monthly" | null {
  const normalizedValue = normalized(text(value));
  if (!normalizedValue) return null;
  if (["semanal", "weekly"].includes(normalizedValue)) return "weekly";
  if (["quincenal", "bisemanal", "biweekly"].includes(normalizedValue)) return "biweekly";
  if (["mensual", "monthly"].includes(normalizedValue)) return "monthly";
  return null;
}

function parsePaymentMethod(value: Cell): "transfer" | "cash" | "other" | null {
  const normalizedValue = normalized(text(value));
  if (!normalizedValue) return null;
  if (["transferencia", "transfer", "banco", "bancario", "deposito"].includes(normalizedValue)) return "transfer";
  if (["efectivo", "cash"].includes(normalizedValue)) return "cash";
  if (["otro", "other", "cheque"].includes(normalizedValue)) return "other";
  return null;
}

function parseAmount(value: Cell) {
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  const raw = text(value).replace(/[$\s]/g, "");
  if (!raw) return null;
  const negative = raw.startsWith("(") && raw.endsWith(")");
  const bare = raw.replace(/[()]/g, "");
  const comma = bare.lastIndexOf(",");
  const dot = bare.lastIndexOf(".");
  const canonical = comma > dot
    ? bare.replace(/\./g, "").replace(",", ".")
    : bare.replace(/,/g, "");
  const amount = Number(canonical);
  return Number.isFinite(amount) ? (negative ? -amount : amount) : null;
}

function parseDate(value: Cell) {
  if (value instanceof Date && !Number.isNaN(value.getTime())) return value.toISOString().slice(0, 10);
  if (typeof value === "number" && Number.isFinite(value)) {
    const date = new Date(Date.UTC(1899, 11, 30 + Math.floor(value)));
    return date.toISOString().slice(0, 10);
  }
  const raw = text(value);
  let match = raw.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/);
  if (match) return dateFromParts(Number(match[3]), Number(match[2]), Number(match[1]));
  match = raw.match(/^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$/);
  if (match) return dateFromParts(Number(match[1]), Number(match[2]), Number(match[3]));
  return null;
}

function dateFromParts(year: number, month: number, day: number) {
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return date.toISOString().slice(0, 10);
}

function extractSnapshotDate(rows: Cell[][]) {
  for (const row of rows.slice(0, 15)) {
    for (let column = 0; column < row.length; column += 1) {
      const label = normalized(text(row[column]));
      if (!/(fecha de corte|corte|fecha reporte|fecha del reporte)/.test(label)) continue;
      const inline = parseDate(row[column]);
      const adjacent = parseDate(row[column + 1]);
      if (inline) return inline;
      if (adjacent) return adjacent;
    }
  }
  return null;
}

function withError(payload: AlphaCollaboratorMigrationPayload, errorCode: string, message: string) {
  payload.errors.push(issue("error", errorCode, message, null, null));
  return payload;
}

function issue(severity: "error" | "warning", errorCode: string, message: string, rowNumber: number | null, contextKey: string | null): CollaboratorStagingError {
  return { severity, error_code: errorCode, message, row_number: rowNumber, alpha_sku: null, location_code: null, context_key: contextKey };
}

function valueAt(row: Cell[], column: number | undefined) { return column === undefined ? null : row[column]; }
function text(value: Cell) { return String(value ?? "").replace(/\s+/g, " ").trim(); }
function nullable(value: string) { return value || null; }
function normalized(value: string) { return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(); }
async function hash(input: ArrayBuffer) { const digest = await crypto.subtle.digest("SHA-256", input); return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join(""); }
