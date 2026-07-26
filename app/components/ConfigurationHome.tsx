"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  AlertCircle,
  ArrowRight,
  Building2,
  CheckCircle2,
  Database,
  History,
  Landmark,
  RefreshCw,
  Search,
  ShieldCheck,
  ShoppingCart,
  SlidersHorizontal,
  Users,
  WalletCards,
  X,
} from "lucide-react";
import { Badge } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";

type ConfigurationMode = "all" | "setup" | "manage" | "audit";
type ConfigurationIcon = typeof Building2;
type Destination = {
  id: string;
  label: string;
  description: string;
  href: string;
  icon: ConfigurationIcon;
  group: string;
  mode: Exclude<ConfigurationMode, "all">;
  keywords: string;
  visible: boolean;
};
type ReadinessModule = {
  code: string;
  label: string;
  description: string;
  href: string;
  checks: Array<{ code: string; label: string; count: number; status: "ready" | "pending" }>;
};
type Readiness = {
  ready_checks: number;
  total_checks: number;
  modules: ReadinessModule[];
};

const GROUPS = [
  { id: "setup", label: "Puesta en marcha", description: "Carga inicial y comprobación de la base operativa." },
  { id: "company", label: "Empresa y acceso", description: "Estructura, personas y alcance de operación." },
  { id: "operation", label: "Operación comercial", description: "Reglas necesarias para vender y cobrar." },
  { id: "finance", label: "Finanzas", description: "Base contable y cuentas financieras." },
  { id: "audit", label: "Auditoría", description: "Evidencia de cambios e importaciones." },
] as const;

const MODES: Array<{ value: ConfigurationMode; label: string }> = [
  { value: "all", label: "Todo" },
  { value: "setup", label: "Puesta en marcha" },
  { value: "manage", label: "Administración" },
  { value: "audit", label: "Auditoría" },
];

function normalize(value: string) {
  return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
}

