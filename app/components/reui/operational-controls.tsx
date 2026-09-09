"use client";

import * as React from "react";
import type { CSSProperties, InputHTMLAttributes, ReactNode } from "react";
import { cn } from "@/app/lib/utils";
import { Button as ReuiButton } from "@/app/components/reui/button";
import { Input as ReuiInput } from "@/app/components/reui/input";
import { CompactSelect, type CompactSelectOption } from "@/components/reui/compact-select";
import { Input as LegacyInput } from "@/app/components/ui/primitives";
import { Search, X } from "lucide-react";

type OperationalButtonVariant = "primary" | "secondary" | "ghost" | "danger";
type OperationalButtonSize = "sm" | "md" | "lg" | "icon";

/** ReUI button with the existing control API kept for business-flow compatibility. */
export const OperationalButton = React.forwardRef<HTMLButtonElement, React.ComponentProps<"button"> & {
  variant?: OperationalButtonVariant;
  size?: OperationalButtonSize;
  loading?: boolean;
}>(function OperationalButton({ className, variant = "secondary", size = "md", loading = false, disabled, children, type = "button", ...props }, ref) {
  const reuiVariant = variant === "primary" ? "default" : variant === "danger" ? "destructive" : variant;
  const reuiSize = size === "md" ? "default" : size;
  return (
    <ReuiButton
      ref={ref}
      type={type}
      variant={reuiVariant}
      size={reuiSize}
      className={cn("ui-button operational-reui-button", `ui-button--${variant}`, `ui-button--${size}`, className)}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      {...props}
    >
      {loading && <span className="ui-button__spinner" aria-hidden="true" />}
      <span className={loading ? "ui-button__content is-loading" : "ui-button__content"}>{children}</span>
    </ReuiButton>
  );
});

/** ReUI input for all regular fields; date fields retain Satrapy's validated calendar. */
export const OperationalInput = React.forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(function OperationalInput({ className, type, ...props }, ref) {
  const inputClassName = cn("ui-input operational-reui-input", className);
  if (type === "date" || type === "datetime-local") {
    return <LegacyInput ref={ref} type={type} className={inputClassName} {...props} />;
  }
  return <ReuiInput ref={ref} type={type} className={inputClassName} {...props} />;
});

/** ReUI autocomplete-backed select, preserving the Select props used by RPC forms. */
export function OperationalSelect({ value, onValueChange, options, placeholder = "Seleccionar", ariaLabel, disabled = false, className, style, showAllOnOpen }: {
  value: string;
  onValueChange: (value: string) => void;
  options: CompactSelectOption[];
  placeholder?: string;
  ariaLabel: string;
  disabled?: boolean;
  className?: string;
  style?: CSSProperties;
  showAllOnOpen?: boolean;
}) {
  const normalizedOptions = options.length ? options : [{ value: "", label: placeholder, disabled: true }];
  return (
    <div className={cn("operational-reui-select", className)} style={style} data-placeholder={value ? undefined : "true"}>
      <CompactSelect
        value={value}
        onValueChange={onValueChange}
        options={normalizedOptions}
        showAllOnOpen={showAllOnOpen}
        ariaLabel={ariaLabel}
        placeholder={placeholder}
        disabled={disabled}
      />
    </div>
  );
}

export function OperationalDataToolbar({ search, onSearchChange, placeholder, filters, activeFilters = 0, onClear, results }: {
  search?: string;
  onSearchChange?: (value: string) => void;
  placeholder?: string;
  filters?: ReactNode;
  activeFilters?: number;
  onClear?: () => void;
  results?: number;
}) {
  return (
    <div className="data-toolbar operational-reui-toolbar">
      {onSearchChange && <label className="data-toolbar__search"><Search size={16} aria-hidden="true" /><OperationalInput value={search ?? ""} onChange={(event) => onSearchChange(event.target.value)} placeholder={placeholder} aria-label={placeholder} /></label>}
      {filters && <div className="data-toolbar__filters">{filters}</div>}
      {(activeFilters > 0 || results !== undefined) && <div className="data-toolbar__meta">
        {results !== undefined && <span>{results.toLocaleString("es-MX")} resultado{results === 1 ? "" : "s"}</span>}
        {activeFilters > 0 && onClear && <OperationalButton variant="ghost" size="sm" onClick={onClear}><X size={14} /> Limpiar filtros</OperationalButton>}
      </div>}
    </div>
  );
}
