"use client";

import type { ComponentProps } from "react";
import { OperationalSelect } from "@/app/components/reui/operational-controls";

export function Select(props: ComponentProps<typeof OperationalSelect>) {
  return <OperationalSelect {...props} showAllOnOpen />;
}
