-- El pronto pago es una condición comercial del proveedor/cotización, no de cada partida.

alter table public.procurement_quotes
  add column if not exists prompt_payment_discount_percent numeric(9,4) not null default 0 check(prompt_payment_discount_percent between 0 and 100),
  add column if not exists prompt_payment_term_days integer check(prompt_payment_term_days is null or prompt_payment_term_days>=0);

update public.procurement_quotes quote
set prompt_payment_discount_percent=coalesce((
  select case when min(line.prompt_payment_discount_percent)=max(line.prompt_payment_discount_percent)
    then max(line.prompt_payment_discount_percent) else 0 end
  from public.procurement_quote_lines line
  where line.quote_id=quote.id
),0);

drop function if exists public.save_procurement_quote(uuid,uuid,uuid,text,date,integer,text,jsonb);

create function public.save_procurement_quote(
  p_company_id uuid,p_requisition_id uuid,p_supplier_id uuid,p_currency_code text,p_valid_until date,p_delivery_days integer,
  p_prompt_payment_discount_percent numeric,p_prompt_payment_term_days integer,p_notes text,p_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_quote uuid;v_line jsonb;v_terms jsonb;v_discount numeric:=coalesce(p_prompt_payment_discount_percent,0);
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_procurement_quotes') then raise exception 'No autorizado para cotizar.'; end if;
  if not exists(select 1 from public.procurement_requisitions where id=p_requisition_id and company_id=p_company_id and status in ('draft','quoting','recommended')) then raise exception 'Necesidad no disponible para cotizar.'; end if;
  if v_discount<0 or v_discount>100 then raise exception 'El descuento por pronto pago debe estar entre 0 y 100.'; end if;
  if v_discount>0 and p_prompt_payment_term_days is null then raise exception 'Indica los días para aplicar el descuento por pronto pago.'; end if;
  if p_prompt_payment_term_days is not null and p_prompt_payment_term_days<0 then raise exception 'Los días de pronto pago no pueden ser negativos.'; end if;
  if to_regclass('public.supplier_prompt_payment_terms') is not null then execute 'select coalesce(jsonb_agg(jsonb_build_object(''term_days'',term_days,''discount_components'',discount_components) order by tier_number),''[]''::jsonb) from public.supplier_prompt_payment_terms where supplier_id=$1' into v_terms using p_supplier_id; else v_terms:='[]'::jsonb; end if;
  insert into public.procurement_quotes(company_id,requisition_id,supplier_id,currency_code,valid_until,delivery_days,credit_days_snapshot,prompt_payment_terms_snapshot,prompt_payment_discount_percent,prompt_payment_term_days,notes,status)
  select p_company_id,p_requisition_id,s.id,upper(trim(p_currency_code)),p_valid_until,p_delivery_days,s.payable_term_days,coalesce(v_terms,'[]'::jsonb),v_discount,p_prompt_payment_term_days,nullif(trim(p_notes),''),'received' from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id and s.is_active
  on conflict(requisition_id,supplier_id) do update set currency_code=excluded.currency_code,valid_until=excluded.valid_until,delivery_days=excluded.delivery_days,credit_days_snapshot=excluded.credit_days_snapshot,prompt_payment_terms_snapshot=excluded.prompt_payment_terms_snapshot,prompt_payment_discount_percent=excluded.prompt_payment_discount_percent,prompt_payment_term_days=excluded.prompt_payment_term_days,notes=excluded.notes,status='received',updated_at=now()
  returning id into v_quote;
  if v_quote is null then raise exception 'Proveedor no disponible.'; end if;
  delete from public.procurement_quote_lines where quote_id=v_quote;
  for v_line in select value from jsonb_array_elements(coalesce(p_lines,'[]'::jsonb)) loop
    insert into public.procurement_quote_lines(company_id,quote_id,requisition_line_id,available_quantity,unit_price,commercial_discount_percent,financing_terms,expected_date)
    select p_company_id,v_quote,r.id,(v_line->>'available_quantity')::numeric,(v_line->>'unit_price')::numeric,coalesce((v_line->>'commercial_discount_percent')::numeric,0),nullif(trim(v_line->>'financing_terms'),''),nullif(v_line->>'expected_date','')::date from public.procurement_requisition_lines r where r.id=(v_line->>'requisition_line_id')::uuid and r.requisition_id=p_requisition_id;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'procurement.quote_saved','procurement_quote',v_quote,jsonb_build_object('requisition_id',p_requisition_id,'supplier_id',p_supplier_id,'prompt_payment_discount_percent',v_discount,'prompt_payment_term_days',p_prompt_payment_term_days));
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;

revoke all on function public.save_procurement_quote(uuid,uuid,uuid,text,date,integer,numeric,integer,text,jsonb) from public,anon;
grant execute on function public.save_procurement_quote(uuid,uuid,uuid,text,date,integer,numeric,integer,text,jsonb) to authenticated;
