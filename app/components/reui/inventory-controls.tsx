"use client";
import type { ComponentProps } from "react";
import { OperationalDrawer, OperationalModal } from "./operational-panels";
export { OperationalButton as Button, OperationalInput as Input, OperationalSelect as Select, OperationalDataToolbar as DataToolbar } from "./operational-controls";
export function Drawer(props: ComponentProps<typeof OperationalDrawer>) { return <OperationalDrawer {...props} className={`inventory-surface ${props.className ?? ""}`} />; }
export function Modal(props: ComponentProps<typeof OperationalModal>) { return <OperationalModal {...props} className={`inventory-surface ${props.className ?? ""}`} />; }
