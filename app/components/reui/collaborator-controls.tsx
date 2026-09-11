"use client";

import { cloneElement, isValidElement, useId, type ComponentProps, type ReactElement, type ReactNode } from "react";
import { OperationalDrawer, OperationalModal } from "./operational-panels";
import { OperationalSelect } from "./operational-controls";
export { OperationalButton as Button, OperationalInput as Input, OperationalDataToolbar as DataToolbar } from "./operational-controls";
export { OperationalTabs as Tabs } from "./operational-panels";

export function Select(props: ComponentProps<typeof OperationalSelect>) { return <OperationalSelect {...props} showAllOnOpen />; }

export function Drawer(props: ComponentProps<typeof OperationalDrawer>) {
  return <OperationalDrawer {...props} className={`collaborator-surface ${props.className ?? ""}`}><div className="collaborator-panel-content" inert={props.closeDisabled||undefined}>{props.children}</div></OperationalDrawer>;
}
export function Modal(props: ComponentProps<typeof OperationalModal>) {
  return <OperationalModal {...props} className={`collaborator-surface ${props.className ?? ""}`}><div className="collaborator-panel-content" inert={props.closeDisabled||undefined}>{props.children}</div></OperationalModal>;
}
/** Keep label, control and assistance in separate grid tracks, including composite fields. */
export function Field({ label, hint, error, children }: { label: ReactNode; hint?: string; error?: string; children: ReactNode }) {
  const id = useId();
  const child = children as ReactElement<Record<string, unknown>>;
  const input = isValidElement(children) && "value" in child.props && !("options" in child.props);
  const controlId = input ? (child.props.id as string | undefined) ?? id : undefined;
  return <div className="ui-field collaborator-field">
    {controlId ? <label htmlFor={controlId}>{label}</label> : <span>{label}</span>}
    {input ? cloneElement(child, { id: controlId, "aria-describedby": hint || error ? `${id}-help` : undefined, "aria-invalid": error ? true : child.props["aria-invalid"] }) : children}
    {(error || hint) && <small id={`${id}-help`} className={error ? "ui-field__error" : undefined} role={error ? "alert" : undefined}>{error || hint}</small>}
  </div>;
}
