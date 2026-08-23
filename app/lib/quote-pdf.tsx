import { Document, Image, Page, StyleSheet, Text, View, pdf } from "@react-pdf/renderer";

export type QuoteStatus = "draft" | "approved" | "sent" | "accepted" | "not_converted";

export type QuotePdfBranding = {
  display_name: string;
  legal_name?: string | null;
  tax_id?: string | null;
  fiscal_address?: string | null;
  document_title: string;
  contact_line?: string | null;
  header_message?: string | null;
  footer_message: string;
  terms_and_conditions?: string | null;
  website?: string | null;
  logo_url?: string | null;
  accent_color?: string | null;
};

export type QuotePdfDocument = {
  quote: {
    folio: string;
    status: QuoteStatus;
    currency_code: string;
    valid_until?: string | null;
    subtotal_amount: number;
    tax_amount: number;
    total_amount: number;
    approved_at?: string | null;
    approved_by?: { id: string; name: string | null } | null;
    supply_status?: "available" | "pending";
    shortage_line_count?: number;
    customer: { display_name: string; code?: string | null };
    location: { name: string; code?: string | null };
    lines: Array<{
      product_name: string;
      product_code?: string | null;
      quantity: number;
      unit_name?: string | null;
      unit_total_amount: number;
      line_total_amount: number;
      inventory_tracked?: boolean;
      available_quantity?: number | null;
      shortage_quantity?: number;
      availability_status?: "available" | "partial" | "unavailable" | "not_applicable";
    }>;
  };
  branding: QuotePdfBranding;
};

const palette = {
  ink: "#17221D",
  muted: "#617069",
  line: "#DCE5E0",
  accent: "#176F5E",
  accentDark: "#0E4D42",
  soft: "#F1F7F4",
  paper: "#FFFFFF",
  white: "#FFFFFF",
  amber: "#9B691B",
  slate: "#34423B",
};

