-- Satrapy · M3E4: agenda operativa de pagos.
-- Lectura paginada de las CxP canónicas. No crea estados, no modifica saldos y
-- sólo enlaza propuestas/pagos que el actor ya puede consultar.

create or replace function public.search_supplier_payment_calendar(
  p_company_id uuid,
  p_query text default null,
  p_supplier_id uuid default null,
  p_currency_code text default null,
  p_due_from date default null,
  p_due_to date default null,
  p_page integer default 1,
  p_page_size integer default 25
) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_result jsonb;
  v_can_proposals boolean;
  v_can_payments boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') then
    raise exception 'No autorizado para consultar la agenda de pagos.';
  end if;
  if p_due_from is null or p_due_to is null or p_due_from>p_due_to or p_due_to-p_due_from>366 then
    raise exception 'La agenda requiere un rango válido de hasta 366 días.';
  end if;

  v_can_proposals:=public.has_company_permission(p_company_id,'prepare_supplier_payment_proposals')
    or public.has_company_permission(p_company_id,'approve_supplier_payment_proposals');
  v_can_payments:=public.has_company_permission(p_company_id,'view_supplier_payments');

  with calendar_base as materialized (
    select
      ap.id,ap.supplier_id,s.code supplier_code,s.display_name supplier_name,ap.supplier_invoice_id,
      concat_ws('-',si.series,si.folio) invoice_number,ap.currency_code,ap.original_amount,ap.outstanding_amount,
      ap.issued_date,ap.due_date,
      case
        when proposal.proposal_id is not null or payment.payment_id is not null then 'scheduled'
        when ap.due_date<current_date then 'overdue'
        when ap.due_date=current_date then 'due_today'
        when ap.due_date<=current_date+15 then 'upcoming'
        else 'future'
      end state,
      proposal.proposal_id,proposal.proposal_status,payment.payment_id,payment.payment_reference
    from public.accounts_payable ap
    join public.supplier_invoices si on si.id=ap.supplier_invoice_id
    join public.suppliers s on s.id=ap.supplier_id
    left join lateral (
      select pp.id proposal_id,pp.status proposal_status
      from public.supplier_payment_proposal_lines pl
      join public.supplier_payment_proposals pp on pp.id=pl.proposal_id
      where v_can_proposals and pl.company_id=p_company_id and pl.accounts_payable_id=ap.id
        and pp.status in ('draft','submitted','approved')
      order by case pp.status when 'approved' then 1 when 'submitted' then 2 else 3 end,pp.updated_at desc,pp.id desc
      limit 1
    ) proposal on true
    left join lateral (
      select p.id payment_id,p.reference payment_reference
      from public.supplier_payment_applications pa
      join public.supplier_payments p on p.id=pa.payment_id
      where v_can_payments and pa.company_id=p_company_id and pa.accounts_payable_id=ap.id and p.status='confirmed'
      order by p.effective_date desc,p.confirmed_at desc,p.id desc
      limit 1
    ) payment on true
    where ap.company_id=p_company_id and ap.reversed_at is null
      and ap.due_date between p_due_from and p_due_to
      and (ap.outstanding_amount>0 or payment.payment_id is not null)
      and (p_supplier_id is null or ap.supplier_id=p_supplier_id)
      and (p_currency_code is null or ap.currency_code=upper(trim(p_currency_code)))
      and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%'
        or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%')
  ), paged as (
    select * from calendar_base order by due_date,supplier_name,invoice_number,id
    limit v_size offset (v_page-1)*v_size
  ), day_totals as (
    select due_date,currency_code,count(*) document_count,round(sum(outstanding_amount),6) outstanding_amount
    from calendar_base group by due_date,currency_code
  )
  select jsonb_build_object(
    'items',(select coalesce(jsonb_agg(to_jsonb(p) order by p.due_date,p.supplier_name,p.invoice_number,p.id),'[]'::jsonb) from paged p),
    'totals',(select coalesce(jsonb_agg(to_jsonb(t) order by t.due_date,t.currency_code),'[]'::jsonb) from day_totals t),
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',(select count(*) from calendar_base)),
    'range',jsonb_build_object('from',p_due_from,'to',p_due_to)
  ) into v_result;
  return v_result;
end $$;

revoke all on function public.search_supplier_payment_calendar(uuid,text,uuid,text,date,date,integer,integer) from public;
grant execute on function public.search_supplier_payment_calendar(uuid,text,uuid,text,date,date,integer,integer) to authenticated;
