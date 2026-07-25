-- Parche posterior a 202607240007: volver a ejecutar sólo si 007 ya fue aplicado.

create or replace function public.save_procurement_quote(p_company_id uuid,p_requisition_id uuid,p_supplier_id uuid,p_currency_code text,p_valid_until date,p_delivery_days integer,p_notes text,p_lines jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_quote uuid;v_line jsonb;v_terms jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_procurement_quotes') then raise exception 'No autorizado para cotizar.'; end if;
  if not exists(select 1 from public.procurement_requisitions where id=p_requisition_id and company_id=p_company_id and status in ('draft','quoting','recommended')) then raise exception 'Necesidad no disponible para cotizar.'; end if;
  if to_regclass('public.supplier_prompt_payment_terms') is not null then execute 'select coalesce(jsonb_agg(jsonb_build_object(''term_days'',term_days,''discount_components'',discount_components) order by tier_number),''[]''::jsonb) from public.supplier_prompt_payment_terms where supplier_id=$1' into v_terms using p_supplier_id; else v_terms:='[]'::jsonb; end if;
  insert into public.procurement_quotes(company_id,requisition_id,supplier_id,currency_code,valid_until,delivery_days,credit_days_snapshot,prompt_payment_terms_snapshot,notes,status)
  select p_company_id,p_requisition_id,s.id,upper(trim(p_currency_code)),p_valid_until,p_delivery_days,s.payable_term_days,coalesce(v_terms,'[]'::jsonb),nullif(trim(p_notes),''),'received' from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id and s.is_active
  on conflict(requisition_id,supplier_id) do update set currency_code=excluded.currency_code,valid_until=excluded.valid_until,delivery_days=excluded.delivery_days,credit_days_snapshot=excluded.credit_days_snapshot,prompt_payment_terms_snapshot=excluded.prompt_payment_terms_snapshot,notes=excluded.notes,status='received',updated_at=now() returning id into v_quote;
  if v_quote is null then raise exception 'Proveedor no disponible.'; end if;
  delete from public.procurement_quote_lines where quote_id=v_quote;
  for v_line in select value from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    insert into public.procurement_quote_lines(company_id,quote_id,requisition_line_id,available_quantity,unit_price,commercial_discount_percent,prompt_payment_discount_percent,financing_terms,expected_date)
    select p_company_id,v_quote,r.id,(v_line->>'available_quantity')::numeric,(v_line->>'unit_price')::numeric,coalesce((v_line->>'commercial_discount_percent')::numeric,0),coalesce((v_line->>'prompt_payment_discount_percent')::numeric,0),nullif(trim(v_line->>'financing_terms'),''),nullif(v_line->>'expected_date','')::date from public.procurement_requisition_lines r where r.id=(v_line->>'requisition_line_id')::uuid and r.requisition_id=p_requisition_id;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'procurement.quote_saved','procurement_quote',v_quote,jsonb_build_object('requisition_id',p_requisition_id,'supplier_id',p_supplier_id));
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;

create or replace function public.approve_procurement_award(p_company_id uuid,p_requisition_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_award public.procurement_awards%rowtype;v_supplier uuid;v_order uuid;v_quote record;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'approve_procurement_awards') then raise exception 'No autorizado para aprobar adjudicación.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La aprobación requiere motivo.'; end if;
  select * into v_award from public.procurement_awards where requisition_id=p_requisition_id and company_id=p_company_id for update;
  if not found or v_award.status<>'recommended' then raise exception 'No hay una recomendación pendiente.'; end if;
  for v_supplier in select distinct q.supplier_id from public.procurement_award_lines al join public.procurement_quote_lines ql on ql.id=al.quote_line_id join public.procurement_quotes q on q.id=ql.quote_id where al.award_id=v_award.id loop
    select q.id,q.currency_code,min(ql.expected_date) expected_date into v_quote from public.procurement_award_lines al join public.procurement_quote_lines ql on ql.id=al.quote_line_id join public.procurement_quotes q on q.id=ql.quote_id where al.award_id=v_award.id and q.supplier_id=v_supplier group by q.id,q.currency_code limit 1;
    insert into public.purchase_orders(company_id,supplier_id,folio,status,currency_code,ordered_date,expected_date,requisition_reference,notes,submitted_at,submitted_by,decided_at,decided_by) values(p_company_id,v_supplier,public.next_purchase_order_folio(p_company_id,false),'draft',v_quote.currency_code,current_date,v_quote.expected_date,(select folio from public.procurement_requisitions where id=p_requisition_id),'Generada desde adjudicación aprobada.',now(),auth.uid(),now(),auth.uid()) returning id into v_order;
    insert into public.purchase_order_lines(company_id,purchase_order_id,line_number,product_id,description,unit,quantity,unit_cost,discount_percent_1,expected_date,requisition_reference)
    select p_company_id,v_order,row_number() over(order by rl.line_number),rl.product_id,rl.description,rl.unit,al.awarded_quantity,ql.unit_price,ql.commercial_discount_percent,ql.expected_date,(select folio from public.procurement_requisitions where id=p_requisition_id) from public.procurement_award_lines al join public.procurement_quote_lines ql on ql.id=al.quote_line_id join public.procurement_quotes q on q.id=ql.quote_id join public.procurement_requisition_lines rl on rl.id=al.requisition_line_id where al.award_id=v_award.id and q.supplier_id=v_supplier;
    perform public.recalculate_purchase_order(v_order); update public.purchase_orders set status='approved',updated_by=auth.uid() where id=v_order;
    insert into public.purchase_order_decisions(company_id,purchase_order_id,decision,reason) values(p_company_id,v_order,'approved','Adjudicación de abastecimiento aprobada: '||trim(p_reason));
    insert into public.procurement_purchase_orders(procurement_award_id,purchase_order_id,company_id) values(v_award.id,v_order,p_company_id);
  end loop;
  update public.procurement_awards set status='approved',decided_by=auth.uid(),decided_at=now(),decided_reason=trim(p_reason) where id=v_award.id;
  update public.procurement_requisitions set status='approved',updated_at=now() where id=p_requisition_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'procurement.award_approved','procurement_award',v_award.id,jsonb_build_object('reason',trim(p_reason)));
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;
