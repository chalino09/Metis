"use client";

import { Check } from "lucide-react";
import { useMemo, useRef, useState, type RefObject } from "react";
import { Autocomplete, AutocompleteContent, AutocompleteEmpty, AutocompleteInput, AutocompleteItem, AutocompleteList } from "@/components/reui/autocomplete";

export type CompactSelectOption = { value: string; label: string; disabled?: boolean };

export function CompactSelect({
  value,
  onValueChange,
  options,
  ariaLabel,
  placeholder,
  disabled = false,
  className,
  showAllOnOpen = true,
}: {
  value: string;
  onValueChange: (value: string) => void;
  options: CompactSelectOption[];
  ariaLabel: string;
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  showAllOnOpen?: boolean;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  const selected = options.find((option) => option.value === value);
  return <CompactSelectControl inputRef={inputRef} showAllOnOpen={showAllOnOpen} key={JSON.stringify([value,selected?.label??""])} value={value} onValueChange={onValueChange} options={options} ariaLabel={ariaLabel} placeholder={placeholder} disabled={disabled} className={className} initialQuery={selected?.label ?? ""} />;
}

function CompactSelectControl({
  value,
  onValueChange,
  options,
  ariaLabel,
  placeholder,
  disabled,
  className,
  initialQuery,
  showAllOnOpen,
  inputRef,
}: {
  value: string;
  onValueChange: (value: string) => void;
  options: CompactSelectOption[];
  ariaLabel: string;
  placeholder?: string;
  disabled: boolean;
  className?: string;
  initialQuery: string;
  showAllOnOpen: boolean;
  inputRef: RefObject<HTMLInputElement | null>;
}) {
  const [open, setOpen] = useState(false);
  const [portalContainer, setPortalContainer] = useState<HTMLElement | null>(null);
  const [query, setQuery] = useState(initialQuery);
  const matching = useMemo(() => options.filter((option) => (showAllOnOpen && open && query === initialQuery) || option.label.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())), [options, query, showAllOnOpen, open, initialQuery]);

  return <Autocomplete open={open} onOpenChange={next=>{if(next)setPortalContainer(inputRef.current?.closest<HTMLElement>('[role="dialog"]')??null);setOpen(next);if(!next&&showAllOnOpen)setQuery(initialQuery);}} className={className} filter={null} items={matching} value={query} onValueChange={setQuery} itemToStringValue={(option) => option.label} openOnInputClick disabled={disabled} autoHighlight>
    <AutocompleteInput ref={inputRef} aria-label={ariaLabel} placeholder={placeholder} showTrigger onKeyDown={event=>{if(event.key==="Enter")event.preventDefault();}} />
    <AutocompleteContent portalContainer={portalContainer??undefined} className="reui-compact-select__content">
      <AutocompleteEmpty>Sin opciones disponibles.</AutocompleteEmpty>
      <AutocompleteList>
        {matching.map((option) => <AutocompleteItem value={option} key={option.value} disabled={option.disabled} onClick={() => { setQuery(option.label); onValueChange(option.value); if(showAllOnOpen) requestAnimationFrame(()=>{if(inputRef.current?.isConnected)inputRef.current.focus();}); }}>
          <span>{option.label}</span>{option.value === value && <Check aria-hidden="true" />}
        </AutocompleteItem>)}
      </AutocompleteList>
    </AutocompleteContent>
  </Autocomplete>;
}

/** Escape closes an open selector before its containing Radix dialog. */
export function preventDialogDismissForOpenSelect(event: KeyboardEvent) {
  const target = event.target instanceof Element ? event.target : document.activeElement;
  const dialog = target?.closest('[role="dialog"]');
  if (dialog?.querySelector('[data-slot="autocomplete-input"][aria-expanded="true"]')) event.preventDefault();
}
