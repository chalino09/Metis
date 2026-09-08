"use client";

import { useId, type ComponentProps } from "react";
import { Select as SharedSelect } from "@/app/components/ui/primitives";

// Radix reserves the empty string for clearing a selection. Keep the adapter
// inside Restaurant so older shared controls need no changes during rollout.
export function Select(props: ComponentProps<typeof SharedSelect>) {
  const emptyValue = `restaurant-empty-${useId()}`;
  return (
    <SharedSelect
      {...props}
      value={props.value || emptyValue}
      options={props.options.map((option) => ({
        ...option,
        value: option.value || emptyValue,
      }))}
      onValueChange={(value) =>
        props.onValueChange(value === emptyValue ? "" : value)
      }
    />
  );
}
