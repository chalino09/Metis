"use client";

import * as Dialog from "@radix-ui/react-dialog";
import * as RadixSelect from "@radix-ui/react-select";
import * as RadixTabs from "@radix-ui/react-tabs";
import * as RadixToast from "@radix-ui/react-toast";
import { CalendarDays, Check, ChevronDown, ChevronLeft, ChevronRight, X } from "lucide-react";
import {
  createContext,
  forwardRef,
  useCallback,
  useContext,
  useId,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type ButtonHTMLAttributes,
  type CSSProperties,
  type InputHTMLAttributes,
  type ReactNode,
} from "react";

function cx(...classes: Array<string | false | null | undefined>) {
  return classes.filter(Boolean).join(" ");
}

export type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "secondary" | "ghost" | "danger";
  size?: "sm" | "md" | "lg" | "icon";
  loading?: boolean;
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { className, variant = "secondary", size = "md", loading = false, disabled, children, type = "button", ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      className={cx("ui-button", `ui-button--${variant}`, `ui-button--${size}`, className)}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      {...props}
    >
      {loading && <span className="ui-button__spinner" aria-hidden="true" />}
      <span className={loading ? "ui-button__content is-loading" : "ui-button__content"} style={{ color: "inherit" }}>{children}</span>
    </button>
  );
});

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function Input(
  { className, ...props },
  ref,
) {
  if (props.type === "date") return <DateInput ref={ref} className={className} {...props} />;
  return <input ref={ref} className={cx("ui-input", className)} {...props} />;
});

function normalizeCurrencyInput(value: string) {
  const cleaned = value.replace(/[^\d.]/g, "");
  const [integer = "", ...decimalParts] = cleaned.split(".");
  const hasDecimal = cleaned.includes(".");
  const decimal = decimalParts.join("").slice(0, 2);
  return `${integer}${hasDecimal ? `.${decimal}` : ""}`;
}

function formatCurrencyInput(value: string) {
  const normalized = normalizeCurrencyInput(value);
  if (!normalized) return "";
  const [integer = "", decimal] = normalized.split(".");
  const grouped = (integer || "0").replace(/^0+(?=\d)/, "").replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return decimal === undefined ? grouped : `${grouped}.${decimal}`;
}

export const CurrencyInput = forwardRef<HTMLInputElement, Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "value" | "onChange"> & {
  value: string;
  onValueChange: (value: string) => void;
  currency?: string;
}>(function CurrencyInput(
  { className, value, onValueChange, currency = "MXN", onBlur, "aria-label": ariaLabel, ...props },
  ref,
) {
  return <div className="ui-currency-input">
    <input
      ref={ref}
      type="text"
      className={cx("ui-input", className)}
      inputMode="decimal"
      value={formatCurrencyInput(value)}
      onChange={event => onValueChange(normalizeCurrencyInput(event.target.value))}
      onBlur={event => {
        const amount = Number(value);
        if (value && Number.isFinite(amount)) onValueChange(amount.toFixed(2));
        onBlur?.(event);
      }}
      aria-label={ariaLabel ? `${ariaLabel} en ${currency}` : undefined}
      {...props}
    />
    <span aria-hidden="true">{currency}</span>
  </div>;
});

function isoToDisplay(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return "";
  const [year, month, day] = value.split("-");
  return `${day}/${month}/${year}`;
}

function displayToIso(value: string) {
  const match = value.trim().match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  if (!match) return null;
  const [, day, month, year] = match;
  const date = new Date(Number(year), Number(month) - 1, Number(day));
  if (date.getFullYear() !== Number(year) || date.getMonth() !== Number(month) - 1 || date.getDate() !== Number(day)) return null;
  return `${year}-${month}-${day}`;
}

function isoDate(value: Date) {
  return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
}

function dateValidationMessage(value: string, min?: string, max?: string) {
  const parsed = displayToIso(value);
  if (!parsed) return "Escribe una fecha válida en formato dd/mm/aaaa.";
  if (min && parsed < min) return `Selecciona una fecha igual o posterior al ${isoToDisplay(min)}.`;
  if (max && parsed > max) return `Selecciona una fecha igual o anterior al ${isoToDisplay(max)}.`;
  return null;
}

function parseIsoDate(value: string) {
  const [year, month, day] = value.split("-").map(Number);
  return new Date(year, month - 1, day);
}

