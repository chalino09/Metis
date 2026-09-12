"use client";

import { Select } from "@base-ui/react/select";
import { Check, ChevronsUpDown } from "lucide-react";
import { useRef, useState } from "react";

export type CompactSelectOption = { value: string; label: string; disabled?: boolean };

/** Fixed options only: the displayed value is a button, never an editable input. */
export function CompactSelect({ value, onValueChange, options, ariaLabel, placeholder = "Seleccionar", disabled = false, className }: {
  value: string;
  onValueChange: (value: string) => void;
  options: CompactSelectOption[];
  ariaLabel: string;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  /** Retained for existing callers; every option is always shown. */
  showAllOnOpen?: boolean;
}) {
  const triggerRef = useRef<HTMLButtonElement>(null);
  const [portalContainer, setPortalContainer] = useState<HTMLElement | null>(null);
  return <div className={className}>
    <Select.Root value={value} items={options} disabled={disabled} modal={false}
      onOpenChange={open => { if (open) setPortalContainer(triggerRef.current?.closest<HTMLElement>('[role="dialog"]') ?? null); }}
      onValueChange={next => { if (next !== null && options.some(option => option.value === next && !option.disabled)) onValueChange(next); }}>
      <Select.Trigger ref={triggerRef} type="button" aria-label={ariaLabel} data-slot="compact-select-trigger" className="reui-fixed-select__trigger">
        <Select.Value placeholder={placeholder}>{options.find(option => option.value === value)?.label ?? placeholder}</Select.Value>
        <Select.Icon className="reui-fixed-select__icon"><ChevronsUpDown size={16} aria-hidden="true" /></Select.Icon>
      </Select.Trigger>
      <Select.Portal container={portalContainer ?? undefined}>
        <Select.Positioner align="start" sideOffset={4} alignItemWithTrigger={false} className="reui-fixed-select__positioner">
          <Select.Popup className="reui-fixed-select__popup">
            <Select.List className="reui-fixed-select__list">
              {options.map(option => <Select.Item key={option.value} value={option.value} disabled={option.disabled} className="reui-fixed-select__item">
                <Select.ItemText>{option.label}</Select.ItemText>
                <Select.ItemIndicator><Check size={15} aria-hidden="true" /></Select.ItemIndicator>
              </Select.Item>)}
              {!options.length && <div className="reui-fixed-select__empty">Sin opciones disponibles.</div>}
            </Select.List>
          </Select.Popup>
        </Select.Positioner>
      </Select.Portal>
    </Select.Root>
  </div>;
}

/** Escape closes an open selector before its containing Radix dialog. */
export function preventDialogDismissForOpenSelect(event: KeyboardEvent) {
  const target = event.target instanceof Element ? event.target : document.activeElement;
  const dialog = target?.closest('[role="dialog"]');
  if (dialog?.querySelector('[data-slot="compact-select-trigger"][aria-expanded="true"], [data-slot="autocomplete-input"][aria-expanded="true"]')) event.preventDefault();
}
