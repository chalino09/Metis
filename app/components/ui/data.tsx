"use client";

import { AlertCircle, Inbox, LoaderCircle, Search, X } from "lucide-react";
import { useState, type KeyboardEvent, type MouseEvent, type ReactNode } from "react";
import { isKeyboardActivationKey } from "@/app/lib/keyboard-activation";
import { Button, Input } from "./primitives";

export function PageHeading({ eyebrow, title, description, action }: { eyebrow: string; title: string; description: string; action?: ReactNode }) {
  return <header className="page-heading"><div><span className="eyebrow">{eyebrow}</span><h1>{title}</h1><p>{description}</p></div>{action}</header>;
}

export function DataPagination({ page, onChange, total, pageSize = 25, totalPages, label = "registros", showTotal = true }: { page: number; onChange: (page: number) => void; total?: number; pageSize?: number; totalPages?: number; label?: string; showTotal?: boolean }) {
  const pages = totalPages ?? Math.max(1, Math.ceil((total ?? 0) / pageSize));
  if (pages <= 1) return null;
  return <div className="data-pagination"><span>Página {page} de {pages}{showTotal && total !== undefined ? ` · ${total.toLocaleString("es-MX")} ${label}` : ""}</span><div><Button size="sm" variant="secondary" disabled={page <= 1} onClick={() => onChange(page - 1)}>Anterior</Button><Button size="sm" variant="secondary" disabled={page >= pages} onClick={() => onChange(page + 1)}>Siguiente</Button></div></div>;
}

export function DataToolbar({
  search,
  onSearchChange,
  placeholder,
  filters,
  activeFilters = 0,
  onClear,
  results,
}: {
  search?: string;
  onSearchChange?: (value: string) => void;
  placeholder?: string;
  filters?: ReactNode;
  activeFilters?: number;
  onClear?: () => void;
  results?: number;
}) {
  return (
    <div className="data-toolbar">
      {onSearchChange && <label className="data-toolbar__search"><Search size={16} aria-hidden="true" /><Input value={search} onChange={(event) => onSearchChange(event.target.value)} placeholder={placeholder} aria-label={placeholder} /></label>}
      {filters && <div className="data-toolbar__filters">{filters}</div>}
      {(activeFilters > 0 || results !== undefined) && <div className="data-toolbar__meta">
        {results !== undefined && <span>{results.toLocaleString("es-MX")} resultado{results === 1 ? "" : "s"}</span>}
        {activeFilters > 0 && onClear && <Button variant="ghost" size="sm" onClick={onClear}><X size={14} /> Limpiar filtros</Button>}
      </div>}
    </div>
  );
}

export function DataState({
  loading,
  error,
  hasData,
  empty,
  loadingLabel = "Cargando información…",
  errorTitle = "No pudimos cargar esta información.",
  emptyTitle = "No hay información para mostrar.",
  emptyAction,
  errorAction,
  children,
}: {
  loading: boolean;
  error: string | null;
  hasData: number;
  empty: string;
  loadingLabel?: string;
  errorTitle?: string;
  emptyTitle?: string;
  emptyAction?: ReactNode;
  errorAction?: ReactNode;
  children: ReactNode;
}) {
  if (loading) return <div className="data-state data-state--loading" role="status" aria-live="polite"><LoaderCircle className="spin" size={20} aria-hidden="true" /> <span>{loadingLabel}</span><div className="data-state__skeleton" aria-hidden="true" /></div>;
  if (error) return <div className="data-state data-state--error" role="alert"><AlertCircle size={20} aria-hidden="true" /><div><strong>{errorTitle}</strong><span>{error}</span>{errorAction}</div></div>;
  if (!hasData) return <div className="data-state data-state--empty" role="status"><Inbox size={21} aria-hidden="true" /><div><strong>{emptyTitle}</strong><span>{empty}</span>{emptyAction}</div></div>;
  return <>{children}</>;
}

export function DataRefreshStatus({ loading, hasData, label = "Actualizando resultados…" }: { loading: boolean; hasData: number; label?: string }) {
  if (!loading || !hasData) return null;
  return <div className="inline-status" role="status" aria-live="polite"><LoaderCircle className="spin" size={15} aria-hidden="true" /> {label}</div>;
}

export function Table({ children, className, ariaLabel, ariaBusy = false }: { children: ReactNode; className?: string; ariaLabel?: string; ariaBusy?: boolean }) {
  return <div className={`table-wrap surface-table ${className ?? ""}`} role={ariaLabel ? "region" : undefined} aria-label={ariaLabel} aria-busy={ariaBusy || undefined} tabIndex={ariaLabel ? 0 : undefined}><table>{children}</table></div>;
}

export function InteractiveTableRow({
  children,
  label,
  onActivate,
  className,
  selected = false,
  disabled = false,
}: {
  children: ReactNode;
  label: string;
  onActivate: () => void;
  className?: string;
  selected?: boolean;
  disabled?: boolean;
}) {
  if (disabled) return <tr className={className}>{children}</tr>;

  function handleClick(event: MouseEvent<HTMLTableRowElement>) {
    const target = event.target as HTMLElement;
    const interactiveTarget = target.closest("button, a, input, select, textarea, [role='button'], [role='link']");
    if (interactiveTarget && interactiveTarget !== event.currentTarget) return;
    onActivate();
  }

  function handleKeyDown(event: KeyboardEvent<HTMLTableRowElement>) {
    if (event.target !== event.currentTarget || !isKeyboardActivationKey(event.key)) return;
    event.preventDefault();
    onActivate();
  }

  return <tr className={className} role="button" tabIndex={0} aria-label={label} aria-pressed={selected || undefined} onClick={handleClick} onKeyDown={handleKeyDown}>{children}</tr>;
}

export function PagedCollection<T>({
  items,
  children,
  resetKey,
  pageSize = 25,
  label = "registros",
}: {
  items: T[];
  children: (visible: T[], startIndex: number) => ReactNode;
  resetKey?: string | number | null;
  pageSize?: number;
  label?: string;
}) {
  const [pagination, setPagination] = useState<{ key: typeof resetKey; page: number }>({ key: resetKey, page: 1 });
  const pages = Math.max(1, Math.ceil(items.length / pageSize));
  const page = pagination.key === resetKey ? Math.min(pagination.page, pages) : 1;
  const start = (page - 1) * pageSize;
  return <>
    {children(items.slice(start, start + pageSize), start)}
    <DataPagination page={page} total={items.length} pageSize={pageSize} label={label} onChange={(nextPage) => setPagination({ key: resetKey, page: nextPage })} />
  </>;
}