const DateInput = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function DateInput(
  { className, type: _type, value, defaultValue: _defaultValue, min, max, required, disabled, onChange, onBlur, onKeyDown, "aria-label": ariaLabel, "aria-describedby": ariaDescribedBy, name, style, ...props },
  ref,
) {
  void _type; void _defaultValue;
  const isoValue = typeof value === "string" ? value : "";
  const [draftText, setDraftText] = useState<string | null>(null);
  const [validationMessage, setValidationMessage] = useState<string | null>(null);
  const validationMessageId = useId();
  const text = draftText ?? isoToDisplay(isoValue);
  const [open, setOpen] = useState(false);
  const [calendarPlacement, setCalendarPlacement] = useState<"below" | "above" | "fixed">("below");
  const pickerRef = useRef<HTMLDivElement>(null);
  const [viewMonth, setViewMonth] = useState(() => {
    const base = isoValue ? parseIsoDate(isoValue) : new Date();
    return new Date(base.getFullYear(), base.getMonth(), 1);
  });
  const firstDay = (viewMonth.getDay() + 6) % 7;
  const daysInMonth = new Date(viewMonth.getFullYear(), viewMonth.getMonth() + 1, 0).getDate();
  const calendarDays: Array<number | null> = [...Array.from({ length: firstDay }, () => null), ...Array.from({ length: daysInMonth }, (_, index) => index + 1)];
  while (calendarDays.length % 7) calendarDays.push(null);
  const todayValue = isoDate(new Date());
  const monthLabel = viewMonth.toLocaleDateString("es-MX", { month: "long", year: "numeric" });
  const minValue = min == null ? undefined : String(min);
  const maxValue = max == null ? undefined : String(max);
  const isUnavailable = (candidate: string) => Boolean(minValue && candidate < minValue) || Boolean(maxValue && candidate > maxValue);
  function notify(next: string) {
    onChange?.({ target: { value: next }, currentTarget: { value: next } } as ChangeEvent<HTMLInputElement>);
  }
  function commit(nextText: string) {
    if (!nextText.trim()) { notify(""); setDraftText(null); setValidationMessage(null); return; }
    const message = dateValidationMessage(nextText, minValue, maxValue);
    if (message) { setDraftText(nextText); setValidationMessage(message); return; }
    notify(displayToIso(nextText)!); setDraftText(null); setValidationMessage(null);
  }
  function choose(next: string) {
    if (isUnavailable(next)) return;
    notify(next); setDraftText(null); setValidationMessage(null); setOpen(false);
  }
  function toggleCalendar() {
    if (!open) {
      const rect = pickerRef.current?.getBoundingClientRect();
      if (rect) {
        const calendarHeight = 286;
        const gap = 7;
        const spaceBelow = window.innerHeight - rect.bottom;
        const spaceAbove = rect.top;
        setCalendarPlacement(spaceBelow >= calendarHeight + gap ? "below" : spaceAbove >= calendarHeight + gap ? "above" : "fixed");
      }
      const base = isoValue ? parseIsoDate(isoValue) : new Date();
      setViewMonth(new Date(base.getFullYear(), base.getMonth(), 1));
    }
    setOpen(current => !current);
  }
  return <div ref={pickerRef} className="satrapy-date-picker" onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false); }} onKeyDown={event => { if (event.key === "Escape") { event.preventDefault(); setOpen(false); } }}>
    <div className="satrapy-date-control" style={{ position: "relative", display: "block" }}>
      <input ref={ref} className={cx("ui-input", "satrapy-date-input", className)} value={text} onChange={event => { setDraftText(event.target.value.replace(/[^\d/]/g, "").slice(0, 10)); setValidationMessage(null); }} onBlur={event => { commit(event.currentTarget.value); onBlur?.(event); }} onKeyDown={event => { if (event.key === "Enter") commit(event.currentTarget.value); onKeyDown?.(event); }} inputMode="numeric" autoComplete="off" placeholder="dd/mm/aaaa" aria-label={ariaLabel} aria-invalid={validationMessage ? true : undefined} aria-describedby={[ariaDescribedBy, validationMessage ? validationMessageId : null].filter(Boolean).join(" ") || undefined} name={name} required={required} disabled={disabled} {...props} style={{ ...style, paddingRight: 43 }} />
      <button type="button" className="satrapy-date-control__button" style={{ position: "absolute", top: 1, right: 1, bottom: 1, display: "grid", width: 39, placeItems: "center", border: 0, background: "transparent" }} aria-label={ariaLabel ? `Abrir calendario: ${ariaLabel}` : "Abrir calendario"} aria-haspopup="dialog" aria-expanded={open} disabled={disabled} onClick={toggleCalendar}><CalendarDays size={17} /></button>
    </div>
    {validationMessage && <small id={validationMessageId} className="ui-field__error" role="alert">{validationMessage}</small>}
    {open && <div className={cx("satrapy-calendar", `is-${calendarPlacement}`)} role="dialog" aria-label={`Calendario${ariaLabel ? ` de ${ariaLabel}` : ""}`}>
      <header><strong>{monthLabel}</strong><div><button type="button" aria-label="Mes anterior" onClick={() => setViewMonth(current => new Date(current.getFullYear(), current.getMonth() - 1, 1))}><ChevronLeft size={17} /></button><button type="button" aria-label="Mes siguiente" onClick={() => setViewMonth(current => new Date(current.getFullYear(), current.getMonth() + 1, 1))}><ChevronRight size={17} /></button></div></header>
      <div className="satrapy-calendar-weekdays" aria-hidden="true">{["L", "M", "M", "J", "V", "S", "D"].map((day, index) => <span key={`${day}-${index}`}>{day}</span>)}</div>
      <div className="satrapy-calendar-days">{calendarDays.map((day, index) => { if (day === null) return <span key={`empty-${index}`} />; const candidate = isoDate(new Date(viewMonth.getFullYear(), viewMonth.getMonth(), day)); return <button type="button" key={candidate} disabled={isUnavailable(candidate)} className={`${candidate === isoValue ? "is-selected " : ""}${candidate === todayValue ? "is-today" : ""}`} aria-label={new Date(`${candidate}T00:00:00`).toLocaleDateString("es-MX", { dateStyle: "full" })} aria-pressed={candidate === isoValue} onClick={() => choose(candidate)}>{day}</button>; })}</div>
      <footer>{!required ? <button type="button" disabled={!isoValue} onClick={() => { notify(""); setDraftText(null); setOpen(false); }}>Borrar</button> : <span />}{!isUnavailable(todayValue) && <button type="button" onClick={() => choose(todayValue)}>Hoy</button>}</footer>
    </div>}
  </div>;
});

