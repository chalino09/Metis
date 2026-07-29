"use client";

import { CircleGauge } from "lucide-react";
import { useEffect, useState, type ReactNode } from "react";
import { Badge } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";

export type NeutralStartModule = "inventory" | "cash_banks" | "receivables" | "payables" | "accounting" | "bi";

type ModuleState = {
  neutral: boolean;
  operation_count?: number;
  opening_set_count?: number;
  empty_value: string;
};

type NeutralStartState = {
  neutral_start: boolean;
  modules: Record<NeutralStartModule, ModuleState>;
};

const MODULE_COPY: Record<NeutralStartModule, { title: string; description: string }> = {
  inventory: {
    title: "Inventario en arranque neutral",
    description: "Las existencias permanecen en cero hasta una recepción real o una importación formal de saldos iniciales.",
  },
  cash_banks: {
    title: "Caja y bancos en arranque neutral",
    description: "No hay dinero supuesto: los saldos permanecen en cero hasta movimientos reales o un estado bancario importado y promovido.",
  },
  receivables: {
    title: "Cuentas por cobrar en arranque neutral",
    description: "El saldo es $0 mientras no existan ventas a crédito ni una apertura formal importada.",
  },
  payables: {
    title: "Cuentas por pagar en arranque neutral",
    description: "El saldo es $0 mientras no existan facturas confirmadas ni evidencia inicial importada.",
  },
  accounting: {
    title: "Contabilidad sin historia inventada",
    description: "No hay pólizas ni saldos implícitos. La apertura, si aplica, debe promoverse como un conjunto conciliado y auditable.",
  },
  bi: {
    title: "BI en arranque neutral",
    description: "Los flujos sin operaciones muestran $0; los indicadores que necesitan historia muestran “No disponible”. Satrapy no estima periodos inexistentes.",
  },
};

export function NeutralStartNotice({
  companyId,
  module,
  children,
}: {
  companyId: string;
  module: NeutralStartModule;
  children: ReactNode;
}) {
  const [state, setState] = useState<NeutralStartState | null>(null);

  useEffect(() => {
    let active = true;
    void getSupabaseClient().rpc("get_company_neutral_start", { p_company_id: companyId }).then(({ data }) => {
      if (active) setState((data as NeutralStartState | null) ?? null);
    });
    return () => { active = false; };
  }, [companyId]);

  const moduleState = state?.modules[module];
  const copy = MODULE_COPY[module];

  return <>
    {moduleState?.neutral && <section className="neutral-start-notice" role="status">
      <span className="neutral-start-notice__icon"><CircleGauge size={19} /></span>
      <div>
        <header><Badge tone="neutral">Arranque neutral</Badge><strong>{copy.title}</strong></header>
        <p>{copy.description}</p>
        <small>Puedes comenzar con operaciones reales. Importa sólo si necesitas incorporar saldos históricos por conjunto.</small>
      </div>
    </section>}
    {children}
  </>;
}
