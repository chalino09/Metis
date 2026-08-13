create or replace function public.collection_get_case(p_company_id uuid,p_case_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_case public.collection_cases%rowtype;
  v_customer public.customers%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collection_automation') then
    raise exception 'No autorizado para consultar cobranza.';
  end if;
  select * into v_case from public.collection_cases where id=p_case_id and company_id=p_company_id;
  if not found then raise exception 'Caso no encontrado.';end if;
  select * into v_customer from public.customers where id=v_case.customer_id;
  return jsonb_build_object(
    'case',to_jsonb(v_case),
    'customer',jsonb_build_object('id',v_customer.id,'code',v_customer.code,'display_name',v_customer.display_name),
    'contact',coalesce((select to_jsonb(c)-'company_id'-'customer_id'-'created_by' from public.customer_contacts c where c.company_id=p_company_id and c.customer_id=v_case.customer_id order by c.is_primary desc,c.created_at limit 1),'null'),
    'documents',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'reference',coalesce(r.source_reference,t.folio),'issued_at',r.issued_at,'due_date',r.due_date,'original_amount',r.original_amount,'outstanding_amount',r.outstanding_amount) order by r.due_date,r.issued_at,r.id) from public.customer_receivables r left join public.canonical_tickets t on t.sale_id=r.sale_id where r.company_id=p_company_id and r.customer_id=v_case.customer_id and r.outstanding_amount>0),'[]'),
    'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'amount',p.amount,'received_at',p.received_at,'payment_method_code',p.payment_method_code) order by p.received_at desc) from public.receivable_payments p where p.company_id=p_company_id and p.customer_id=v_case.customer_id),'[]'),
    'promises',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.collection_promises p where p.case_id=v_case.id),'[]'),
    'blocks',coalesce((select jsonb_agg(to_jsonb(b) order by b.created_at desc) from public.collection_blocks b where b.case_id=v_case.id),'[]'),
    'timeline',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'type',a.action_type,'reason',a.reason,'created_at',a.created_at,'result',a.result) order by a.created_at desc) from public.collection_actions a where a.case_id=v_case.id),'[]')
  );
end $$;

revoke all on function public.collection_get_case(uuid,uuid) from public,anon,authenticated;
grant execute on function public.collection_get_case(uuid,uuid) to authenticated;