export function ConfigurationHome({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const has = useCallback((...codes: string[]) => codes.some((code) => permissions.includes(code) || permissions.includes("*")), [permissions]);
  const canReviewMigration = has("import_data", "import_prices", "import_costs", "import_accounting_opening");
  const [query, setQuery] = useState("");
  const [mode, setMode] = useState<ConfigurationMode>("all");
  const [readiness, setReadiness] = useState<Readiness | null>(null);
  const [readinessLoading, setReadinessLoading] = useState(canReviewMigration);
  const [readinessError, setReadinessError] = useState(false);
  const searchRef = useRef<HTMLInputElement>(null);

  const loadReadiness = useCallback(async () => {
    if (!canReviewMigration) return;
    setReadinessLoading(true);
    setReadinessError(false);
    try {
      const { data, error } = await getSupabaseClient().rpc("get_initial_migration_readiness", { p_company_id: companyId });
      if (error || !data) {
        setReadiness(null);
        setReadinessError(true);
        return;
      }
      setReadiness(data as Readiness);
    } catch {
      setReadiness(null);
      setReadinessError(true);
    } finally {
      setReadinessLoading(false);
    }
  }, [canReviewMigration, companyId]);

  useEffect(() => {
    if (!canReviewMigration) return;
    void Promise.resolve().then(loadReadiness);
  }, [canReviewMigration, loadReadiness]);

  useEffect(() => {
    function focusSearch(event: KeyboardEvent) {
      const target = event.target as HTMLElement | null;
      if (event.key !== "/" || target?.matches("input, textarea, select, [contenteditable='true']")) return;
      event.preventDefault();
      searchRef.current?.focus();
    }
    window.addEventListener("keydown", focusSearch);
    return () => window.removeEventListener("keydown", focusSearch);
  }, []);

  const destinations = useMemo<Destination[]>(() => {
    const entries: Destination[] = [
    {
      id: "migration-readiness",
      label: "Migración inicial",
      description: "Comprueba qué información de origen tiene evidencia real.",
      href: "/satrapy/configuracion/migracion-inicial",
      icon: CheckCircle2,
      group: "setup",
      mode: "setup",
      keywords: "inicio avance cobertura checklist datos importar",
      visible: canReviewMigration,
    },
    {
      id: "migration-center",
      label: "Centro de Migración",
      description: "Carga archivos, valida excepciones y conserva cada lote.",
      href: "/satrapy/configuracion/importaciones",
      icon: Database,
      group: "setup",
      mode: "setup",
      keywords: "alpha archivos excel carga importacion lotes",
      visible: canReviewMigration,
    },
    {
      id: "locations",
      label: "Sucursales y ubicaciones",
      description: "Administra la estructura física donde ocurre la operación.",
      href: "/satrapy/configuracion/empresa/sucursales",
      icon: Building2,
      group: "company",
      mode: "manage",
      keywords: "empresa tiendas almacenes oficinas ubicacion sucursal",
      visible: has("manage_locations"),
    },
    {
      id: "users",
      label: "Usuarios y accesos",
      description: "Invita personas y limita su acceso por rol y sucursal.",
      href: "/satrapy/configuracion/usuarios",
      icon: Users,
      group: "company",
      mode: "manage",
      keywords: "personas permisos roles seguridad invitaciones",
      visible: has("manage_company_users"),
    },
    {
      id: "sales",
      label: "Ventas y caja",
      description: "Configura pagos, cajas, precios, descuentos y documentos.",
      href: "/satrapy/configuracion/ventas",
      icon: ShoppingCart,
      group: "operation",
      mode: "manage",
      keywords: "configuracion comercial formas pago caja precios descuentos ticket cotizacion",
      visible: has("manage_payment_methods", "manage_discount_policies", "manage_locations", "manage_prices", "manage_ticket_branding"),
    },
    {
      id: "assortments",
      label: "Surtidos comerciales",
      description: "Define qué productos pertenecen al surtido de cada ubicación.",
      href: "/satrapy/configuracion/surtidos",
      icon: SlidersHorizontal,
      group: "operation",
      mode: "manage",
      keywords: "productos catalogo venta disponibilidad pertenencia",
      visible: has("manage_assortments"),
    },
    {
      id: "accounting",
      label: "Configuración contable",
      description: "Mantén la base contable, automatización y cuentas de control.",
      href: "/satrapy/configuracion/contabilidad",
      icon: Landmark,
      group: "finance",
      mode: "manage",
      keywords: "contabilidad catalogo cuentas polizas periodos",
      visible: has("view_accounting", "configure_accounting"),
    },
    {
      id: "bank-accounts",
      label: "Cuentas bancarias",
      description: "Administra las cuentas financieras usadas en pagos y conciliación.",
      href: "/satrapy/configuracion/cuentas-bancarias",
      icon: WalletCards,
      group: "finance",
      mode: "manage",
      keywords: "bancos cuentas pagadoras pagos proveedores finanzas",
      visible: has("view_banking", "manage_supplier_paying_accounts"),
    },
    {
      id: "import-audit",
      label: "Auditoría de importaciones",
      description: "Consulta archivos, validaciones, promociones y resultados.",
      href: "/satrapy/configuracion/auditoria-importaciones",
      icon: History,
      group: "audit",
      mode: "audit",
      keywords: "historial evidencia alpha lotes cambios",
      visible: has("view_import_audit"),
    },
    {
      id: "sales-audit",
      label: "Auditoría comercial",
      description: "Revisa cambios de precios, descuentos y configuración de venta.",
      href: "/satrapy/configuracion/auditoria-comercial",
      icon: ShieldCheck,
      group: "audit",
      mode: "audit",
      keywords: "historial evidencia ventas caja precios cambios",
      visible: has("view_sales_audit"),
    },
    ];
    return entries.filter((destination) => destination.visible);
  }, [canReviewMigration, has]);

  const normalizedQuery = normalize(query);
  const visibleDestinations = destinations.filter((destination) => {
    const matchesMode = mode === "all" || destination.mode === mode;
    const searchable = normalize(`${destination.label} ${destination.description} ${destination.keywords}`);
    return matchesMode && (!normalizedQuery || searchable.includes(normalizedQuery));
  });
  const visibleGroups = GROUPS.map((group) => ({
    ...group,
    destinations: visibleDestinations.filter((destination) => destination.group === group.id),
  })).filter((group) => group.destinations.length);
  const nextModule = readiness?.modules.find((module) => module.checks.some((check) => check.status !== "ready"));
  const readyChecks = readiness?.ready_checks ?? 0;
  const totalChecks = readiness?.total_checks ?? 0;
  const readinessPercentage = totalChecks ? Math.round((readyChecks / totalChecks) * 100) : 0;
  const hasDirectoryFilter = Boolean(normalizedQuery) || mode !== "all";
  const directorySummary = hasDirectoryFilter
    ? `${visibleDestinations.length} resultado${visibleDestinations.length === 1 ? "" : "s"}`
    : `${destinations.length} opciones disponibles`;

  return <div className="content-frame configuration-home">
    <header className="configuration-home__heading">
      <div><span className="eyebrow">Administración</span><h1>Configuración</h1><p>Encuentra un ajuste por nombre o continúa desde el punto que requiere atención.</p></div>
      <Badge><span aria-live="polite">{directorySummary}</span></Badge>
    </header>

    <section className="configuration-command-center" aria-label="Buscar y continuar configuración">
      <div className="configuration-command-center__search">
        <span>¿Qué quieres configurar?</span>
        <label>
          <Search size={19} aria-hidden="true" />
          <input ref={searchRef} value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Busca caja, usuarios, precios, sucursales…" aria-label="Buscar en Configuración" />
          {query && <button type="button" aria-label="Limpiar búsqueda" onClick={() => { setQuery(""); searchRef.current?.focus(); }}><X size={16} /></button>}
          {!query && <kbd>/</kbd>}
        </label>
      </div>
      {canReviewMigration && <div className="configuration-readiness">
        {readinessLoading && !readiness ? <><span className="configuration-readiness__skeleton" /><div role="status" aria-live="polite"><small>Comprobando puesta en marcha</small><strong>Calculando evidencia…</strong><p>Esta revisión no modifica la información de la empresa.</p></div></> : readinessError ? <div className="configuration-readiness__notice" role="status" aria-live="polite">
          <AlertCircle size={21} aria-hidden="true" />
          <div><small>Puesta en marcha</small><strong>No pudimos comprobar la evidencia</strong><p>La configuración sigue disponible. Intenta actualizar el estado cuando quieras.</p></div>
          <button type="button" onClick={() => void loadReadiness()}><RefreshCw size={14} />Reintentar</button>
        </div> : <>
          <div className="configuration-readiness__score"><strong>{readinessPercentage}%</strong><span>con evidencia</span></div>
          <div><small>Puesta en marcha</small><strong>{nextModule ? `Siguiente: ${nextModule.label}` : "Evidencia inicial completa"}</strong><p>{readyChecks} de {totalChecks} verificaciones detectadas. No implica conciliación.</p></div>
          <Link href={nextModule?.href ?? "/satrapy/configuracion/migracion-inicial"}>{nextModule ? "Abrir siguiente" : "Ver estado"} <ArrowRight size={15} /></Link>
        </>}
      </div>}
    </section>

    <nav className="configuration-mode-nav" aria-label="Tipo de configuración">
      {MODES.map((item) => {
        const count = item.value === "all" ? destinations.length : destinations.filter((destination) => destination.mode === item.value).length;
        if (item.value !== "all" && count === 0) return null;
        return <button type="button" className={mode === item.value ? "is-active" : ""} aria-pressed={mode === item.value} onClick={() => setMode(item.value)} key={item.value}><span>{item.label}</span><b>{count}</b></button>;
      })}
    </nav>

    {visibleGroups.length ? <div className="configuration-directory">
      {visibleGroups.map((group) => <section className="configuration-directory__group" aria-labelledby={`configuration-${group.id}`} key={group.id}>
        <header><div><h2 id={`configuration-${group.id}`}>{group.label}</h2><p>{group.description}</p></div><span>{group.destinations.length}</span></header>
        <div>{group.destinations.map((destination) => {
          const Icon = destination.icon;
          return <Link href={destination.href} key={destination.id}>
            <span className="configuration-directory__icon"><Icon size={18} /></span>
            <span className="configuration-directory__copy"><strong>{destination.label}</strong><small>{destination.description}</small></span>
            <span className={`configuration-directory__kind is-${destination.mode}`}>{destination.mode === "setup" ? "Inicio" : destination.mode === "audit" ? "Auditoría" : "Administración"}</span>
            <ArrowRight className="configuration-directory__arrow" size={16} />
          </Link>;
        })}</div>
      </section>)}
    </div> : <section className="configuration-no-results">
      <Search size={22} />
      <strong>No encontramos una configuración para “{query.trim() || "estos filtros"}”</strong>
      <p>Prueba con el nombre del proceso, por ejemplo “caja”, “usuarios” o “precios”, o limpia los filtros.</p>
      <button type="button" onClick={() => { setQuery(""); setMode("all"); searchRef.current?.focus(); }}>Ver toda la configuración</button>
    </section>}
  </div>;
}
