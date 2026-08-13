-- Fase 0 · diagnóstico reproducible de cartera para automatización de cobranza.
-- Solo lectura. Ejecutar contra el entorno que contenga la cartera operativa.
-- La fecha se fija para que la evidencia sea reproducible; actualizarla de forma
-- explícita en una nueva corrida y conservarla junto con sus resultados.

\set as_of_date '2026-08-12'
\set company_name 'Teza Agricultura Sustentable'
\set pilot_size '25'

with receivables as (
  select
    company_id,
    count(*) filter (where outstanding_amount > 0) as open_documents,
    count(distinct customer_id) filter (where outstanding_amount > 0) as open_customers,
    coalesce(sum(outstanding_amount) filter (where outstanding_amount > 0), 0) as open_amount,
    count(*) filter (
      where outstanding_amount > 0 and due_date < date :'as_of_date'
    ) as overdue_documents,
    count(distinct customer_id) filter (
      where outstanding_amount > 0 and due_date < date :'as_of_date'
    ) as overdue_customers,
    coalesce(sum(outstanding_amount) filter (
      where outstanding_amount > 0 and due_date < date :'as_of_date'
    ), 0) as overdue_amount,
    min(due_date) filter (where outstanding_amount > 0) as oldest_due_date
  from public.customer_receivables
  group by company_id
), overdue_debtors as (
  select distinct company_id, customer_id
  from public.customer_receivables
  where outstanding_amount > 0 and due_date < date :'as_of_date'
), contact_quality as (
  select
    debtor.company_id,
    count(*) filter (where not exists (
      select 1
      from public.customer_contacts contact
      where contact.company_id = debtor.company_id
        and contact.customer_id = debtor.customer_id
        and nullif(trim(contact.phone), '') is not null
    )) as overdue_without_phone,
    count(*) filter (where not exists (
      select 1
      from public.customer_contacts contact
      where contact.company_id = debtor.company_id
        and contact.customer_id = debtor.customer_id
        and nullif(trim(contact.email), '') is not null
    )) as overdue_without_email,
    count(*) filter (where not exists (
      select 1
      from public.customer_contacts contact
      where contact.company_id = debtor.company_id
        and contact.customer_id = debtor.customer_id
        and (
          nullif(trim(contact.phone), '') is not null
          or nullif(trim(contact.email), '') is not null
        )
    )) as overdue_without_any_contact
  from overdue_debtors debtor
  group by debtor.company_id
), payment_history as (
  select
    company_id,
    count(*) as total_payments,
    count(*) filter (
      where received_at >= date :'as_of_date' - interval '90 days'
        and received_at < date :'as_of_date' + interval '1 day'
    ) as payments_90d,
    coalesce(sum(amount) filter (
      where received_at >= date :'as_of_date' - interval '90 days'
        and received_at < date :'as_of_date' + interval '1 day'
    ), 0) as paid_amount_90d
  from public.receivable_payments
  group by company_id
)
select
  company.id as company_id,
  company.display_name,
  :'as_of_date'::date as measured_at,
  coalesce(receivables.open_customers, 0) as open_customers,
  coalesce(receivables.open_documents, 0) as open_documents,
  coalesce(receivables.open_amount, 0) as open_amount,
  coalesce(receivables.overdue_customers, 0) as overdue_customers,
  coalesce(receivables.overdue_documents, 0) as overdue_documents,
  coalesce(receivables.overdue_amount, 0) as overdue_amount,
  receivables.oldest_due_date,
  coalesce(contact_quality.overdue_without_phone, 0) as overdue_without_phone,
  coalesce(contact_quality.overdue_without_email, 0) as overdue_without_email,
  coalesce(contact_quality.overdue_without_any_contact, 0) as overdue_without_any_contact,
  coalesce(payment_history.total_payments, 0) as total_payments,
  coalesce(payment_history.payments_90d, 0) as payments_90d,
  coalesce(payment_history.paid_amount_90d, 0) as paid_amount_90d
from public.companies company
left join receivables on receivables.company_id = company.id
left join contact_quality on contact_quality.company_id = company.id
left join payment_history on payment_history.company_id = company.id
order by overdue_amount desc, company.display_name, company.id;

-- Comprobación de capacidades históricas requeridas por la fase. No presupone
-- que una tabla ausente deba crearse antes de acordar el proceso de negocio.
select
  to_regclass('public.receivable_payments') is not null as payment_history_available,
  to_regclass('public.collection_promises') is not null as collection_promises_available;

-- Población propuesta del piloto: clientes con deuda de más de 90 días y al
-- menos un teléfono canónico. El tamaño es un parámetro aprobado, no una
-- constante de producto. La consulta devuelve clientes, nunca documentos como
-- unidad operativa, y no modifica ni reserva registros.
with target_company as (
  select id
  from public.companies
  where display_name = :'company_name'
), eligible as (
  select
    receivable.company_id,
    receivable.customer_id,
    sum(receivable.outstanding_amount) as overdue_amount,
    min(receivable.due_date) as oldest_due_date,
    count(*) as overdue_documents
  from public.customer_receivables receivable
  join target_company company on company.id = receivable.company_id
  where receivable.outstanding_amount > 0
    and receivable.due_date < date :'as_of_date' - interval '90 days'
    and exists (
      select 1
      from public.customer_contacts contact
      where contact.company_id = receivable.company_id
        and contact.customer_id = receivable.customer_id
        and nullif(trim(contact.phone), '') is not null
    )
  group by receivable.company_id, receivable.customer_id
)
select company_id, customer_id, overdue_amount, oldest_due_date, overdue_documents
from eligible
order by overdue_amount desc, oldest_due_date, customer_id
limit :'pilot_size'::integer;
