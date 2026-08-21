"use client";

import Link from "next/link";
import { PageHeading } from "@/app/components/ui/data";

export type ReceivablesTab = "cartera" | "gestiones";

const RECEIVABLES_PATH = "/satrapy/ventas/cuentas-por-cobrar";
const COLLECTION_AUTOMATION_PATH = `${RECEIVABLES_PATH}/automatizacion`;

export function ReceivablesTabs({ active, showGestiones = true, ariaLabel = "Vistas de cuentas por cobrar" }: { active: ReceivablesTab; showGestiones?: boolean; ariaLabel?: string }) {
  return <nav className="receivables-tabs" aria-label={ariaLabel}>
    <Link href={RECEIVABLES_PATH} aria-current={active === "cartera" ? "page" : undefined}>Cartera</Link>
    {showGestiones && <Link href={COLLECTION_AUTOMATION_PATH} aria-current={active === "gestiones" ? "page" : undefined}>Gestiones</Link>}
  </nav>;
}

export function ReceivablesModuleHeader({ active, title, description, showGestiones = true, tabsLabel = "Vistas de cuentas por cobrar" }: { active: ReceivablesTab; title: string; description: string; showGestiones?: boolean; tabsLabel?: string }) {
  return <>
    <PageHeading eyebrow="Cuentas por cobrar" title={title} description={description} />
    <ReceivablesTabs active={active} showGestiones={showGestiones} ariaLabel={tabsLabel} />
  </>;
}
