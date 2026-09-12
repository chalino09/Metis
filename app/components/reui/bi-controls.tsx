"use client";

import * as React from "react";
import { cn } from "@/app/lib/utils";
import {
  OperationalButton,
  OperationalInput,
  OperationalSelect,
} from "@/app/components/reui/operational-controls";

/**
 * BI controls are a thin visual adapter over Satrapy's operational controls.
 * Keep this API stable when a BI module needs to match the ReUI contract while
 * retaining the validated date inputs and existing select behavior.
 */
export const BiButton = React.forwardRef<HTMLButtonElement, React.ComponentProps<typeof OperationalButton>>(
  function BiButton({ className, ...props }, ref) {
    return <OperationalButton ref={ref} className={cn("bi-reui-button", className)} {...props} />;
  },
);

BiButton.displayName = "BiButton";

export const BiInput = React.forwardRef<HTMLInputElement, React.ComponentProps<typeof OperationalInput>>(
  function BiInput({ className, ...props }, ref) {
    return <OperationalInput ref={ref} className={cn("bi-reui-input", className)} {...props} />;
  },
);

BiInput.displayName = "BiInput";

export type BiSelectProps = {
  value: string;
  onValueChange: (value: string) => void;
  options: React.ComponentProps<typeof OperationalSelect>["options"];
  placeholder?: string;
  ariaLabel: string;
  disabled?: boolean;
  className?: string;
  style?: React.CSSProperties;
  showAllOnOpen?: boolean;
};

export function BiSelect({ className, ...props }: BiSelectProps) {
  return <OperationalSelect className={cn("bi-reui-select", className)} {...props} />;
}
