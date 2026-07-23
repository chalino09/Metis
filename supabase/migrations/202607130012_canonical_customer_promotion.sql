-- Future customer promotions write only canonical customer, address and contact entities.

create or replace function public.promote_alpha_customer_migration_chunk(p_batch_id uuid,p_limit integer default 200)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype; v_stage public.alpha_customer_migration_customers%rowtype; v_customer public.customers%rowtype; v_doc record; v_customer_id uuid;
  v_chunk_promoted integer:=0; v_promoted integer:=0; v_blocked integer:=0; v_remaining integer:=0; v_opening_key text; v_status text; v_limit integer:=least(greatest(coalesce(p_limit,200),1),500);
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then raise exception 'No autorizado para importar clientes.'; end if;
  if v_batch.status not in ('ready_to_promote','promoting') then raise exception 'El lote no está listo para importar.'; end if;
  if v_batch.status='ready_to_promote' then update public.alpha_customer_migration_batches set status='promoting' where id=p_batch_id; end if;
  for v_stage in select * from public.alpha_customer_migration_customers where batch_id=p_batch_id and status='reconciled' order by external_code limit v_limit for update loop
    begin
      select * into v_customer from public.customers where company_id=v_batch.company_id and code=v_stage.external_code for update;
      if found then
        if v_customer.alpha_external_code is distinct from v_stage.external_code or v_customer.alpha_source_row_hash is distinct from v_stage.source_row_hash then raise exception 'Existe un cliente con la misma clave que no coincide con la fuente importada.'; end if;
        v_customer_id:=v_customer.id;
      else
        insert into public.customers(company_id,code,display_name,tax_id,credit_enabled,credit_limit,credit_term_days,is_active,created_by,alpha_external_code,alpha_source_row_hash,bank_reference,payment_manager,sales_agent,migration_status)
        values(v_batch.company_id,v_stage.external_code,v_stage.display_name,v_stage.tax_id,lower(coalesce(v_stage.commercial_type,'')) in ('credito','crédito'),coalesce(v_stage.credit_limit,0),coalesce(v_stage.credit_term_days,0),true,auth.uid(),v_stage.external_code,v_stage.source_row_hash,v_stage.bank_reference,v_stage.payment_manager,v_stage.sales_agent,'promoted') returning id into v_customer_id;
        if nullif(trim(coalesce(v_stage.address_line,'')),'') is not null then
          insert into public.customer_addresses(company_id,customer_id,label,address_line,neighborhood,municipality,state_name,postal_code,is_primary)
          values(v_batch.company_id,v_customer_id,'Principal',trim(v_stage.address_line),nullif(trim(v_stage.neighborhood),''),nullif(trim(v_stage.municipality),''),nullif(trim(v_stage.state_name),''),nullif(trim(v_stage.postal_code),''),true);
        end if;
        if nullif(trim(coalesce(v_stage.phone,'')),'') is not null then
          insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,is_primary)
          values(v_batch.company_id,v_customer_id,coalesce(nullif(trim(v_stage.contact_name),''),v_stage.display_name),'Contacto principal',trim(v_stage.phone),true);
        end if;
      end if;
      if v_stage.document_mode='documents' then
        for v_doc in select * from public.alpha_customer_migration_documents where batch_id=p_batch_id and customer_external_code=v_stage.external_code and outstanding_amount>0 order by document_date,folio loop
          if exists(select 1 from public.customer_receivables r where r.company_id=v_batch.company_id and r.source_document_key=v_doc.source_document_key and r.source_row_hash is distinct from v_doc.source_row_hash) then raise exception 'La clave de documento ya existe con una huella distinta.'; end if;
          insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
          values(v_batch.company_id,v_customer_id,null,v_doc.document_date,v_doc.document_date,v_doc.original_amount,v_doc.outstanding_amount,'alpha_document',v_doc.source_document_key,v_doc.source_row_hash,v_doc.folio,v_batch.cutoff_date)
          on conflict(company_id,source_document_key) where source_kind in ('alpha_document','alpha_opening_balance') do nothing;
        end loop;
      elsif v_stage.document_mode='opening_balance' and v_stage.reported_open_amount>0 then
        v_opening_key:=encode(digest(concat_ws('|','alpha_opening_balance',v_stage.external_code,v_batch.cutoff_date::text,v_stage.reported_open_amount::text),'sha256'),'hex');
        insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
        values(v_batch.company_id,v_customer_id,null,v_batch.cutoff_date,v_batch.cutoff_date,v_stage.reported_open_amount,v_stage.reported_open_amount,'alpha_opening_balance',v_opening_key,v_stage.opening_balance_source_hash,v_stage.opening_balance_reference,v_batch.cutoff_date)
        on conflict(company_id,source_document_key) where source_kind in ('alpha_document','alpha_opening_balance') do nothing;
      end if;
      update public.alpha_customer_migration_customers set status='promoted',promoted_customer_id=v_customer_id where id=v_stage.id; v_chunk_promoted:=v_chunk_promoted+1;
    exception when others then
      update public.alpha_customer_migration_customers set status='discrepancy',discrepancy=discrepancy||jsonb_build_array(jsonb_build_object('code','PROMOTION_FAILED','message',sqlerrm,'severity','error')) where id=v_stage.id;
      insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message) values(p_batch_id,v_stage.external_code,'error','PROMOTION_FAILED',sqlerrm);
    end;
  end loop;
  select count(*) filter(where status='promoted'),count(*) filter(where status='discrepancy'),count(*) filter(where status='reconciled') into v_promoted,v_blocked,v_remaining from public.alpha_customer_migration_customers where batch_id=p_batch_id;
  if v_remaining=0 then
    v_status:=case when v_promoted=0 and v_blocked>0 then 'failed' when v_blocked>0 then 'completed_with_discrepancies' else 'completed' end;
    update public.alpha_customer_migration_batches set status=v_status,records_promoted=v_promoted,completed_at=now(),summary=summary||jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked) where id=p_batch_id;
    perform public.write_sales_audit(v_batch.company_id,'customer_migration.promoted','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked));
  else
    v_status:='promoting'; update public.alpha_customer_migration_batches set records_promoted=v_promoted,summary=summary||jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked,'remaining_customers',v_remaining) where id=p_batch_id;
    perform public.write_sales_audit(v_batch.company_id,'customer_migration.promotion_chunk','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('chunk_promoted',v_chunk_promoted,'promoted_customers',v_promoted,'remaining_customers',v_remaining));
  end if;
  return jsonb_build_object('batch_id',p_batch_id,'status',v_status,'chunk_promoted',v_chunk_promoted,'promoted_customers',v_promoted,'blocked_customers',v_blocked,'remaining_customers',v_remaining);
end $$;

revoke execute on function public.promote_alpha_customer_migration(uuid) from authenticated;

create or replace function public.request_alpha_customer_migration_adjustment(p_company_id uuid,p_customer_id uuid,p_receivable_id uuid,p_field_name text,p_proposed_value jsonb,p_reason text,p_evidence text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_customer public.customers%rowtype; v_previous jsonb; v_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'import_data') then raise exception 'No autorizado para solicitar ajustes de migración.'; end if;
  select * into v_customer from public.customers where id=p_customer_id and company_id=p_company_id for update;
  if not found or v_customer.alpha_external_code is null then raise exception 'El ajuste aplica únicamente a clientes promovidos.'; end if;
  if p_field_name not in ('display_name','tax_id','phone','address_line','contact_name','bank_reference','credit_limit','credit_term_days','outstanding_amount') or nullif(trim(coalesce(p_reason,'')),'') is null or nullif(trim(coalesce(p_evidence,'')),'') is null then raise exception 'Solicitud de ajuste incompleta.'; end if;
  if p_field_name='outstanding_amount' then select to_jsonb(outstanding_amount) into v_previous from public.customer_receivables where id=p_receivable_id and customer_id=p_customer_id and company_id=p_company_id and source_kind in ('alpha_document','alpha_opening_balance') for update;
  else v_previous:=case p_field_name when 'display_name' then to_jsonb(v_customer.display_name) when 'tax_id' then to_jsonb(v_customer.tax_id) when 'phone' then (select to_jsonb(phone) from public.customer_contacts where customer_id=p_customer_id and is_primary) when 'address_line' then (select to_jsonb(address_line) from public.customer_addresses where customer_id=p_customer_id and is_primary) when 'contact_name' then (select to_jsonb(display_name) from public.customer_contacts where customer_id=p_customer_id and is_primary) when 'bank_reference' then to_jsonb(v_customer.bank_reference) when 'credit_limit' then to_jsonb(v_customer.credit_limit) when 'credit_term_days' then to_jsonb(v_customer.credit_term_days) end; end if;
  if p_field_name='outstanding_amount' and (v_previous is null or coalesce((p_proposed_value#>>'{}')::numeric,-1)<0) then raise exception 'Saldo propuesto inválido.'; end if;
  insert into public.alpha_customer_migration_adjustments(company_id,customer_id,receivable_id,field_name,previous_value,proposed_value,reason,evidence,requested_by) values(p_company_id,p_customer_id,p_receivable_id,p_field_name,v_previous,p_proposed_value,trim(p_reason),trim(p_evidence),auth.uid()) returning id into v_id;
  update public.customers set migration_status='adjustment_pending' where id=p_customer_id;
  perform public.write_sales_audit(p_company_id,'customer_migration.adjustment_requested','alpha_customer_migration_adjustments',v_id,jsonb_build_object('customer_id',p_customer_id,'field_name',p_field_name)); return v_id;
end $$;

create or replace function public.decide_alpha_customer_migration_adjustment(p_adjustment_id uuid,p_approve boolean,p_decision_reason text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.alpha_customer_migration_adjustments%rowtype; v_customer public.customers%rowtype;
begin
  select * into v from public.alpha_customer_migration_adjustments where id=p_adjustment_id for update;
  if not found or v.status<>'pending' then raise exception 'Ajuste no disponible.'; end if;
  if auth.uid()=v.requested_by or not public.is_super_admin() then raise exception 'La aprobación requiere un super administrador distinto al solicitante.'; end if;
  select * into v_customer from public.customers where id=v.customer_id;
  if p_approve then
    if v.field_name='outstanding_amount' then update public.customer_receivables set outstanding_amount=(v.proposed_value#>>'{}')::numeric where id=v.receivable_id;
    elsif v.field_name='display_name' then update public.customers set display_name=v.proposed_value#>>'{}' where id=v.customer_id;
    elsif v.field_name='tax_id' then update public.customers set tax_id=nullif(v.proposed_value#>>'{}','') where id=v.customer_id;
    elsif v.field_name='phone' then
      if exists(select 1 from public.customer_contacts where customer_id=v.customer_id and is_primary) then update public.customer_contacts set phone=nullif(v.proposed_value#>>'{}','') where customer_id=v.customer_id and is_primary;
      elsif nullif(v.proposed_value#>>'{}','') is not null then insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,is_primary) values(v.company_id,v.customer_id,v_customer.display_name,'Contacto principal',v.proposed_value#>>'{}',true); end if;
    elsif v.field_name='contact_name' then update public.customer_contacts set display_name=v.proposed_value#>>'{}' where customer_id=v.customer_id and is_primary;
    elsif v.field_name='address_line' then
      if exists(select 1 from public.customer_addresses where customer_id=v.customer_id and is_primary) then update public.customer_addresses set address_line=v.proposed_value#>>'{}' where customer_id=v.customer_id and is_primary;
      else insert into public.customer_addresses(company_id,customer_id,label,address_line,is_primary) values(v.company_id,v.customer_id,'Principal',v.proposed_value#>>'{}',true); end if;
    elsif v.field_name='bank_reference' then update public.customers set bank_reference=nullif(v.proposed_value#>>'{}','') where id=v.customer_id;
    elsif v.field_name='credit_limit' then update public.customers set credit_limit=(v.proposed_value#>>'{}')::numeric where id=v.customer_id;
    elsif v.field_name='credit_term_days' then update public.customers set credit_term_days=(v.proposed_value#>>'{}')::integer where id=v.customer_id; end if;
  end if;
  update public.alpha_customer_migration_adjustments set status=case when p_approve then 'approved' else 'rejected' end,decided_by=auth.uid(),decided_at=now(),decision_reason=nullif(trim(p_decision_reason),'') where id=v.id;
  update public.customers set migration_status=case when exists(select 1 from public.alpha_customer_migration_adjustments a where a.customer_id=v.customer_id and a.status='pending' and a.id<>v.id) then 'adjustment_pending' else 'promoted' end where id=v.customer_id;
  perform public.write_sales_audit(v.company_id,'customer_migration.adjustment_'||case when p_approve then 'approved' else 'rejected' end,'alpha_customer_migration_adjustments',v.id,jsonb_build_object('customer_id',v.customer_id,'field_name',v.field_name));
  return jsonb_build_object('adjustment_id',v.id,'status',case when p_approve then 'approved' else 'rejected' end);
end $$;