const styles = StyleSheet.create({
  page: { backgroundColor: palette.paper, color: palette.ink, fontFamily: "Helvetica", fontSize: 9, paddingTop: 38, paddingRight: 42, paddingBottom: 54, paddingLeft: 42 },
  topRule: { position: "absolute", top: 0, left: 0, right: 0, height: 7, backgroundColor: palette.accent },
  header: { flexDirection: "row", alignItems: "flex-start", justifyContent: "space-between", marginBottom: 18 },
  identity: { flexDirection: "row", alignItems: "center", maxWidth: "68%" },
  logo: { width: 72, height: 40, objectFit: "contain", marginRight: 14 },
  brand: { fontSize: 17, fontFamily: "Helvetica-Bold", color: palette.ink, marginBottom: 4 },
  brandMeta: { color: palette.muted, fontSize: 7.5, lineHeight: 1.45 },
  documentLabel: { color: palette.muted, fontSize: 7, fontFamily: "Helvetica-Bold", letterSpacing: 1.1, textTransform: "uppercase", marginBottom: 4, textAlign: "right" },
  documentFolio: { color: palette.accentDark, fontSize: 14, fontFamily: "Helvetica-Bold", textAlign: "right" },
  hero: { flexDirection: "row", justifyContent: "space-between", alignItems: "center", borderRadius: 8, backgroundColor: palette.soft, padding: 14, marginBottom: 17 },
  heroTitle: { fontSize: 18, fontFamily: "Helvetica-Bold", color: palette.accentDark, marginBottom: 4 },
  heroMetaRow: { flexDirection: "row" },
  heroMeta: { color: palette.muted, fontSize: 8, lineHeight: 1.5, marginRight: 16 },
  status: { borderRadius: 20, backgroundColor: palette.accent, paddingTop: 6, paddingRight: 10, paddingBottom: 6, paddingLeft: 10, color: palette.white, fontSize: 7.5, fontFamily: "Helvetica-Bold", letterSpacing: .6, textTransform: "uppercase" },
  draftStatus: { backgroundColor: palette.amber },
  message: { borderLeftWidth: 3, borderLeftColor: palette.accent, backgroundColor: "#FAFCFB", color: palette.slate, lineHeight: 1.5, paddingTop: 8, paddingRight: 11, paddingBottom: 8, paddingLeft: 11, marginBottom: 16 },
  availabilityNotice: { borderWidth: 1, borderColor: "#E4C98F", borderRadius: 7, backgroundColor: "#FFF9EE", paddingTop: 9, paddingRight: 11, paddingBottom: 9, paddingLeft: 11, marginBottom: 14 },
  availabilityTitle: { color: palette.amber, fontSize: 8, fontFamily: "Helvetica-Bold", marginBottom: 3 },
  availabilityText: { color: palette.slate, fontSize: 7.2, lineHeight: 1.45 },
  customerGrid: { flexDirection: "row", marginBottom: 17 },
  customerBlock: { width: "62%", paddingRight: 18 },
  locationBlock: { width: "38%", borderLeftWidth: 1, borderLeftColor: palette.line, paddingLeft: 18 },
  eyebrow: { color: palette.accent, fontSize: 7, fontFamily: "Helvetica-Bold", letterSpacing: 1, textTransform: "uppercase", marginBottom: 5 },
  customerName: { fontSize: 12, fontFamily: "Helvetica-Bold", marginBottom: 4 },
  detail: { color: palette.muted, fontSize: 8, lineHeight: 1.45 },
  table: { marginBottom: 15 },
  tableHeader: { flexDirection: "row", alignItems: "center", borderTopWidth: 1, borderBottomWidth: 1, borderColor: palette.line, backgroundColor: "#FAFCFB", paddingTop: 8, paddingBottom: 8 },
  tableHeaderText: { color: palette.muted, fontSize: 7, fontFamily: "Helvetica-Bold", letterSpacing: .7, textTransform: "uppercase" },
  row: { flexDirection: "row", alignItems: "flex-start", borderBottomWidth: 1, borderBottomColor: palette.line, paddingTop: 10, paddingBottom: 10 },
  product: { width: "48%", paddingRight: 8 },
  quantity: { width: "14%", textAlign: "right", paddingRight: 8 },
  unitPrice: { width: "18%", textAlign: "right", paddingRight: 8 },
  amount: { width: "20%", textAlign: "right" },
  productName: { fontFamily: "Helvetica-Bold", fontSize: 8.5, lineHeight: 1.35, marginBottom: 3 },
  productMeta: { color: palette.muted, fontSize: 7.2 },
  productAvailability: { color: palette.amber, fontSize: 7.1, fontFamily: "Helvetica-Bold", marginTop: 3 },
  numeric: { fontSize: 8.5, fontVariant: "tabular-nums" },
  strongNumeric: { fontSize: 8.5, fontFamily: "Helvetica-Bold", fontVariant: "tabular-nums" },
  totalsWrap: { flexDirection: "row", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 18 },
  commercialNote: { width: "48%", borderTopWidth: 1, borderTopColor: palette.line, paddingTop: 8 },
  commercialNoteTitle: { color: palette.accent, fontSize: 7, fontFamily: "Helvetica-Bold", letterSpacing: .8, textTransform: "uppercase", marginBottom: 5 },
  commercialNoteText: { color: palette.muted, fontSize: 7.3, lineHeight: 1.5 },
  totals: { width: 210 },
  totalLine: { flexDirection: "row", justifyContent: "space-between", color: palette.muted, paddingTop: 4, paddingBottom: 4 },
  grandTotal: { flexDirection: "row", justifyContent: "space-between", borderRadius: 7, backgroundColor: palette.accentDark, color: palette.white, paddingTop: 10, paddingRight: 12, paddingBottom: 10, paddingLeft: 12, marginTop: 5, fontFamily: "Helvetica-Bold", fontSize: 10 },
  conditions: { borderTopWidth: 1, borderTopColor: palette.line, paddingTop: 10, marginBottom: 12 },
  conditionsText: { color: palette.muted, fontSize: 7.5, lineHeight: 1.5 },
  legalNote: { color: palette.muted, fontSize: 6.6, marginTop: 6 },
  footer: { position: "absolute", left: 42, right: 42, bottom: 22, flexDirection: "row", justifyContent: "space-between", alignItems: "flex-end", borderTopWidth: 1, borderTopColor: palette.line, paddingTop: 9, color: palette.muted, fontSize: 7 },
  footerCopy: { maxWidth: "78%", lineHeight: 1.45 },
  pageNumber: { fontFamily: "Helvetica-Bold" },
  watermark: { position: "absolute", top: 380, left: 115, color: "#E5C98D", fontSize: 58, fontFamily: "Helvetica-Bold", opacity: .18, transform: "rotate(-25deg)", letterSpacing: 5 },
});

