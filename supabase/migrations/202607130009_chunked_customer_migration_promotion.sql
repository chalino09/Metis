-- Promote large Clientes/CxC migrations in bounded, resumable transactions.

create or replace function public.promote_alpha_customer_migration_chunk(p_batch_id uuid, p_limit integer default 200)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype;
  v_stage public.alpha_customer_migration_customers%rowtype;
  v_customer public.customers%rowtype;
  v_doc record;
  v_customer_id uuid;
  v_chunk_promoted integer := 0;
  v_promoted integer := 0;
  v_blocked integer := 0;
  v_remaining integer := 0;
  v_opening_key text;
  v_status text;
  v_limit integer := least(greatest(coalesce(p_limit,200),1),500);
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para importar clientes.';
  end if;
  if v_batch.status not in ('ready_to_promote','promoting') then
    raise exception 'El lote no está listo para importar.';
  end if;
  if v_batch.status='ready_to_promote' then
    update public.alpha_customer_migration_batches set status='promoting' where id=p_batch_id;
  end if;

  for v_stage in
    select * from public.alpha_customer_migration_customers
    where batch_id=p_batch_id and status='reconciled'
    order by external_code
    limit v_limit
    for update
  loop
    begin
      select * into v_customer from public.customers where company_id=v_batch.company_id and code=v_stage.external_code for update;
      if found then
        if v_customer.alpha_external_code is distinct from v_stage.external_code or v_customer.alpha_source_row_hash is distinct from v_stage.source_row_hash then
          raise exception 'Existe un cliente con la misma clave que no coincide con la fuente Alpha.';
        end if;
        v_customer_id := v_customer.id;
      else
        insert into public.customers(company_id,code,display_name,tax_id,phone,credit_enabled,credit_limit,credit_term_days,is_active,created_by,alpha_external_code,alpha_source_row_hash,address_line,neighborhood,municipality,state_name,postal_code,contact_name,bank_reference,payment_manager,sales_agent,migration_status)
        values(v_batch.company_id,v_stage.external_code,v_stage.display_name,v_stage.tax_id,v_stage.phone,lower(coalesce(v_stage.commercial_type,'')) in ('credito','crédito'),coalesce(v_stage.credit_limit,0),coalesce(v_stage.credit_term_days,0),true,auth.uid(),v_stage.external_code,v_stage.source_row_hash,v_stage.address_line,v_stage.neighborhood,v_stage.municipality,v_stage.state_name,v_stage.postal_code,v_stage.contact_name,v_stage.bank_reference,v_stage.payment_manager,v_stage.sales_agent,'promoted')
        returning id into v_customer_id;
      end if;

      if v_stage.document_mode='documents' then
        for v_doc in select * from public.alpha_customer_migration_documents where batch_id=p_batch_id and customer_external_code=v_stage.external_code and outstanding_amount > 0 order by document_date,folio loop
          if exists (select 1 from public.customer_receivables r where r.company_id=v_batch.company_id and r.source_document_key=v_doc.source_document_key and r.source_row_hash is distinct from v_doc.source_row_hash) then
            raise exception 'La clave de documento ya existe con una huella distinta.';
          end if;
          insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
          values(v_batch.company_id,v_customer_id,null,v_doc.document_date,v_doc.document_date,v_doc.original_amount,v_doc.outstanding_amount,'alpha_document',v_doc.source_document_key,v_doc.source_row_hash,v_doc.folio,v_batch.cutoff_date)
          on conflict (company_id,source_document_key) where source_kind in ('alpha_document','alpha_opening_balance') do nothing;
        end loop;
      elsif v_stage.document_mode='opening_balance' and v_stage.reported_open_amount > 0 then
        v_opening_key := encode(digest(concat_ws('|','alpha_opening_balance',v_stage.external_code,v_batch.cutoff_date::text,v_stage.reported_open_amount::text),'sha256'),'hex');
        insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
        values(v_batch.company_id,v_customer_id,null,v_batch.cutoff_date,v_batch.cutoff_date,v_stage.reported_open_amount,v_stage.reported_open_amount,'alpha_opening_balance',v_opening_key,v_stage.opening_balance_source_hash,v_stage.opening_balance_reference,v_batch.cutoff_date)
        on conflict (company_id,source_document_key) where source_kind in ('alpha_document','alpha_opening_balance') do nothing;
      end if;
      update public.alpha_customer_migration_customers set status='promoted',promoted_customer_id=v_customer_id where id=v_stage.id;
      v_chunk_promoted := v_chunk_promoted + 1;
    exception when others then
      update public.alpha_customer_migration_customers set status='discrepancy',discrepancy=discrepancy || jsonb_build_array(jsonb_build_object('code','PROMOTION_FAILED','message',sqlerrm,'severity','error')) where id=v_stage.id;
      insert into public.alpha_customer_migration_differences(batch_id,customer_external_code,severity,difference_code,message) values(p_batch_id,v_stage.external_code,'error','PROMOTION_FAILED',sqlerrm);
    end;
  end loop;

  select count(*) filter(where status='promoted'), count(*) filter(where status='discrepancy'), count(*) filter(where status='reconciled')
    into v_promoted,v_blocked,v_remaining
  from public.alpha_customer_migration_customers where batch_id=p_batch_id;

  if v_remaining=0 then
    v_status := case when v_promoted=0 and v_blocked>0 then 'failed' when v_blocked>0 then 'completed_with_discrepancies' else 'completed' end;
    update public.alpha_customer_migration_batches
      set status=v_status,records_promoted=v_promoted,completed_at=now(),summary=summary || jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked)
      where id=p_batch_id;
    perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.promoted','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked));
  else
    v_status := 'promoting';
    update public.alpha_customer_migration_batches set records_promoted=v_promoted,summary=summary || jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked,'remaining_customers',v_remaining) where id=p_batch_id;
    perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.promotion_chunk','alpha_customer_migration_batches',p_batch_id,jsonb_build_object('chunk_promoted',v_chunk_promoted,'promoted_customers',v_promoted,'remaining_customers',v_remaining));
  end if;

  return jsonb_build_object('batch_id',p_batch_id,'status',v_status,'chunk_promoted',v_chunk_promoted,'promoted_customers',v_promoted,'blocked_customers',v_blocked,'remaining_customers',v_remaining);
end $$;

revoke all on function public.promote_alpha_customer_migration_chunk(uuid,integer) from public;
grant execute on function public.promote_alpha_customer_migration_chunk(uuid,integer) to authenticated;
