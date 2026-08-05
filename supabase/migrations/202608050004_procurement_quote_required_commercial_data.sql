-- Una cotización que puede convertirse en orden debe contener una oferta comercial utilizable.

create or replace function public.save_procurement_quote(
  p_company_id uuid,p_requisition_id uuid,p_supplier_id uuid,p_currency_code text,p_valid_until date,p_delivery_days integer,
  p_prompt_payment_discount_percent numeric,p_prompt_payment_term_days integer,p_notes text,p_lines jsonb
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_quote uuid;v_line jsonb;v_terms jsonb;v_discount numeric:=coalesce(p_prompt_payment_discount_percent,0);v_expected integer;v_received integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_procurement_quotes') then raise exception 'No autorizado para cotizar.'; end if;
  if not exists(select 1 from public.procurement_requisitions where id=p_requisition_id and company_id=p_company_id and status in ('draft','quoting','recommended')) then raise exception 'Necesidad no disponible para cotizar.'; end if;
  if p_valid_until is null then raise exception 'Indica la vigencia de la cotización.'; end if;
  if v_discount<0 or v_discount>100 then raise exception 'El descuento por pronto pago debe estar entre 0 y 100.'; end if;
  if v_discount>0 and p_prompt_payment_term_days is null then raise exception 'Indica los días para aplicar el descuento por pronto pago.'; end if;
  if p_prompt_payment_term_days is not null and p_prompt_payment_term_days<0 then raise exception 'Los días de pronto pago no pueden ser negativos.'; end if;
  if jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'Agrega las partidas cotizadas.'; end if;
  select count(*) into v_expected from public.procurement_requisition_lines where requisition_id=p_requisition_id;
  select count(*) into v_received from jsonb_to_recordset(p_lines) line(requisition_line_id uuid,available_quantity numeric,unit_price numeric,expected_date date);
  if v_received<>v_expected then raise exception 'Cotiza cada partida de la solicitud.'; end if;
  if exists(
    select 1 from jsonb_to_recordset(p_lines) line(requisition_line_id uuid,available_quantity numeric,unit_price numeric,expected_date date)
    left join public.procurement_requisition_lines requisition_line on requisition_line.id=line.requisition_line_id and requisition_line.requisition_id=p_requisition_id
    where requisition_line.id is null or line.available_quantity is null or line.available_quantity<=0 or line.unit_price is null or line.unit_price<=0 or line.expected_date is null
  ) then raise exception 'Cada partida requiere disponibilidad, precio y fecha estimada válidos.'; end if;
  if (select count(distinct line.requisition_line_id) from jsonb_to_recordset(p_lines) line(requisition_line_id uuid,available_quantity numeric,unit_price numeric,expected_date date))<>v_received then raise exception 'No repitas partidas en la cotización.'; end if;
  if to_regclass('public.supplier_prompt_payment_terms') is not null then execute 'select coalesce(jsonb_agg(jsonb_build_object(''term_days'',term_days,''discount_components'',discount_components) order by tier_number),''[]''::jsonb) from public.supplier_prompt_payment_terms where supplier_id=$1' into v_terms using p_supplier_id; else v_terms:='[]'::jsonb; end if;
  insert into public.procurement_quotes(company_id,requisition_id,supplier_id,currency_code,valid_until,delivery_days,credit_days_snapshot,prompt_payment_terms_snapshot,prompt_payment_discount_percent,prompt_payment_term_days,notes,status)
  select p_company_id,p_requisition_id,s.id,upper(trim(p_currency_code)),p_valid_until,p_delivery_days,s.payable_term_days,coalesce(v_terms,'[]'::jsonb),v_discount,p_prompt_payment_term_days,nullif(trim(p_notes),''),'received' from public.suppliers s where s.id=p_supplier_id and s.company_id=p_company_id and s.is_active
  on conflict(requisition_id,supplier_id) do update set currency_code=excluded.currency_code,valid_until=excluded.valid_until,delivery_days=excluded.delivery_days,credit_days_snapshot=excluded.credit_days_snapshot,prompt_payment_terms_snapshot=excluded.prompt_payment_terms_snapshot,prompt_payment_discount_percent=excluded.prompt_payment_discount_percent,prompt_payment_term_days=excluded.prompt_payment_term_days,notes=excluded.notes,status='received',updated_at=now()
  returning id into v_quote;
  if v_quote is null then raise exception 'Proveedor no disponible.'; end if;
  delete from public.procurement_quote_lines where quote_id=v_quote;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    insert into public.procurement_quote_lines(company_id,quote_id,requisition_line_id,available_quantity,unit_price,commercial_discount_percent,financing_terms,expected_date)
    select p_company_id,v_quote,requisition_line.id,(v_line->>'available_quantity')::numeric,(v_line->>'unit_price')::numeric,coalesce((v_line->>'commercial_discount_percent')::numeric,0),nullif(trim(v_line->>'financing_terms'),''),(v_line->>'expected_date')::date from public.procurement_requisition_lines requisition_line where requisition_line.id=(v_line->>'requisition_line_id')::uuid and requisition_line.requisition_id=p_requisition_id;
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'procurement.quote_saved','procurement_quote',v_quote,jsonb_build_object('requisition_id',p_requisition_id,'supplier_id',p_supplier_id,'prompt_payment_discount_percent',v_discount,'prompt_payment_term_days',p_prompt_payment_term_days));
  return public.get_procurement_requisition(p_company_id,p_requisition_id);
end $$;
