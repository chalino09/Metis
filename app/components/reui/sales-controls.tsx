"use client";

import * as React from "react";
import type { CSSProperties, InputHTMLAttributes, ReactNode } from "react";
import { cn } from "@/app/lib/utils";
import { Button as ReuiButton } from "@/app/components/reui/button";
import { Input as ReuiInput } from "@/app/components/reui/input";
import { Label } from "@/app/components/reui/label";
import { CompactSelect, type CompactSelectOption } from "@/components/reui/compact-select";
import { Input as LegacyInput } from "@/app/components/ui/primitives";
import { Search, X } from "lucide-react";

type SalesButtonVariant = "primary" | "secondary" | "ghost" | "danger";
type SalesButtonSize = "sm" | "md" | "lg" | "icon";

/** ReUI button with the legacy Sales API kept for business-flow compatibility. */
export const SalesButton = React.forwardRef<HTMLButtonElement, React.ComponentProps<"button"> & {
  variant?: SalesButtonVariant;
  size?: SalesButtonSize;
  loading?: boolean;
}>(function SalesButton({ className, variant = "secondary", size = "md", loading = false, disabled, children, type = "button", ...props }, ref) {
  const reuiVariant = variant === "primary" ? "default" : variant === "danger" ? "destructive" : variant;
  const reuiSize = size === "md" ? "default" : size;
  return (
    <ReuiButton
      ref={ref}
      type={type}
      variant={reuiVariant}
      size={reuiSize}
      className={cn("ui-button sales-reui-button", `ui-button--${variant}`, `ui-button--${size}`, className)}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      {...props}
    >
      {loading && <span className="ui-button__spinner" aria-hidden="true" />}
      <span className={loading ? "ui-button__content is-loading" : "ui-button__content"}>{children}</span>
    </ReuiButton>
  );
});

/** ReUI input for all regular Sales fields; date fields retain Satrapy's validated calendar. */
export const SalesInput = React.forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function SalesInput({ className, type, ...props }, ref) {
  const inputClassName = cn("ui-input sales-reui-input", className);
  if (type === "date" || type === "datetime-local") {
    return <LegacyInput ref={ref} type={type} className={inputClassName} {...props} />;
  }
  return <ReuiInput ref={ref} type={type} className={inputClassName} {...props} />;
});

function normalizeCurrency(value: string) {
  const cleaned = value.replace(/[^\d.]/g, "");
  const [integer = "", ...decimalParts] = cleaned.split(".");
  const decimal = decimalParts.join("").slice(0, 2);
  return `${integer}${cleaned.includes(".") ? `.${decimal}` : ""}`;
}

function formatCurrency(value: string) {
  const normalized = normalizeCurrency(value);
  if (!normalized) return "";
  const [integer = "", decimal] = normalized.split(".");
  const grouped = (integer || "0").replace(/^0+(?=\d)/, "").replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return decimal === undefined ? grouped : `${grouped}.${decimal}`;
}

export const SalesCurrencyInput = React.forwardRef<HTMLInputElement, Omit<InputHTMLAttributes<HTMLInputElement>, "type" | "value" | "onChange"> & {
  value: string;
  onValueChange: (value: string) => void;
  currency?: string;
}>(function SalesCurrencyInput({ className, value, onValueChange, currency = "MXN", onBlur, "aria-label": ariaLabel, ...props }, ref) {
  return (
    <div className="ui-currency-input sales-reui-currency-input">
      <ReuiInput
        ref={ref}
        type="text"
        className={cn("ui-input sales-reui-input", className)}
        inputMode="decimal"
        value={formatCurrency(value)}
        onChange={(event) => onValueChange(normalizeCurrency(event.target.value))}
        onBlur={(event) => {
          const amount = Number(value);
          if (value && Number.isFinite(amount)) onValueChange(amount.toFixed(2));
          onBlur?.(event);
        }}
        aria-label={ariaLabel ? `${ariaLabel} en ${currency}` : undefined}
        {...props}
      />
      <span aria-hidden="true">{currency}</span>
    </div>
  );
});

/** ReUI autocomplete-backed select, preserving the Select props used by Sales RPC forms. */
export function SalesSelect({ value, onValueChange, options, placeholder = "Seleccionar", ariaLabel, disabled = false, className, style }: {
  value: string;
  onValueChange: (value: string) => void;
  options: CompactSelectOption[];
  placeholder?: string;
  ariaLabel: string;
  disabled?: boolean;
  className?: string;
  style?: CSSProperties;
}) {
  const normalizedOptions = options.length ? options : [{ value: "", label: placeholder }];
  return (
    <div className={cn("sales-reui-select", className)} style={style} data-placeholder={value ? undefined : "true"}>
      <CompactSelect
        value={value}
        onValueChange={onValueChange}
        options={normalizedOptions}
        ariaLabel={ariaLabel}
        disabled={disabled}
      />
    </div>
  );
}

export type SalesFieldProps = {
  label: ReactNode;
  hint?: string;
  error?: string;
  children: ReactNode;
};

export function SalesField({ label, hint, error, children }: SalesFieldProps) {
  return (
    <div className="ui-field sales-reui-field">
      <Label>{label}</Label>
      {children}
      {error ? <small className="ui-field__error">{error}</small> : hint ? <small>{hint}</small> : null}
    </div>
  );
}

export function SalesDataToolbar({ search, onSearchChange, placeholder, filters, activeFilters = 0, onClear, results }: {
  search?: string;
  onSearchChange?: (value: string) => void;
  placeholder?: string;
  filters?: ReactNode;
  activeFilters?: number;
  onClear?: () => void;
  results?: number;
}) {
  return (
    <div className="data-toolbar sales-reui-toolbar">
      {onSearchChange && <label className="data-toolbar__search"><Search size={16} aria-hidden="true" /><SalesInput value={search ?? ""} onChange={(event) => onSearchChange(event.target.value)} placeholder={placeholder} aria-label={placeholder} /></label>}
      {filters && <div className="data-toolbar__filters">{filters}</div>}
      {(activeFilters > 0 || results !== undefined) && <div className="data-toolbar__meta">
        {results !== undefined && <span>{results.toLocaleString("es-MX")} resultado{results === 1 ? "" : "s"}</span>}
        {activeFilters > 0 && onClear && <SalesButton variant="ghost" size="sm" onClick={onClear}><X size={14} /> Limpiar filtros</SalesButton>}
      </div>}
    </div>
  );
}

export function SalesDataPagination({ page, onChange, total, pageSize = 25, totalPages, label = "registros", showTotal = true }: {
  page: number;
  onChange: (page: number) => void;
  total?: number;
  pageSize?: number;
  totalPages?: number;
  label?: string;
  showTotal?: boolean;
}) {
  const pages = totalPages ?? Math.max(1, Math.ceil((total ?? 0) / pageSize));
  if (pages <= 1) return null;
  return (
    <div className="data-pagination sales-reui-pagination">
      <span>Página {page} de {pages}{showTotal && total !== undefined ? ` · ${total.toLocaleString("es-MX")} ${label}` : ""}</span>
      <div><SalesButton size="sm" variant="secondary" disabled={page <= 1} onClick={() => onChange(page - 1)}>Anterior</SalesButton><SalesButton size="sm" variant="secondary" disabled={page >= pages} onClick={() => onChange(page + 1)}>Siguiente</SalesButton></div>
    </div>
  );
}
