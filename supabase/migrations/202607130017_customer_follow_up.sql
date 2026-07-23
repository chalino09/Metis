-- Consultas canónicas posteriores: recibos de CxC y ajustes auditados de clientes importados.

create or replace function public.list_customer_receivable_receipts(p_company_id uuid,p_customer_id uuid,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1); v_size integer:=least(greatest(coalesce(p_page_size,25),1),100); v_total integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para consultar recibos.'; end if;
  if not exists(select 1 from public.customers where id=p_customer_id and company_id=p_company_id) then raise exception 'Cliente no encontrado.'; end if;
  select count(*) into v_total from public.canonical_receivable_receipts r join public.receivable_payments p on p.id=r.receivable_payment_id where r.company_id=p_company_id and p.customer_id=p_customer_id;
  return jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'folio',r.folio,'issued_at',r.issued_at,'amount',r.payload->'amount','currency_code',r.payload->'currency_code','payment_method',r.payload->'payment_method','payment_reference',r.payload->'payment_reference') order by r.issued_at desc,r.id desc) from (select r.* from public.canonical_receivable_receipts r join public.receivable_payments p on p.id=r.receivable_payment_id where r.company_id=p_company_id and p.customer_id=p_customer_id order by r.issued_at desc,r.id desc offset (v_page-1)*v_size limit v_size) r),'[]'::jsonb),'total',v_total,'page',v_page,'page_size',v_size);
end $$;

create or replace function public.get_customer_receivable_receipt(p_company_id uuid,p_receipt_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_payload jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then raise exception 'No autorizado para consultar recibos.'; end if;
  select r.payload into v_payload from public.canonical_receivable_receipts r where r.company_id=p_company_id and r.id=p_receipt_id;
  if v_payload is null then raise exception 'Recibo no encontrado.'; end if;
  return v_payload;
end $$;

create or replace function public.list_customer_migration_adjustments(p_company_id uuid,p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_can_decide boolean:=public.is_super_admin();
begin
  if auth.uid() is null or (not public.has_company_permission(p_company_id,'import_data') and not v_can_decide) then raise exception 'No autorizado para consultar ajustes auditados.'; end if;
  if not exists(select 1 from public.customers where id=p_customer_id and company_id=p_company_id and alpha_external_code is not null) then raise exception 'Cliente protegido no encontrado.'; end if;
  return jsonb_build_object('can_decide',v_can_decide,'items',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'field_name',a.field_name,'previous_value',a.previous_value,'proposed_value',a.proposed_value,'reason',a.reason,'evidence',a.evidence,'status',a.status,'created_at',a.created_at,'requested_by',a.requested_by,'decided_at',a.decided_at,'decision_reason',a.decision_reason) order by a.created_at desc) from public.alpha_customer_migration_adjustments a where a.company_id=p_company_id and a.customer_id=p_customer_id and (v_can_decide or a.requested_by=auth.uid())),'[]'::jsonb));
end $$;

revoke all on function public.list_customer_receivable_receipts(uuid,uuid,integer,integer),public.get_customer_receivable_receipt(uuid,uuid),public.list_customer_migration_adjustments(uuid,uuid) from public;
grant execute on function public.list_customer_receivable_receipts(uuid,uuid,integer,integer),public.get_customer_receivable_receipt(uuid,uuid),public.list_customer_migration_adjustments(uuid,uuid) to authenticated;
