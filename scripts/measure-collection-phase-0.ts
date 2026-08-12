import { createClient } from "@supabase/supabase-js";

const companyName = process.argv.slice(2).join(" ").trim();
const measuredAt = new Date("2026-08-12T12:00:00-06:00");
const pageSize = 1_000;

if (!companyName) throw new Error("Indica el nombre exacto de la empresa.");
if (!process.env.NEXT_PUBLIC_SUPABASE_URL || !process.env.SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error("Faltan NEXT_PUBLIC_SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY.");
}

const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

async function readAll<T>(
  table: string,
  columns: string,
  companyId: string,
): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0; ; from += pageSize) {
    const { data, error } = await supabase
      .from(table)
      .select(columns)
      .eq("company_id", companyId)
      .range(from, from + pageSize - 1);
    if (error) throw error;
    rows.push(...((data ?? []) as T[]));
    if ((data?.length ?? 0) < pageSize) return rows;
  }
}

type Receivable = {
  customer_id: string;
  due_date: string;
  outstanding_amount: number | string;
};
type Contact = { customer_id: string; phone: string | null; email: string | null };
type Payment = { amount: number | string; received_at: string };

const { data: companies, error: companyError } = await supabase
  .from("companies")
  .select("id,display_name")
  .eq("display_name", companyName);
if (companyError) throw companyError;
if (companies?.length !== 1) throw new Error("La empresa no existe o no es única.");
const company = companies[0];

const [receivables, contacts, payments] = await Promise.all([
  readAll<Receivable>("customer_receivables", "customer_id,due_date,outstanding_amount", company.id),
  readAll<Contact>("customer_contacts", "customer_id,phone,email", company.id),
  readAll<Payment>("receivable_payments", "amount,received_at", company.id),
]);

const open = receivables.filter((row) => Number(row.outstanding_amount) > 0);
const overdue = open.filter((row) => new Date(`${row.due_date}T12:00:00-06:00`) < measuredAt);
const openCustomers = new Set(open.map((row) => row.customer_id));
const overdueCustomers = new Set(overdue.map((row) => row.customer_id));
const contactChannels = new Map<string, { phone: boolean; email: boolean }>();
for (const contact of contacts) {
  const current = contactChannels.get(contact.customer_id) ?? { phone: false, email: false };
  current.phone ||= Boolean(contact.phone?.trim());
  current.email ||= Boolean(contact.email?.trim());
  contactChannels.set(contact.customer_id, current);
}

const aging = { current: 0, days_1_30: 0, days_31_60: 0, days_61_90: 0, days_91_plus: 0 };
for (const row of open) {
  const amount = Number(row.outstanding_amount);
  const days = Math.floor((measuredAt.getTime() - new Date(`${row.due_date}T12:00:00-06:00`).getTime()) / 86_400_000);
  if (days <= 0) aging.current += amount;
  else if (days <= 30) aging.days_1_30 += amount;
  else if (days <= 60) aging.days_31_60 += amount;
  else if (days <= 90) aging.days_61_90 += amount;
  else aging.days_91_plus += amount;
}

const paymentCutoff = new Date(measuredAt);
paymentCutoff.setDate(paymentCutoff.getDate() - 90);
const payments90d = payments.filter((payment) => {
  const receivedAt = new Date(payment.received_at);
  return receivedAt >= paymentCutoff && receivedAt <= measuredAt;
});
const withoutPhone = [...overdueCustomers].filter((id) => !contactChannels.get(id)?.phone).length;
const withoutEmail = [...overdueCustomers].filter((id) => !contactChannels.get(id)?.email).length;
const withoutAnyContact = [...overdueCustomers].filter((id) => {
  const channel = contactChannels.get(id);
  return !channel?.phone && !channel?.email;
}).length;
const proposedPilotCandidates = [...overdueCustomers].map((customerId) => {
  const rows = overdue.filter((row) => row.customer_id === customerId && Math.floor(
    (measuredAt.getTime() - new Date(`${row.due_date}T12:00:00-06:00`).getTime()) / 86_400_000,
  ) > 90);
  return {
    customerId,
    eligible: Boolean(contactChannels.get(customerId)?.phone) && rows.length > 0,
    overdueAmount: rows.reduce((sum, row) => sum + Number(row.outstanding_amount), 0),
    oldestDueDate: rows.map((row) => row.due_date).sort()[0] ?? "",
  };
}).filter((candidate) => candidate.eligible).sort((left, right) =>
  right.overdueAmount - left.overdueAmount
  || left.oldestDueDate.localeCompare(right.oldestDueDate)
  || left.customerId.localeCompare(right.customerId));
const proposedPilot = proposedPilotCandidates.slice(0, 25);

const money = (value: number) => Math.round(value * 100) / 100;
console.log(JSON.stringify({
  company: company.display_name,
  measured_at: "2026-08-12",
  open_customers: openCustomers.size,
  open_documents: open.length,
  open_amount: money(open.reduce((sum, row) => sum + Number(row.outstanding_amount), 0)),
  overdue_customers: overdueCustomers.size,
  overdue_documents: overdue.length,
  overdue_amount: money(overdue.reduce((sum, row) => sum + Number(row.outstanding_amount), 0)),
  oldest_open_due_date: open.map((row) => row.due_date).sort()[0] ?? null,
  aging: Object.fromEntries(Object.entries(aging).map(([key, value]) => [key, money(value)])),
  overdue_without_phone: withoutPhone,
  overdue_without_email: withoutEmail,
  overdue_without_any_contact: withoutAnyContact,
  total_payments: payments.length,
  payments_90d: payments90d.length,
  paid_amount_90d: money(payments90d.reduce((sum, payment) => sum + Number(payment.amount), 0)),
  proposed_pilot: {
    eligible_customers: proposedPilotCandidates.length,
    selected_customers: proposedPilot.length,
    selected_overdue_amount: money(proposedPilot.reduce((sum, customer) => sum + customer.overdueAmount, 0)),
  },
}, null, 2));
