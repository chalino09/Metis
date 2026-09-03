"use client";

import { Check } from "lucide-react";
import { useMemo, useState } from "react";
import { Autocomplete, AutocompleteContent, AutocompleteEmpty, AutocompleteInput, AutocompleteItem, AutocompleteList } from "@/components/reui/autocomplete";

export type CompactSelectOption = { value: string; label: string; disabled?: boolean };

export function CompactSelect({
  value,
  onValueChange,
  options,
  ariaLabel,
  disabled = false,
  className,
}: {
  value: string;
  onValueChange: (value: string) => void;
  options: CompactSelectOption[];
  ariaLabel: string;
  disabled?: boolean;
  className?: string;
}) {
  const selected = options.find((option) => option.value === value);
  return <CompactSelectControl key={value} value={value} onValueChange={onValueChange} options={options} ariaLabel={ariaLabel} disabled={disabled} className={className} initialQuery={selected?.label ?? ""} />;
}

function CompactSelectControl({
  value,
  onValueChange,
  options,
  ariaLabel,
  disabled,
  className,
  initialQuery,
}: {
  value: string;
  onValueChange: (value: string) => void;
  options: CompactSelectOption[];
  ariaLabel: string;
  disabled: boolean;
  className?: string;
  initialQuery: string;
}) {
  const [query, setQuery] = useState(initialQuery);
  const matching = useMemo(() => options.filter((option) => option.label.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase())), [options, query]);

  return <Autocomplete className={className} items={matching} value={query} onValueChange={setQuery} itemToStringValue={(option) => option.label} openOnInputClick disabled={disabled} autoHighlight>
    <AutocompleteInput aria-label={ariaLabel} showTrigger />
    <AutocompleteContent className="reui-compact-select__content">
      <AutocompleteEmpty>Sin opciones disponibles.</AutocompleteEmpty>
      <AutocompleteList>
        {matching.map((option) => <AutocompleteItem value={option} key={option.value} disabled={option.disabled} onClick={() => { setQuery(option.label); onValueChange(option.value); }}>
          <span>{option.label}</span>{option.value === value && <Check aria-hidden="true" />}
        </AutocompleteItem>)}
      </AutocompleteList>
    </AutocompleteContent>
  </Autocomplete>;
}