export function Field({
  label,
  hint,
  error,
  children,
}: {
  label: ReactNode;
  hint?: string;
  error?: string;
  children: ReactNode;
}) {
  return <label className="ui-field"><span>{label}</span>{children}{error ? <small className="ui-field__error">{error}</small> : hint ? <small>{hint}</small> : null}</label>;
}

export function Badge({
  tone = "neutral",
  children,
  className,
}: {
  tone?: "neutral" | "primary" | "success" | "warning" | "danger" | "info";
  children: ReactNode;
  className?: string;
}) {
  return <span className={cx("ui-badge", `ui-badge--${tone}`, className)}>{children}</span>;
}

export type SelectOption = { value: string; label: string; disabled?: boolean };

export function Select({
  value,
  onValueChange,
  options,
  placeholder = "Seleccionar",
  ariaLabel,
  disabled,
  className,
  style,
}: {
  value: string;
  onValueChange: (value: string) => void;
  options: SelectOption[];
  placeholder?: string;
  ariaLabel: string;
  disabled?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  const selected = options.find((option) => option.value === value);
  return (
    <RadixSelect.Root value={value} onValueChange={onValueChange} disabled={disabled}>
      <RadixSelect.Trigger className={cx("ui-select", className)} style={style} aria-label={ariaLabel}>
        <RadixSelect.Value>{selected?.label ?? placeholder}</RadixSelect.Value>
        <RadixSelect.Icon><ChevronDown size={15} /></RadixSelect.Icon>
      </RadixSelect.Trigger>
      <RadixSelect.Portal>
        <RadixSelect.Content className="ui-select__content" position="popper" sideOffset={6}>
          <RadixSelect.Viewport>
            {options.map((option) => (
              <RadixSelect.Item className="ui-select__item" value={option.value} disabled={option.disabled} key={option.value}>
                <RadixSelect.ItemText>{option.label}</RadixSelect.ItemText>
                <RadixSelect.ItemIndicator><Check size={14} /></RadixSelect.ItemIndicator>
              </RadixSelect.Item>
            ))}
          </RadixSelect.Viewport>
        </RadixSelect.Content>
      </RadixSelect.Portal>
    </RadixSelect.Root>
  );
}

export function Tabs({
  value,
  onValueChange,
  items,
}: {
  value: string;
  onValueChange: (value: string) => void;
  items: Array<{ value: string; label: string; disabled?: boolean }>;
}) {
  return (
    <RadixTabs.Root value={value} onValueChange={onValueChange}>
      <RadixTabs.List className="ui-tabs" aria-label="Secciones">
        {items.map((item) => <RadixTabs.Trigger className="ui-tabs__trigger" value={item.value} disabled={item.disabled} key={item.value}>{item.label}</RadixTabs.Trigger>)}
      </RadixTabs.List>
    </RadixTabs.Root>
  );
}

type ModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  eyebrow?: string;
  title: string;
  description?: string;
  children?: ReactNode;
  footer?: ReactNode;
  labelledBy?: string;
  className?: string;
};

