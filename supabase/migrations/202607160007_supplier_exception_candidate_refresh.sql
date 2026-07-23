-- Reparación derivada de la auditoría 3B: una excepción de proveedor debe poder
-- vincularse a un candidato canónico creado al resolver otra fila del mismo lote.

create or replace function public.list_supplier_import_exceptions(p_company_id uuid,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_total int;v_items jsonb;
begin
 if auth.uid() is null or not public.has_company_permission(p_company_id,'promote_suppliers') then raise exception 'No autorizado para revisar excepciones.';end if;
 select count(*) into v_total from public.supplier_import_exceptions where company_id=p_company_id and status='pending';
 select coalesce(jsonb_agg(to_jsonb(x) order by x.detected_at,x.id),'[]'::jsonb) into v_items from(
   select e.id,e.batch_id,e.conflict_kinds,e.candidate_supplier_ids,e.detected_at,s.external_code,s.display_name,s.tax_id,s.source_row_number,
     coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'code',c.code,'display_name',c.display_name,'tax_id',c.tax_id) order by c.display_name,c.id)
       from public.suppliers c where c.company_id=e.company_id and (c.id=any(e.candidate_supplier_ids)
         or (public.canonical_supplier_tax_id(s.tax_id) is not null and c.tax_id=public.canonical_supplier_tax_id(s.tax_id))
         or public.normalize_supplier_identity(c.display_name)=public.normalize_supplier_identity(s.display_name))),'[]'::jsonb) candidates
   from public.supplier_import_exceptions e join public.alpha_purchasing_import_suppliers s on s.id=e.staged_supplier_id
   where e.company_id=p_company_id and e.status='pending' order by e.detected_at,e.id limit v_size offset(v_page-1)*v_size
 )x;
 return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.resolve_supplier_import_exception(p_exception_id uuid,p_decision text,p_target_supplier_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_e public.supplier_import_exceptions%rowtype;v_s public.alpha_purchasing_import_suppliers%rowtype;v_supplier uuid;v_tax text;v_summary jsonb;
begin
 select * into v_e from public.supplier_import_exceptions where id=p_exception_id for update;
 if not found or auth.uid() is null or not public.has_company_permission(v_e.company_id,'promote_suppliers') then raise exception 'No autorizado para resolver la excepción.';end if;
 if v_e.status='resolved' then return jsonb_build_object('status','already_resolved','supplier_id',v_e.resolved_supplier_id);end if;
 if p_decision not in('link_existing','create_separate') or nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Decisión y motivo son obligatorios.';end if;
 select * into v_s from public.alpha_purchasing_import_suppliers where id=v_e.staged_supplier_id for update;
 if p_decision='link_existing' then
   select id into v_supplier from public.suppliers c where c.id=p_target_supplier_id and c.company_id=v_e.company_id and (
     c.id=any(v_e.candidate_supplier_ids) or
     (public.canonical_supplier_tax_id(v_s.tax_id) is not null and c.tax_id=public.canonical_supplier_tax_id(v_s.tax_id)) or
     public.normalize_supplier_identity(c.display_name)=public.normalize_supplier_identity(v_s.display_name));
   if not found then raise exception 'Selecciona un candidato verificable por RFC o identidad dentro de la misma empresa.';end if;
 else
   v_tax:=public.canonical_supplier_tax_id(v_s.tax_id);
   if v_tax is not null and exists(select 1 from public.suppliers where company_id=v_e.company_id and tax_id=v_tax) then raise exception 'Ya existe un proveedor canónico con el mismo RFC; vincúlalo en lugar de duplicarlo.';end if;
   insert into public.suppliers(company_id,code,display_name,legal_name,tax_id,supplier_category,address_line,neighborhood,municipality,state_name,phone)
   values(v_e.company_id,'SUP-'||upper(substr(gen_random_uuid()::text,1,8)),v_s.display_name,v_s.display_name,v_tax,v_s.supplier_type,v_s.address_line,v_s.neighborhood,v_s.municipality,v_s.state_name,v_s.phone) returning id into v_supplier;
 end if;
 insert into public.supplier_external_references(company_id,supplier_id,source_system,external_code,source_row_hash,metadata)
 values(v_e.company_id,v_supplier,'alpha',v_s.external_code,v_s.source_row_hash,jsonb_build_object('resolution',p_decision,'reason',trim(p_reason)));
 update public.alpha_purchasing_import_suppliers set promoted_supplier_id=v_supplier where id=v_s.id;
 update public.supplier_import_exceptions set status='resolved',decision=p_decision,resolved_supplier_id=v_supplier,resolution_reason=trim(p_reason),resolved_at=now(),resolved_by=auth.uid() where id=p_exception_id;
 v_summary:=jsonb_build_object('source_suppliers',(select count(*) from public.alpha_purchasing_import_suppliers where batch_id=v_e.batch_id),'promoted',(select count(*) from public.alpha_purchasing_import_suppliers where batch_id=v_e.batch_id and promoted_supplier_id is not null),'pending_exceptions',(select count(*) from public.supplier_import_exceptions where batch_id=v_e.batch_id and status='pending'),'purchase_orders_created',0,'payables_created',0,'payments_created',0);
 update public.alpha_purchasing_import_batches set supplier_promotion_summary=v_summary where id=v_e.batch_id;
 insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(v_e.company_id,auth.uid(),'alpha_suppliers.exception_resolved','supplier_import_exception',p_exception_id,jsonb_build_object('decision',p_decision,'supplier_id',v_supplier,'reason',trim(p_reason),'batch_id',v_e.batch_id,'candidate_revalidated_at_resolution',true));
 return jsonb_build_object('status','resolved','supplier_id',v_supplier,'summary',v_summary);
end $$;

revoke all on function public.list_supplier_import_exceptions(uuid,integer,integer),public.resolve_supplier_import_exception(uuid,text,uuid,text) from public;
grant execute on function public.list_supplier_import_exceptions(uuid,integer,integer),public.resolve_supplier_import_exception(uuid,text,uuid,text) to authenticated;
