"use client";

import { CircleDollarSign, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { Button, CurrencyInput, Field, Input, Modal, useToast } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";

export type PayrollAdjustmentKind = "overtime" | "absence" | "commission" | "bonus";

type CollaboratorOption = {
  id: string;
  code: string;
  display_name: string;
  position_name?: string | null;
  base_pay_amount: number | null;
  effective_from: string | null;
};

type AdjustmentRow = {
  id: string;
  collaboratorId: string;
  collaboratorCode: string;
  collaboratorName: string;
  basePayAmount: number | null;
  compensationEffectiveFrom: string | null;
  effectiveOn: string;
  payableHours: string;
  overtimeHourlyRate: string;
  absenceDays: string;
  absenceHours: string;
  amount: string;
  description: string;
};

type OperationalSettings = {
  payable_days_per_period: number | null;
  hours_per_workday: number | null;
  default_overtime_hourly_rate: number | null;
};

type StoredAdjustmentDraft = { rows?: AdjustmentRow[]; defaultDate?: string };

const copy: Record<PayrollAdjustmentKind, { title: string; singular: string; description: string }> = {
  overtime: {
    title: "Agregar horas extra",
    singular: "horas extra",
    description: "Captura las horas redondeadas y ajusta la tarifa individual cuando corresponda.",
  },
  absence: {
    title: "Registrar inasistencias",
    singular: "inasistencia",
    description: "Captura días, horas o ambos. Satrapy muestra el descuento antes de guardar.",
  },
  commission: {
    title: "Agregar comisiones",
    singular: "comisión",
    description: "Registra el importe autorizado y su referencia para cada colaborador.",
  },
  bonus: {
    title: "Agregar bonificaciones",
    singular: "bonificación",
    description: "Registra bonificaciones extraordinarias sin mezclarlas con comisiones.",
  },
};

const money = (value: number | null | undefined) =>
  `${new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN" }).format(Number(value ?? 0))} MXN`;

function emptyRow(option: CollaboratorOption, effectiveOn: string, overtimeHourlyRate: number): AdjustmentRow {
  return {
    id: crypto.randomUUID(),
    collaboratorId: option.id,
    collaboratorCode: option.code,
    collaboratorName: option.display_name,
    basePayAmount: option.base_pay_amount,
    compensationEffectiveFrom: option.effective_from,
    effectiveOn,
    payableHours: "",
    overtimeHourlyRate: overtimeHourlyRate.toFixed(2),
    absenceDays: "",
    absenceHours: "",
    amount: "",
    description: "",
  };
}

function readDraft(key: string): StoredAdjustmentDraft | null {
  if (typeof window === "undefined") return null;
  try {
    return JSON.parse(window.sessionStorage.getItem(key) ?? "null") as StoredAdjustmentDraft | null;
  } catch {
    window.sessionStorage.removeItem(key);
    return null;
  }
}

export function PayrollAdjustmentModal({
  companyId,
  kind,
  settings,
  period,
  onClose,
  onSaved,
}: {
  companyId: string;
  kind: PayrollAdjustmentKind;
  settings: OperationalSettings;
  period: { starts_on: string; ends_on: string };
  onClose: () => void;
  onSaved: () => Promise<void>;
}) {
  const { toast } = useToast();
  const draftStorageKey = `satrapy:payroll-adjustment:${companyId}:${kind}:${period.starts_on}:${period.ends_on}`;
  const [storedDraft] = useState(() => readDraft(draftStorageKey));
  const [rows, setRows] = useState<AdjustmentRow[]>(() => Array.isArray(storedDraft?.rows) ? storedDraft.rows : []);
  const [query, setQuery] = useState("");
  const [debounced, setDebounced] = useState("");
  const [options, setOptions] = useState<CollaboratorOption[]>([]);
  const [searching, setSearching] = useState(false);
  const [searchOpen, setSearchOpen] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [lastAddedName, setLastAddedName] = useState("");
  const [saving, setSaving] = useState(false);
  const [defaultDate, setDefaultDate] = useState(() => {
    if (storedDraft?.defaultDate) return storedDraft.defaultDate;
    const today = new Date().toISOString().slice(0, 10);
    return today >= period.starts_on && today <= period.ends_on ? today : period.ends_on;
  });
  const requestId = useRef(0);
  const firstInvalidRef = useRef<HTMLInputElement | null>(null);
  const saveRef = useRef<() => Promise<void>>(async () => undefined);

  useEffect(() => {
    window.sessionStorage.setItem(draftStorageKey, JSON.stringify({ rows, defaultDate }));
  }, [defaultDate, draftStorageKey, rows]);

  useEffect(() => {
    function saveWithKeyboard(event: KeyboardEvent) {
      if (!(event.metaKey || event.ctrlKey) || event.key !== "Enter" || event.repeat || event.isComposing || saving) return;
      event.preventDefault();
      void saveRef.current();
    }
    window.addEventListener("keydown", saveWithKeyboard);
    return () => window.removeEventListener("keydown", saveWithKeyboard);
  }, [saving]);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const next = query.trim();
      setDebounced(next);
      setSearching(next.length >= 2);
      if (next.length < 2) setOptions([]);
    }, 250);
    return () => window.clearTimeout(timer);
  }, [query]);

  useEffect(() => {
    if (debounced.length < 2) return;
    const current = ++requestId.current;
    void getSupabaseClient()
      .rpc("search_collaborators", {
        p_company_id: companyId,
        p_query: debounced,
        p_status: "active",
        p_page: 1,
        p_page_size: 20,
      })
      .then(({ data, error }) => {
        if (current !== requestId.current) return;
        setSearching(false);
        setSearchError(error?.message ?? null);
        setOptions((data as { items?: CollaboratorOption[] } | null)?.items ?? []);
      });
  }, [companyId, debounced]);

  const availableOptions = useMemo(
    () => options.filter(option => !rows.some(row => row.collaboratorId === option.id)),
    [options, rows],
  );

  function addCollaborator(option: CollaboratorOption) {
    if (rows.length >= 100) {
      toast({ title: "Límite del lote alcanzado", description: "Guarda este lote antes de agregar más colaboradores.", tone: "info" });
      return;
    }
    setRows(current => [...current, emptyRow(option, defaultDate, Number(settings.default_overtime_hourly_rate ?? 50))]);
    setLastAddedName(`${option.display_name} agregado al lote.`);
    setQuery("");
    setDebounced("");
    setOptions([]);
    setSearchOpen(false);
    setSearchError(null);
  }

  function updateRow(id: string, patch: Partial<AdjustmentRow>) {
    setRows(current => current.map(row => row.id === id ? { ...row, ...patch } : row));
  }

  function rateFor(row: AdjustmentRow) {
    const applicable = Boolean(
      row.basePayAmount !== null &&
      row.compensationEffectiveFrom &&
      row.compensationEffectiveFrom <= row.effectiveOn &&
      settings.payable_days_per_period &&
      settings.hours_per_workday,
    );
    if (!applicable) return { daily: null, hourly: null };
    const daily = Number(row.basePayAmount) / Number(settings.payable_days_per_period);
    return { daily, hourly: daily / Number(settings.hours_per_workday) };
  }

  const previews = rows.map(row => {
    const rates = rateFor(row);
    if (kind === "overtime") {
      const payable = Number(row.payableHours);
      const hourlyRate = Number(row.overtimeHourlyRate);
      return {
        amount: hourlyRate > 0 && payable > 0 ? hourlyRate * payable : null,
        label: hourlyRate > 0 ? `${money(hourlyRate)} por hora extra` : "Completa la tarifa por hora",
        detail: hourlyRate > 0 && payable > 0
          ? `${payable.toLocaleString("es-MX")} h × ${money(hourlyRate)} = ${money(hourlyRate * payable)}`
          : "Captura las horas redondeadas para ver el importe",
      };
    }
    if (kind === "absence") {
      const days = Number(row.absenceDays || 0);
      const hours = Number(row.absenceHours || 0);
      const hoursPerDay = Number(settings.hours_per_workday || 0);
      const dayHours = days * hoursPerDay;
      const totalHours = dayHours + hours;
      const amount = rates.daily !== null && rates.hourly !== null && days + hours > 0
        ? rates.daily * days + rates.hourly * hours
        : null;
      const dayPart = days > 0 ? `${days.toLocaleString("es-MX")} ${days === 1 ? "día" : "días"} (${dayHours.toLocaleString("es-MX")} h)` : "";
      const hourPart = hours > 0 ? `${hours.toLocaleString("es-MX")} h` : "";
      return {
        amount,
        label: days + hours > 0 ? [dayPart, hourPart].filter(Boolean).join(" + ") : "Completa días u horas",
        detail: amount !== null ? `Total equivalente: ${totalHours.toLocaleString("es-MX")} h · Descuento ${money(amount)}` : "Importe por calcular",
      };
    }
    const amount = Number(row.amount);
    return {
      amount: Number.isFinite(amount) && amount > 0 ? amount : null,
      label: amount > 0 ? money(amount) : "Completa el importe",
      detail: kind === "commission" ? "Suma como comisión" : "Suma como bonificación",
    };
  });

  function isInvalid(row: AdjustmentRow) {
    if (!row.effectiveOn) return true;
    if (kind === "overtime") return !(Number(row.payableHours) > 0) || !(Number(row.overtimeHourlyRate) > 0);
    if (kind === "absence") return Number(row.absenceDays || 0) < 0 || Number(row.absenceHours || 0) < 0 || Number(row.absenceDays || 0) + Number(row.absenceHours || 0) <= 0;
    return !(Number(row.amount) > 0);
  }

  async function save() {
    if (saving) return;
    const invalidIndex = rows.findIndex(isInvalid);
    if (!rows.length || rows.length > 100 || invalidIndex >= 0) {
      firstInvalidRef.current = document.querySelector<HTMLInputElement>(`#payroll-adjustment-row-${rows[invalidIndex]?.id ?? ""} input`);
      firstInvalidRef.current?.focus();
      toast({
        title: `Revisa ${copy[kind].title.toLowerCase()}`,
        description: invalidIndex >= 0 ? `Completa los datos de la fila ${invalidIndex + 1}.` : "Agrega entre 1 y 100 colaboradores.",
        tone: "error",
      });
      return;
    }
    setSaving(true);
    const payload = rows.map(row => ({
      collaborator_id: row.collaboratorId,
      effective_on: row.effectiveOn,
      reported_minutes: kind === "overtime" ? Math.round(Number(row.payableHours) * 60) : null,
      payable_hours: kind === "overtime" ? Number(row.payableHours) : null,
      hourly_rate: kind === "overtime" ? Number(row.overtimeHourlyRate) : null,
      days: kind === "absence" ? Number(row.absenceDays || 0) : null,
      hours: kind === "absence" ? Number(row.absenceHours || 0) : null,
      amount: kind === "commission" || kind === "bonus" ? Number(row.amount) : null,
      description: row.description.trim() || null,
    }));
    const { error } = await getSupabaseClient().rpc("save_payroll_adjustments_batch", {
      p_company_id: companyId,
      p_kind: kind,
      p_rows: payload,
    });
    setSaving(false);
    if (error) {
      toast({ title: `No se guardó la ${copy[kind].singular}`, description: error.message, tone: "error" });
      return;
    }
    await onSaved();
    toast({
      title: `${copy[kind].title.replace("Agregar ", "").replace("Registrar ", "")} guardadas`,
      description: `${rows.length} ${rows.length === 1 ? "movimiento quedó pendiente" : "movimientos quedaron pendientes"} de aprobación.`,
      tone: "success",
    });
    window.sessionStorage.removeItem(draftStorageKey);
    onClose();
  }
  useEffect(() => {
    saveRef.current = save;
  });

  function close() {
    window.sessionStorage.removeItem(draftStorageKey);
    onClose();
  }

  const kindColumns = useMemo(() => {
    if (kind === "overtime") return ["Horas extra", "Tarifa por hora"];
    if (kind === "absence") return ["Días", "Horas"];
    return ["Importe"];
  }, [kind]);

  return (
    <Modal
      open
      onOpenChange={open => !open && !saving && close()}
      className="payroll-adjustment-dialog"
      eyebrow="Nómina · Movimientos"
      title={copy[kind].title}
      description={kind === "absence" ? `Cada día equivale a ${Number(settings.hours_per_workday || 0).toLocaleString("es-MX")} horas. Captura días, horas adicionales o ambos.` : copy[kind].description}
      footer={<>
        <Button disabled={saving} onClick={close}>Cancelar</Button>
        <Button variant="primary" loading={saving} onClick={() => void save()}>Guardar como pendientes (Ctrl/⌘ + Enter)</Button>
      </>}
    >
      <div className="payroll-adjustment">
        {kind === "overtime" && <section className="payroll-adjustment__rule" aria-label="Regla de cálculo de horas extra">
          <CircleDollarSign size={18} aria-hidden="true" />
          <div>
            <strong>Tarifa predeterminada: {money(settings.default_overtime_hourly_rate ?? 50)} por hora extra</strong>
            <span>Cada fila comienza con esta tarifa. Puedes modificar una o varias personas sin cambiar la configuración general.</span>
          </div>
        </section>}
        {kind === "absence" && <section className="payroll-adjustment__rule" aria-label="Regla de cálculo de inasistencias">
          <CircleDollarSign size={18} aria-hidden="true" />
          <div>
            <strong>{Number(settings.payable_days_per_period || 0).toLocaleString("es-MX")} días de trabajo pagados por periodo · {Number(settings.hours_per_workday || 0).toLocaleString("es-MX")} horas por día</strong>
            <span>Un día descuenta el sueldo diario. Las horas capturadas se suman como ausencia adicional.</span>
          </div>
        </section>}
        <section className="payroll-adjustment__defaults" aria-labelledby="payroll-adjustment-defaults">
          <div>
            <strong id="payroll-adjustment-defaults">Agregar colaboradores</strong>
            <small>Busca por nombre o código y presiona Enter para agregar la primera coincidencia. Hasta 100 filas por operación.</small>
          </div>
          <div className="payroll-adjustment__controls">
            <div className="payroll-adjustment__search">
              <label htmlFor="payroll-adjustment-query">Colaborador</label>
              <div>
                <Search size={16} aria-hidden="true" />
                <Input
                  id="payroll-adjustment-query"
                  value={query}
                  onFocus={() => setSearchOpen(true)}
                  onBlur={() => window.setTimeout(() => setSearchOpen(false), 120)}
                  onChange={event => { setQuery(event.target.value); setSearchOpen(true); setSearchError(null); }}
                  onKeyDown={event => {
                    if (event.key === "Enter" && !event.metaKey && !event.ctrlKey && !event.nativeEvent.isComposing && searchOpen && !searching && availableOptions.length > 0) {
                      event.preventDefault();
                      addCollaborator(availableOptions[0]);
                    }
                  }}
                  placeholder="Escribe nombre o código"
                  autoComplete="off"
                />
              </div>
              {searchOpen && query.trim().length >= 2 && <div className="payroll-adjustment__results">
                {searching ? <p role="status">Buscando colaboradores…</p> : availableOptions.length ? availableOptions.map(option =>
                  <button type="button" key={option.id} onMouseDown={event => event.preventDefault()} onClick={() => addCollaborator(option)}>
                    <span><strong>{option.display_name}</strong><small>{option.code}{option.position_name ? ` · ${option.position_name}` : ""}</small></span>
                    <Plus size={15} aria-hidden="true" />
                  </button>,
                ) : <p>{searchError ?? "No hay colaboradores activos que coincidan."}</p>}
              </div>}
              <span className="sr-only" role="status" aria-live="polite">{lastAddedName}</span>
            </div>
            <Field label="Fecha del movimiento">
              <Input
                type="date"
                min={period.starts_on}
                max={period.ends_on}
                value={defaultDate}
                onChange={event => setDefaultDate(event.target.value)}
                aria-label="Fecha del movimiento"
              />
            </Field>
            <Button
              size="sm"
              variant="secondary"
              disabled={!rows.length || !defaultDate}
              onClick={() => setRows(current => current.map(row => ({ ...row, effectiveOn: defaultDate })))}
            >
              Usar esta fecha en todas
            </Button>
          </div>
        </section>

        <div className="payroll-adjustment__rows">
        {rows.length ? <div className="payroll-adjustment__table">
          <table className={`is-${kind}`}>
            <colgroup>
              {(kind === "overtime" || kind === "absence") ? <>
                <col style={{ width: "15%" }} /><col style={{ width: "15%" }} />
                <col style={{ width: "10%" }} /><col style={{ width: "13%" }} />
                <col style={{ width: "21%" }} /><col style={{ width: "22%" }} /><col style={{ width: "4%" }} />
              </> : <>
                <col style={{ width: "18%" }} /><col style={{ width: "15%" }} />
                <col style={{ width: "16%" }} /><col style={{ width: "22%" }} />
                <col style={{ width: "25%" }} /><col style={{ width: "4%" }} />
              </>}
            </colgroup>
            <thead><tr>
              <th>Colaborador</th><th>Fecha</th>
              {kindColumns.map(column => <th key={column}>{column}</th>)}
              <th>Vista previa</th><th>Descripción</th><th aria-label="Acciones" />
            </tr></thead>
            <tbody>{rows.map((row, index) => {
              const invalid = isInvalid(row);
              const preview = previews[index];
              return <tr id={`payroll-adjustment-row-${row.id}`} key={row.id}>
                <td data-label="Colaborador"><strong>{row.collaboratorName}</strong><small>{row.collaboratorCode}</small></td>
                <td data-label="Fecha">
                  <Input type="date" min={period.starts_on} max={period.ends_on} value={row.effectiveOn} onChange={event => updateRow(row.id, { effectiveOn: event.target.value })} aria-label={`Fecha de ${copy[kind].singular} de ${row.collaboratorName}`} />
                </td>
                {kind === "overtime" && <>
                  <td data-label="Horas extra"><Input type="number" min="0.01" step="0.25" value={row.payableHours} onChange={event => updateRow(row.id, { payableHours: event.target.value })} placeholder="Ej. 1.5" inputMode="decimal" aria-label={`Horas extra redondeadas de ${row.collaboratorName}`} aria-invalid={invalid || undefined} /></td>
                  <td data-label="Tarifa por hora"><CurrencyInput value={row.overtimeHourlyRate} onValueChange={value => updateRow(row.id, { overtimeHourlyRate: value })} placeholder="50.00" aria-label={`Tarifa de hora extra de ${row.collaboratorName}`} aria-invalid={invalid || undefined} /></td>
                </>}
                {kind === "absence" && <>
                  <td data-label="Días"><Input type="number" min="0" step="0.5" value={row.absenceDays} onChange={event => updateRow(row.id, { absenceDays: event.target.value })} placeholder="0" inputMode="decimal" aria-label={`Días de inasistencia de ${row.collaboratorName}`} aria-invalid={invalid || undefined} /></td>
                  <td data-label="Horas"><Input type="number" min="0" step="0.25" value={row.absenceHours} onChange={event => updateRow(row.id, { absenceHours: event.target.value })} placeholder="0" inputMode="decimal" aria-label={`Horas de inasistencia de ${row.collaboratorName}`} aria-invalid={invalid || undefined} /></td>
                </>}
                {(kind === "commission" || kind === "bonus") && <td data-label="Importe">
                  <CurrencyInput value={row.amount} onValueChange={value => updateRow(row.id, { amount: value })} placeholder="0.00" aria-label={`Importe de ${copy[kind].singular} de ${row.collaboratorName}`} aria-invalid={invalid || undefined} />
                </td>}
                <td data-label="Vista previa"><div className="payroll-adjustment__preview"><strong>{preview.label}</strong><small>{preview.detail}</small></div></td>
                <td data-label="Descripción"><Input value={row.description} onChange={event => updateRow(row.id, { description: event.target.value })} placeholder={kind === "commission" ? "Ej. Venta o folio" : "Ej. Motivo o referencia"} aria-label={`Descripción de ${copy[kind].singular} de ${row.collaboratorName}`} /></td>
                <td className="payroll-adjustment__remove">
                  <Button size="icon" variant="ghost" aria-label={`Quitar a ${row.collaboratorName}`} onClick={() => setRows(current => current.filter(item => item.id !== row.id))}><Trash2 size={15} aria-hidden="true" /></Button>
                </td>
              </tr>;
            })}</tbody>
          </table>
        </div> : <div className="payroll-adjustment__empty">
          <Search size={20} aria-hidden="true" />
          <strong>Agrega colaboradores para comenzar</strong>
          <span>La captura se realiza directamente en Satrapy.</span>
        </div>}
        </div>

      </div>
    </Modal>
  );
}
