"use client";

import {
  AlertTriangle,
  Cable,
  CheckCircle2,
  Megaphone,
  RefreshCw,
} from "lucide-react";
import { useCallback, useEffect, useState, type FormEvent } from "react";
import { PageHeading } from "@/app/components/ui/data";
import { Badge, Button, Field, Input } from "@/app/components/ui/primitives";
import { getSupabaseClient } from "@/app/lib/supabase";

type ConnectionSummary = {
  connected: boolean;
  last_sync_at?: string | null;
  last_error_code?: string | null;
};

type PilotAlert = {
  code: string;
  title: string;
  detail: string;
  count: number;
  severity: "critical" | "warning";
};

type PilotSummary = {
  settings: { low_margin_percent: number };
  shopify: ConnectionSummary & { shop_domain?: string };
  meta_ads: ConnectionSummary & { account_name?: string };
  coverage: {
    orders: number;
    order_lines: number;
    linked_lines: number;
    complete_addresses: number;
    known_shipping_costs: number;
    attributed_orders: number;
    last_order_at: string | null;
  };
  alerts: PilotAlert[];
};

const emptyAlerts: PilotAlert[] = [
  { code: "sync_failed", title: "Actualizaciones sin sincronizar", count: 0, severity: "critical", detail: "Reintenta la importación desde Shopify." },
  { code: "product_unlinked", title: "Productos sin vincular", count: 0, severity: "warning", detail: "Relaciona el SKU de Shopify con el producto canónico." },
  { code: "address_incomplete", title: "Direcciones incompletas", count: 0, severity: "warning", detail: "Corrige el domicilio en Shopify para recibir la actualización." },
  { code: "shipping_cost_unknown", title: "Costos de envío desconocidos", count: 0, severity: "warning", detail: "Importa el costo real antes de evaluar rentabilidad." },
  { code: "margin_at_risk", title: "Ventas con margen en riesgo", count: 0, severity: "warning", detail: "Incluye margen negativo y margen inferior al límite configurado." },
];

const emptySummary: PilotSummary = {
  settings: { low_margin_percent: 15 },
  shopify: { connected: false },
  meta_ads: { connected: false },
  coverage: { orders: 0, order_lines: 0, linked_lines: 0, complete_addresses: 0, known_shipping_costs: 0, attributed_orders: 0, last_order_at: null },
  alerts: emptyAlerts,
};

function dateTime(value?: string | null) {
  return value ? new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(value)) : "Sin sincronizaciones";
}

function percentage(part: number, total: number) {
  return total ? Math.round((part / total) * 100) : 0;
}