const statusLabels: Record<QuoteStatus, string> = {
  draft: "Borrador",
  approved: "Aprobada",
  sent: "Enviada",
  accepted: "Aceptada",
  not_converted: "No concretada",
};

function money(value: number, currency = "MXN") {
  return new Intl.NumberFormat("es-MX", { style: "currency", currency }).format(Number(value ?? 0));
}

function date(value: string | null | undefined, long = false) {
  return value ? new Date(value.includes("T") ? value : `${value}T12:00:00`).toLocaleDateString("es-MX", long ? { dateStyle: "long" } : { dateStyle: "medium" }) : "Sin vigencia";
}

function QuoteDocument({ data }: { data: QuotePdfDocument }) {
  const { quote, branding } = data;
  const isDraft = quote.status === "draft";
  const issuedAt = quote.approved_at ?? new Date().toISOString();
  const accent = branding.accent_color ?? palette.accent;
  return <Document title={`${branding.document_title} ${quote.folio}`} author={branding.display_name} subject={`Cotizacion para ${quote.customer.display_name}`} creator="Satrapy">
    <Page size="A4" style={styles.page} wrap>
      <View style={[styles.topRule, { backgroundColor: accent }]} fixed />
      {isDraft && <Text style={styles.watermark} fixed>BORRADOR</Text>}
      <View style={styles.header}>
        <View style={styles.identity}>
          {/* eslint-disable-next-line jsx-a11y/alt-text -- @react-pdf/renderer Image is a PDF primitive, not a DOM image. */}
          {branding.logo_url ? <Image src={branding.logo_url} style={styles.logo} /> : null}
          <View>
            <Text style={styles.brand}>{branding.display_name}</Text>
            {branding.legal_name && branding.legal_name !== branding.display_name ? <Text style={styles.brandMeta}>{branding.legal_name}</Text> : null}
            {branding.tax_id ? <Text style={styles.brandMeta}>RFC {branding.tax_id}</Text> : null}
            {branding.fiscal_address ? <Text style={styles.brandMeta}>{branding.fiscal_address}</Text> : null}
            {branding.contact_line ? <Text style={styles.brandMeta}>{branding.contact_line}</Text> : null}
          </View>
        </View>
        <View>
          <Text style={styles.documentLabel}>{branding.document_title}</Text>
          <Text style={[styles.documentFolio, { color: accent }]}>{quote.folio}</Text>
        </View>
      </View>

      <View style={styles.hero}>
        <View>
          <Text style={[styles.heroTitle, { color: accent }]}>Propuesta comercial</Text>
          <View style={styles.heroMetaRow}>
            <Text style={styles.heroMeta}>Emisión: {date(issuedAt)}</Text>
            <Text style={styles.heroMeta}>Vigente hasta: {date(quote.valid_until)}</Text>
            <Text style={styles.heroMeta}>Moneda: {quote.currency_code}</Text>
          </View>
        </View>
        {isDraft ? <Text style={[styles.status, styles.draftStatus]}>{statusLabels[quote.status]}</Text> : null}
      </View>

      {branding.header_message ? <Text style={[styles.message, { borderLeftColor: accent }]}>{branding.header_message}</Text> : null}

      {quote.supply_status === "pending" ? <View style={styles.availabilityNotice} wrap={false}>
        <Text style={styles.availabilityTitle}>Surtido pendiente</Text>
        <Text style={styles.availabilityText}>Esta propuesta incluye productos sin existencia suficiente. La disponibilidad se confirma y reserva al crear el pedido.</Text>
      </View> : null}

      <View style={styles.customerGrid}>
        <View style={styles.customerBlock}>
          <Text style={[styles.eyebrow, { color: accent }]}>Cliente</Text>
          <Text style={styles.customerName}>{quote.customer.display_name}</Text>
          <Text style={styles.detail}>{quote.customer.code ?? "Sin clave de cliente"}</Text>
        </View>
        <View style={styles.locationBlock}>
          <Text style={[styles.eyebrow, { color: accent }]}>Sucursal</Text>
          <Text style={styles.customerName}>{quote.location.name}</Text>
          <Text style={styles.detail}>{quote.location.code ?? "Sin clave de sucursal"}</Text>
        </View>
      </View>

      <View style={styles.table}>
        <View style={styles.tableHeader} fixed>
          <Text style={[styles.tableHeaderText, styles.product]}>Producto</Text>
          <Text style={[styles.tableHeaderText, styles.quantity]}>Cantidad</Text>
          <Text style={[styles.tableHeaderText, styles.unitPrice]}>Precio unit.</Text>
          <Text style={[styles.tableHeaderText, styles.amount]}>Importe</Text>
        </View>
        {quote.lines.map((line, index) => <View key={`${line.product_code ?? line.product_name}-${index}`} style={styles.row} wrap={false}>
          <View style={styles.product}>
            <Text style={styles.productName}>{line.product_name}</Text>
            <Text style={styles.productMeta}>{line.product_code ?? "Sin codigo"}{line.unit_name ? ` · ${line.unit_name}` : ""}</Text>
            {Number(line.shortage_quantity ?? 0) > 0 ? <Text style={styles.productAvailability}>{line.availability_status === "unavailable" ? "Sin existencia" : "Existencia parcial"} · Disponible {Number(line.available_quantity ?? 0).toLocaleString("es-MX")} · Faltan {Number(line.shortage_quantity ?? 0).toLocaleString("es-MX")}</Text> : null}
          </View>
          <Text style={[styles.numeric, styles.quantity]}>{Number(line.quantity).toLocaleString("es-MX")}</Text>
          <Text style={[styles.numeric, styles.unitPrice]}>{money(line.unit_total_amount, quote.currency_code)}</Text>
          <Text style={[styles.strongNumeric, styles.amount]}>{money(line.line_total_amount, quote.currency_code)}</Text>
        </View>)}
      </View>

      <View style={styles.totalsWrap} wrap={false}>
        <View style={styles.commercialNote}>
          <Text style={[styles.commercialNoteTitle, { color: accent }]}>Resumen</Text>
          <Text style={styles.commercialNoteText}>{quote.lines.length} {quote.lines.length === 1 ? "partida cotizada" : "partidas cotizadas"}.</Text>
          <Text style={styles.commercialNoteText}>Precios expresados en {quote.currency_code}.</Text>
          <Text style={styles.commercialNoteText}>{quote.tax_amount > 0 ? "El IVA se muestra por separado." : "No se agregó IVA a esta propuesta."}</Text>
        </View>
        <View style={styles.totals}>
          <View style={styles.totalLine}><Text>Subtotal</Text><Text>{money(quote.subtotal_amount, quote.currency_code)}</Text></View>
          <View style={styles.totalLine}><Text>IVA</Text><Text>{money(quote.tax_amount, quote.currency_code)}</Text></View>
          <View style={[styles.grandTotal, { backgroundColor: accent }]}><Text>Total</Text><Text>{money(quote.total_amount, quote.currency_code)}</Text></View>
        </View>
      </View>

      {branding.terms_and_conditions ? <View style={styles.conditions} wrap={false}>
        <Text style={[styles.eyebrow, { color: accent }]}>Condiciones comerciales</Text>
        <Text style={styles.conditionsText}>{branding.terms_and_conditions}</Text>
        <Text style={styles.legalNote}>Esta cotización es informativa y no sustituye al comprobante fiscal de la operación.</Text>
      </View> : null}

      <View style={styles.footer} fixed>
        <View style={styles.footerCopy}>
          <Text>{branding.footer_message}</Text>
          {branding.website ? <Text>{branding.website}</Text> : null}
        </View>
        <Text style={styles.pageNumber} render={({ pageNumber, totalPages }) => `${pageNumber} / ${totalPages}`} />
      </View>
    </Page>
  </Document>;
}

export async function createQuotePdfBlob(data: QuotePdfDocument) {
  return pdf(<QuoteDocument data={data} />).toBlob();
}

export async function createQuotePdfUrl(data: QuotePdfDocument) {
  return URL.createObjectURL(await createQuotePdfBlob(data));
}

export async function downloadQuotePdf(data: QuotePdfDocument) {
  const url = await createQuotePdfUrl(data);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `${data.quote.folio}.pdf`;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 2_000);
}

export async function printQuotePdf(data: QuotePdfDocument) {
  const target = window.open("", "satrapy-quote-print", "popup,width=1000,height=760");
  if (!target) throw new Error("El navegador bloqueo la ventana de impresion.");
  target.document.write("<title>Preparando cotizacion...</title><p style=\"font-family:system-ui;padding:24px\">Preparando cotizacion...</p>");
  const url = await createQuotePdfUrl(data);
  target.addEventListener("load", () => { target.focus(); target.print(); }, { once: true });
  target.location.href = url;
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
}
