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
  disabled = false,
  className,
  showAllOnOpen = false,
}: {
  value: string;
  onValueChange: (value: string) => void;
  options: CompactSelectOption[];
  ariaLabel: string;
  disabled?: boolean;
  className?: string;
  showAllOnOpen?: boolean;
}) {
  const inputRef = useRef<HTMLInputElement>(null);
  const selected = options.find((option) => option.value === value);
  return <CompactSelectControl inputRef={inputRef} showAllOnOpen={showAllOnOpen} key={value} value={value} onValueChange={onValueChange} options={options} ariaLabel={ariaLabel} disabled={disabled} className={className} initialQuery={selected?.label ?? ""} />;
}

function CompactSelectControl({
  value,
  onValueChange,
  options,
  ariaLabel,
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
  disabled: boolean;
  className?: string;
  initialQuery: string;
  showAllOnOpen: boolean;
  inputRef: RefObject<HTMLInputElement | null>;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState(initialQuery);
  const matching = useMemo(() => options.filter((option) => (showAllOnOpen && open && query === initialQuery) || option.label.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())), [options, query, showAllOnOpen, open, initialQuery]);

  return <Autocomplete open={open} onOpenChange={next=>{setOpen(next);if(!next&&showAllOnOpen)setQuery(initialQuery);}} className={className} items={matching} value={query} onValueChange={setQuery} itemToStringValue={(option) => option.label} openOnInputClick disabled={disabled} autoHighlight>
    <AutocompleteInput ref={inputRef} aria-label={ariaLabel} showTrigger />
    <AutocompleteContent className="reui-compact-select__content">
      <AutocompleteEmpty>Sin opciones disponibles.</AutocompleteEmpty>
      <AutocompleteList>
        {matching.map((option) => <AutocompleteItem value={option} key={option.value} disabled={option.disabled} onClick={() => { setQuery(option.label); onValueChange(option.value); if(showAllOnOpen) requestAnimationFrame(()=>{if(inputRef.current?.isConnected)inputRef.current.focus();}); }}>
          <span>{option.label}</span>{option.value === value && <Check aria-hidden="true" />}
        </AutocompleteItem>)}
      </AutocompleteList>
    </AutocompleteContent>
  </Autocomplete>;
}