export function EcommerceModule({ companyId, permissions }: { companyId: string; permissions: string[] }) {
  const [summary, setSummary] = useState<PilotSummary>(emptySummary);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [shopDomain, setShopDomain] = useState("");
  const [connectingShopify, setConnectingShopify] = useState(false);
  const [connectionMessage, setConnectionMessage] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const { data, error: loadError } = await getSupabaseClient().rpc("get_ecommerce_pilot_summary", { p_company_id: companyId });
    if (loadError) {
      setError("No fue posible cargar Ecommerce. Actualiza la página; si continúa, revisa la conexión.");
      setSummary(emptySummary);
    } else {
      setSummary((data ?? emptySummary) as PilotSummary);
    }
    setLoading(false);
  }, [companyId]);

  useEffect(() => {
    void Promise.resolve().then(() => {
      return load();
    });
  }, [load]);

  async function connectShopify(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setConnectingShopify(true);
    setConnectionMessage(null);
    try {
      const session = (await getSupabaseClient().auth.getSession()).data.session;
      if (!session) throw new Error("La sesión terminó. Inicia sesión y vuelve a intentar.");
      const response = await fetch("/api/integrations/shopify/start", {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" },
        body: JSON.stringify({ companyId, shop: shopDomain }),
      });
      const result = await response.json() as { message?: string };
      if (!response.ok) throw new Error(result.message ?? "No fue posible conectar Shopify.");
      setConnectionMessage(result.message ?? "Shopify se conectó correctamente.");
      await load();
    } catch (value) {
      setConnectionMessage(value instanceof Error ? value.message : "No fue posible iniciar la conexión con Shopify.");
    } finally {
      setConnectingShopify(false);
    }
  }

  const linkedCoverage = percentage(summary.coverage.linked_lines, summary.coverage.order_lines);
  const addressCoverage = percentage(summary.coverage.complete_addresses, summary.coverage.orders);
  const costCoverage = percentage(summary.coverage.known_shipping_costs, summary.coverage.orders);
  const attributionCoverage = percentage(summary.coverage.attributed_orders, summary.coverage.orders);
  const activeAlerts = summary.alerts.reduce((total, alert) => total + alert.count, 0);
  const canConnectShopify = permissions.includes("manage_sales_orders");

  return <div className="content-frame ecommerce-module">
    <PageHeading
      eyebrow="Canal digital"
      title="Ecommerce"
      description="Supervisa la información recibida de Shopify y evalúa la rentabilidad del canal. La operación diaria permanece en Shopify."
      action={<Button variant="secondary" onClick={() => void load()} loading={loading}><RefreshCw size={16} aria-hidden="true" /> Actualizar datos</Button>}
    />

    <section className="ecommerce-section" aria-labelledby="ecommerce-connections-title" aria-busy={loading}>
      <header><span className="eyebrow">Integraciones</span><h2 id="ecommerce-connections-title">Conexiones del canal</h2><p>Las conexiones son de lectura y no modifican pedidos ni campañas.</p></header>
      <div className="ecommerce-connections-grid">
        <article className="ecommerce-connection">
          <div className="ecommerce-connection__icon" aria-hidden="true"><Cable size={22} /></div>
          <div><h3>{summary.shopify.connected ? summary.shopify.shop_domain : "Shopify"}</h3><p>{summary.shopify.connected ? `Última sincronización: ${dateTime(summary.shopify.last_sync_at)}` : "Conecta tu tienda para importar clientes, pedidos y envíos."}</p>
            {!summary.shopify.connected && canConnectShopify && <form className="ecommerce-connect-form" onSubmit={connectShopify}>
              <Field label="Dominio de tu tienda Shopify" hint="Ejemplo: mitienda.myshopify.com">
                <Input value={shopDomain} onChange={event => setShopDomain(event.target.value)} placeholder="mitienda.myshopify.com" autoComplete="url" autoCapitalize="none" spellCheck={false} required aria-describedby={connectionMessage ? "shopify-connection-message" : undefined} />
              </Field>
              <Button type="submit" variant="primary" loading={connectingShopify}><Cable size={16} aria-hidden="true" /> Conectar tienda</Button>
            </form>}
            {!summary.shopify.connected && !canConnectShopify && <p className="ecommerce-connect-message">Solicita a una persona con permiso para administrar pedidos que conecte la tienda.</p>}
            {connectionMessage && <p id="shopify-connection-message" className={connectionMessage.includes("correctamente") ? "ecommerce-connect-message is-success" : "ecommerce-connect-message is-error"} role={connectionMessage.includes("correctamente") ? "status" : "alert"}>{connectionMessage}</p>}
          </div>
          <Badge tone={summary.shopify.connected ? (summary.shopify.last_error_code ? "warning" : "success") : "warning"}>{summary.shopify.connected ? (summary.shopify.last_error_code ? "Requiere atención" : "Conectado") : "Por conectar"}</Badge>
        </article>
        <article className="ecommerce-connection">
          <div className="ecommerce-connection__icon" aria-hidden="true"><Megaphone size={22} /></div>
          <div><h3>{summary.meta_ads.connected ? summary.meta_ads.account_name || "Meta Ads" : "Meta Ads"}</h3><p>{summary.meta_ads.connected ? `Última sincronización: ${dateTime(summary.meta_ads.last_sync_at)}` : "Conecta la cuenta después de Shopify para medir campañas contra ventas reales."}</p></div>
          <Badge tone={summary.meta_ads.connected ? (summary.meta_ads.last_error_code ? "warning" : "success") : "neutral"}>{summary.meta_ads.connected ? (summary.meta_ads.last_error_code ? "Requiere atención" : "Conectado") : "Pendiente"}</Badge>
        </article>
      </div>
      {error && <p className="ecommerce-load-error" role="alert">{error}</p>}
    </section>

    <section className="ecommerce-section" aria-labelledby="ecommerce-alerts-title">
      <header><span className="eyebrow">Control de calidad</span><h2 id="ecommerce-alerts-title">Alertas que requieren revisión</h2><p>{error ? "Las alertas estarán disponibles cuando se restablezca la conexión." : activeAlerts ? `${activeAlerts} incidencias pueden afectar el análisis del canal.` : "No hay incidencias pendientes en los datos sincronizados."}</p></header>
      <div className="ecommerce-alert-list" aria-live="polite">
        {summary.alerts.map(alert => <article key={alert.code} className={error ? "is-unavailable" : alert.count ? `is-${alert.severity}` : "is-clear"}>
          {error || alert.count ? <AlertTriangle size={19} aria-hidden="true" /> : <CheckCircle2 size={19} aria-hidden="true" />}
          <div><h3>{alert.title}</h3><p>{alert.detail}</p></div>
          <strong aria-label={error ? "Datos no disponibles" : `${alert.count} incidencias`}>{error ? "—" : alert.count}</strong>
        </article>)}
      </div>
    </section>

    <section className="ecommerce-section" aria-labelledby="ecommerce-coverage-title">
      <header><span className="eyebrow">Cobertura de datos</span><h2 id="ecommerce-coverage-title">Información disponible para análisis</h2><p>Clientes y direcciones se guardan en los registros canónicos; aquí sólo se mide la cobertura del canal.</p></header>
      <div className="ecommerce-coverage-grid" aria-live="polite">
        <article><span>Pedidos registrados</span><strong>{error ? "—" : summary.coverage.orders}</strong><small>{error ? "Datos no disponibles" : summary.coverage.last_order_at ? `Último: ${dateTime(summary.coverage.last_order_at)}` : "Aún no hay pedidos"}</small></article>
        <article><span>Productos vinculados</span><strong>{error ? "—" : `${linkedCoverage}%`}</strong><small>{error ? "Datos no disponibles" : `${summary.coverage.linked_lines} de ${summary.coverage.order_lines} partidas`}</small></article>
        <article><span>Direcciones completas</span><strong>{error ? "—" : `${addressCoverage}%`}</strong><small>{error ? "Datos no disponibles" : `${summary.coverage.complete_addresses} de ${summary.coverage.orders} pedidos`}</small></article>
        <article><span>Costo de envío conocido</span><strong>{error ? "—" : `${costCoverage}%`}</strong><small>{error ? "Datos no disponibles" : `${summary.coverage.known_shipping_costs} de ${summary.coverage.orders} pedidos`}</small></article>
        <article><span>Ventas con atribución</span><strong>{error ? "—" : `${attributionCoverage}%`}</strong><small>{error ? "Datos no disponibles" : `${summary.coverage.attributed_orders} vinculadas a una campaña`}</small></article>
      </div>
    </section>

  </div>;
}
