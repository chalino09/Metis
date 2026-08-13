"use client";

import { AlertCircle, AlertTriangle, ArrowDownRight, ArrowRight, ArrowUpRight, CheckCircle2, Inbox, LoaderCircle } from "lucide-react";
import {
  type HTMLAttributes,
  type ReactNode,
} from "react";
import { Table } from "./data";
import { Drawer } from "./primitives";

function cx(...classes: Array<string | false | null | undefined>) {
  return classes.filter(Boolean).join(" ");
}

export type BiSemanticTone = "neutral" | "accent" | "success" | "warning" | "danger";

export function MetricDelta({
  value,
  label,
  direction = "flat",
  tone = "neutral",
  className,
}: {
  value: ReactNode;
  label?: ReactNode;
  direction?: "up" | "down" | "flat";
  tone?: BiSemanticTone;
  className?: string;
}) {
  const Icon = direction === "up" ? ArrowUpRight : direction === "down" ? ArrowDownRight : ArrowRight;
  return <span className={cx("bi-metric-delta", `is-${tone}`, className)}>
    <Icon size={13} aria-hidden="true" />
    <span className="bi-metric-delta__value">{value}</span>
    {label && <span className="bi-metric-delta__label">{label}</span>}
  </span>;
}

export function MetricCard({
  label,
  value,
  eyebrow,
  description,
  delta,
  headerAction,
  footerAction,
  onSelect,
  selected = false,
  unavailable = false,
  featured = false,
  className,
}: {
  label: ReactNode;
  value: ReactNode;
  eyebrow?: ReactNode;
  description?: ReactNode;
  delta?: ReactNode;
  headerAction?: ReactNode;
  footerAction?: ReactNode;
  onSelect?: () => void;
  selected?: boolean;
  unavailable?: boolean;
  featured?: boolean;
  className?: string;
}) {
  const content = <><span className="bi-metric-card__label">{label}</span><strong className="bi-metric-card__value">{value}</strong></>;
  return <article className={cx("bi-metric-card", selected && "is-selected", unavailable && "is-unavailable", featured && "is-featured", className)}>
    {(eyebrow || headerAction) && <header><div>{eyebrow}</div>{headerAction}</header>}
    {onSelect ? <button type="button" className="bi-metric-card__main" onClick={onSelect} disabled={unavailable}>{content}</button> : <div className="bi-metric-card__main">{content}</div>}
    {description && <div className="bi-metric-card__description">{description}</div>}
    {delta && <div className="bi-metric-card__delta">{delta}</div>}
    {footerAction && <footer>{footerAction}</footer>}
  </article>;
}

const attentionIcons = {
  neutral: AlertCircle,
  accent: AlertCircle,
  success: CheckCircle2,
  warning: AlertTriangle,
  danger: AlertCircle,
} as const;

export function AttentionItem({
  title,
  description,
  tone = "neutral",
  action,
  className,
}: {
  title: ReactNode;
  description?: ReactNode;
  tone?: BiSemanticTone;
  action?: ReactNode;
  className?: string;
}) {
  const Icon = attentionIcons[tone];
  return <article className={cx("bi-attention-item", `is-${tone}`, className)}>
    <Icon size={17} aria-hidden="true" />
    <div><strong>{title}</strong>{description && <p>{description}</p>}</div>
    {action && <div className="bi-attention-item__action">{action}</div>}
  </article>;
}

export function BiFilterBar({
  children,
  pending = false,
  ariaLabel = "Filtros de Business Intelligence",
  className,
}: {
  children: ReactNode;
  pending?: boolean;
  ariaLabel?: string;
  className?: string;
}) {
  return <section className={cx("bi-filter-bar", pending && "has-pending", className)} aria-label={ariaLabel}>{children}</section>;
}

export function AnalyticsTable({
  children,
  caption,
  className,
}: {
  children: ReactNode;
  caption?: string;
  className?: string;
}) {
  return <div className="bi-analytics-table">
    <Table className={className}>{caption && <caption>{caption}</caption>}{children}</Table>
  </div>;
}

export function BiDrawer({
  open,
  onOpenChange,
  title,
  eyebrow,
  description,
  children,
  footer,
  className,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  eyebrow?: string;
  description?: ReactNode;
  children: ReactNode;
  footer?: ReactNode;
  className?: string;
}) {
  return <Drawer open={open} onOpenChange={onOpenChange} title={title} className={cx("bi-drawer", className)}>
    {(eyebrow || description) && <header className="bi-drawer__intro">{eyebrow && <span className="eyebrow">{eyebrow}</span>}{description && <p>{description}</p>}</header>}
    <div className="bi-drawer__content">{children}</div>
    {footer && <footer className="bi-drawer__footer">{footer}</footer>}
  </Drawer>;
}

export function ChartContainer({
  eyebrow,
  title,
  description,
  action,
  legend,
  children,
  selected = false,
  className,
  ...props
}: Omit<HTMLAttributes<HTMLElement>, "title"> & {
  eyebrow?: ReactNode;
  title: ReactNode;
  description?: ReactNode;
  action?: ReactNode;
  legend?: ReactNode;
  selected?: boolean;
}) {
  return <article className={cx("bi-chart-container", selected && "is-selected", className)} {...props}>
    <header><div>{eyebrow && <span className="eyebrow">{eyebrow}</span>}<h2>{title}</h2>{description && <p>{description}</p>}</div>{action}</header>
    {legend && <div className="bi-chart-container__legend">{legend}</div>}
    <div className="bi-chart-container__body">{children}</div>
  </article>;
}

export type BiStateKind = "loading" | "empty" | "error" | "partial";

export function BiState({
  kind,
  title,
  description,
  action,
  compact = false,
  className,
}: {
  kind: BiStateKind;
  title: ReactNode;
  description?: ReactNode;
  action?: ReactNode;
  compact?: boolean;
  className?: string;
}) {
  const Icon = kind === "loading" ? LoaderCircle : kind === "empty" ? Inbox : kind === "partial" ? AlertTriangle : AlertCircle;
  const liveProps = kind === "error" ? { role: "alert" as const } : { role: "status" as const, "aria-live": "polite" as const };
  return <div className={cx("bi-state", `is-${kind}`, compact && "is-compact", className)} {...liveProps}>
    <Icon className={kind === "loading" ? "spin" : undefined} size={compact ? 16 : 20} aria-hidden="true" />
    <div><strong>{title}</strong>{description && <p>{description}</p>}</div>
    {action && <div className="bi-state__action">{action}</div>}
    {kind === "loading" && !compact && <div className="bi-state__skeleton" aria-hidden="true"><i /><i /><i /></div>}
  </div>;
}