export function Modal({ open, onOpenChange, eyebrow, title, description, children, footer, labelledBy, className }: ModalProps) {
  const titleId = labelledBy ?? "satrapy-dialog-title";
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="ui-dialog-overlay" />
        <Dialog.Content className={cx("ui-dialog", className)} aria-describedby={description ? `${titleId}-description` : undefined}>
          <Dialog.Close asChild><button className="ui-dialog__close" aria-label="Cerrar"><X size={17} /></button></Dialog.Close>
          {eyebrow && <span className="eyebrow">{eyebrow}</span>}
          <Dialog.Title id={titleId}>{title}</Dialog.Title>
          {description && <Dialog.Description id={`${titleId}-description`}>{description}</Dialog.Description>}
          {children && <div className="ui-dialog__body">{children}</div>}
          {footer && <div className="ui-dialog__footer">{footer}</div>}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export function Drawer({
  open,
  onOpenChange,
  title,
  children,
  className,
  returnFocusRef,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  children: ReactNode;
  className?: string;
  returnFocusRef?: { current: HTMLElement | null };
}) {
  const previousFocusRef = useRef<HTMLElement | null>(null);
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="ui-dialog-overlay" />
        <Dialog.Content className={cx("ui-drawer", className)} onOpenAutoFocus={() => {
          previousFocusRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
        }} onCloseAutoFocus={event => {
          const target = returnFocusRef?.current ?? previousFocusRef.current;
          if (!target) return;
          event.preventDefault();
          target.focus();
        }}>
          <Dialog.Title>{title}</Dialog.Title>
          <Dialog.Close asChild><button className="ui-dialog__close" aria-label="Cerrar"><X size={17} /></button></Dialog.Close>
          <div className="ui-drawer__body">{children}</div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

type ToastItem = { id: number; title: string; description?: string; tone: "success" | "error" | "info" };
type ToastContextValue = { toast: (item: Omit<ToastItem, "id">) => void };
const ToastContext = createContext<ToastContextValue | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const toast = useCallback((item: Omit<ToastItem, "id">) => {
    const id = Date.now();
    setItems((current) => [...current.slice(-2), { ...item, id }]);
  }, []);
  const context = useMemo(() => ({ toast }), [toast]);
  return (
    <ToastContext.Provider value={context}>
      <RadixToast.Provider swipeDirection="right" duration={5000}>
        {children}
        {items.map((item) => (
          <RadixToast.Root className={cx("ui-toast", `ui-toast--${item.tone}`)} key={item.id} defaultOpen onOpenChange={(open) => !open && setItems((current) => current.filter((entry) => entry.id !== item.id))}>
            <RadixToast.Title>{item.title}</RadixToast.Title>
            {item.description && <RadixToast.Description>{item.description}</RadixToast.Description>}
            <RadixToast.Close className="ui-toast__close" aria-label="Cerrar"><X size={14} /></RadixToast.Close>
          </RadixToast.Root>
        ))}
        <RadixToast.Viewport className="ui-toast-viewport" />
      </RadixToast.Provider>
    </ToastContext.Provider>
  );
}

export function useToast() {
  const context = useContext(ToastContext);
  if (!context) throw new Error("useToast debe usarse dentro de ToastProvider");
  return context;
}
