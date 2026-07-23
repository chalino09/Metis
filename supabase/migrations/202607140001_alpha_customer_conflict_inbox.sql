-- Bandeja de conflictos de identidad de clientes Alpha.
-- No modifica ni reemplaza promoción, RFC genérico ni CxC existentes.
-- El RFC genérico ya se canoniza automáticamente por 202607130025 y por eso
-- no aparece aquí como una decisión manual.

begin;

create table if not exists public.alpha_customer_identity_links (
  company_id uuid not null references public.companies(id) on delete cascade,
  external_code text not null,
  customer_id uuid not null references public.customers(id) on delete restrict,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (company_id, external_code)
);

create table if not exists public.alpha_customer_migration_identity_decisions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  batch_id uuid not null references public.alpha_customer_migration_batches(id) on delete cascade,
  customer_external_code text not null,
  decision text not null check (decision in ('link_existing','create_cash_without_rfc','leave_pending')),
  target_customer_id uuid references public.customers(id) on delete restrict,
  reason text not null check (length(trim(reason)) > 0),
  evidence jsonb not null default '{}'::jsonb,
  decided_by uuid not null references auth.users(id) on delete restrict,
  decided_at timestamptz not null default now()
);

create unique index if not exists alpha_customer_identity_decisions_idempotency_key
  on public.alpha_customer_migration_identity_decisions (
    batch_id, customer_external_code, decision,
    coalesce(target_customer_id, '00000000-0000-0000-0000-000000000000'::uuid), reason
  );
create index if not exists alpha_customer_identity_decisions_batch_idx
  on public.alpha_customer_migration_identity_decisions(batch_id, customer_external_code, decided_at desc);

alter table public.alpha_customer_identity_links enable row level security;
alter table public.alpha_customer_migration_identity_decisions enable row level security;

drop policy if exists alpha_customer_identity_links_read on public.alpha_customer_identity_links;
create policy alpha_customer_identity_links_read on public.alpha_customer_identity_links
  for select to authenticated using (
    public.has_company_permission(company_id, 'import_data')
    or public.has_company_permission(company_id, 'view_import_audit')
  );
drop policy if exists alpha_customer_identity_decisions_read on public.alpha_customer_migration_identity_decisions;
create policy alpha_customer_identity_decisions_read on public.alpha_customer_migration_identity_decisions
  for select to authenticated using (
    public.has_company_permission(company_id, 'import_data')
    or public.has_company_permission(company_id, 'view_import_audit')
  );

create or replace function public.alpha_customer_identity_candidates(
  p_company_id uuid, p_external_code text, p_display_name text, p_tax_id text
) returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', candidate.id,
    'code', candidate.code,
    'display_name', candidate.display_name,
    'tax_id', candidate.tax_id,
    'credit_enabled', candidate.credit_enabled,
    'match_reasons', candidate.match_reasons
  ) order by candidate.display_name, candidate.code), '[]'::jsonb)
  from (
    select c.id,c.code,c.display_name,c.tax_id,c.credit_enabled,
      array_remove(array[
        case when c.code=trim(p_external_code) then 'misma clave' end,
        case when nullif(trim(coalesce(p_tax_id,'')),'') is not null
          and lower(coalesce(c.tax_id,''))=lower(trim(p_tax_id)) then 'mismo RFC' end,
        case when public.alpha_customer_identity_name(c.display_name)=public.alpha_customer_identity_name(p_display_name)
          and public.alpha_customer_identity_name(p_display_name)<>'' then 'nombre coincidente' end
      ], null) as match_reasons
    from public.customers c
    where c.company_id=p_company_id and (
      c.code=trim(p_external_code)
      or (nullif(trim(coalesce(p_tax_id,'')),'') is not null and lower(coalesce(c.tax_id,''))=lower(trim(p_tax_id)))
      or (public.alpha_customer_identity_name(c.display_name)=public.alpha_customer_identity_name(p_display_name) and public.alpha_customer_identity_name(p_display_name)<>'')
    )
  ) candidate
$$;

create or replace function public.list_alpha_customer_identity_conflicts(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if auth.uid() is null or not (
    public.has_company_permission(p_company_id,'import_data')
    or public.has_company_permission(p_company_id,'view_import_audit')
  ) then
    raise exception 'No autorizado para consultar conflictos de identidad.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'batch_id', item.batch_id,
      'cutoff_date', item.cutoff_date,
      'external_code', item.external_code,
      'display_name', item.display_name,
      'tax_id', item.tax_id,
      'commercial_type', item.commercial_type,
      'credit_limit', item.credit_limit,
      'credit_term_days', item.credit_term_days,
      'document_count', item.document_count,
      'document_total', item.document_total,
      'differences', item.differences,
      'candidates', public.alpha_customer_identity_candidates(p_company_id,item.external_code,item.display_name,item.tax_id),
      'status', item.status,
      'latest_decision', item.latest_decision,
      'decision_history', item.decision_history
    ) order by item.cutoff_date desc, item.external_code)
    from (
      select b.id as batch_id,b.cutoff_date,c.external_code,c.display_name,c.tax_id,
        c.commercial_type,c.credit_limit,c.credit_term_days,c.status,
        coalesce((select count(*) from public.alpha_customer_migration_documents d where d.batch_id=c.batch_id and d.customer_external_code=c.external_code),0) as document_count,
        coalesce((select sum(d.outstanding_amount) from public.alpha_customer_migration_documents d where d.batch_id=c.batch_id and d.customer_external_code=c.external_code),0) as document_total,
        coalesce((select jsonb_agg(jsonb_build_object('code',d.difference_code,'message',d.message,'severity',d.severity,'evidence',d.evidence) order by d.created_at)
          from public.alpha_customer_migration_differences d
          where d.batch_id=c.batch_id and d.customer_external_code=c.external_code), '[]'::jsonb) as differences,
        (select jsonb_build_object('decision',x.decision,'reason',x.reason,'decided_at',x.decided_at,'decided_by',x.decided_by,'target_customer_id',x.target_customer_id)
          from public.alpha_customer_migration_identity_decisions x
          where x.batch_id=c.batch_id and x.customer_external_code=c.external_code
          order by x.decided_at desc,x.id desc limit 1) as latest_decision,
        coalesce((select jsonb_agg(jsonb_build_object('decision',x.decision,'reason',x.reason,'evidence',x.evidence,'decided_at',x.decided_at,'decided_by',x.decided_by,'target_customer_id',x.target_customer_id) order by x.decided_at desc,x.id desc)
          from public.alpha_customer_migration_identity_decisions x
          where x.batch_id=c.batch_id and x.customer_external_code=c.external_code), '[]'::jsonb) as decision_history
      from public.alpha_customer_migration_customers c
      join public.alpha_customer_migration_batches b on b.id=c.batch_id
      where b.company_id=p_company_id
        and c.status='discrepancy'
        and not public.alpha_customer_noncanonical_tax_id(c.tax_id)
        and exists (
          select 1 from public.alpha_customer_migration_differences d
          where d.batch_id=c.batch_id and d.customer_external_code=c.external_code
            and d.difference_code='PROMOTION_FAILED'
            and d.message ~ 'customers_company_(tax_id|code)_key'
        )
    ) item
  ), '[]'::jsonb);
end $$;

create or replace function public.decide_alpha_customer_identity_conflict(
  p_batch_id uuid,
  p_customer_external_code text,
  p_decision text,
  p_target_customer_id uuid,
  p_reason text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype;
  v_stage public.alpha_customer_migration_customers%rowtype;
  v_target public.customers%rowtype;
  v_customer_id uuid;
  v_existing_link uuid;
  v_evidence jsonb;
  v_blocked integer;
  v_promoted integer;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para resolver conflictos de clientes.';
  end if;
  if p_decision not in ('link_existing','create_cash_without_rfc','leave_pending') then raise exception 'Decisión de conflicto inválida.'; end if;
  if nullif(trim(coalesce(p_customer_external_code,'')),'') is null or nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La decisión y su motivo son obligatorios.'; end if;

  select * into v_stage from public.alpha_customer_migration_customers
  where batch_id=p_batch_id and external_code=trim(p_customer_external_code) for update;
  if not found then raise exception 'Cliente Alpha no encontrado en el lote.'; end if;
  if public.alpha_customer_noncanonical_tax_id(v_stage.tax_id) then
    raise exception 'El RFC genérico se resuelve automáticamente y no requiere una decisión manual.';
  end if;
  if v_stage.status='promoted' then
    select target_customer_id into v_customer_id from public.alpha_customer_migration_identity_decisions
    where batch_id=p_batch_id and customer_external_code=v_stage.external_code and decision=p_decision and reason=trim(p_reason)
      and (p_decision<>'link_existing' or target_customer_id is not distinct from p_target_customer_id)
    order by decided_at desc,id desc limit 1;
    if found then
      select count(*) into v_blocked from public.alpha_customer_migration_customers where batch_id=p_batch_id and status='discrepancy';
      return jsonb_build_object('batch_id',p_batch_id,'customer_external_code',v_stage.external_code,'decision',p_decision,'status','resolved','promoted_customer_id',v_customer_id,'remaining_conflicts',v_blocked,'idempotent',true);
    end if;
    raise exception 'El conflicto ya fue resuelto y no admite otra decisión.';
  end if;
  if v_stage.status<>'discrepancy' then raise exception 'El caso no requiere una decisión de identidad.'; end if;
  if not exists (
    select 1 from public.alpha_customer_migration_differences d
    where d.batch_id=p_batch_id and d.customer_external_code=v_stage.external_code
      and d.difference_code='PROMOTION_FAILED' and d.message ~ 'customers_company_(tax_id|code)_key'
  ) or exists (
    select 1 from public.alpha_customer_migration_differences d
    where d.batch_id=p_batch_id and d.customer_external_code=v_stage.external_code
      and d.severity='error' and d.difference_code<>'PROMOTION_FAILED'
  ) then raise exception 'El caso contiene una diferencia distinta de identidad y no puede resolverse desde esta bandeja.'; end if;

  v_evidence:=jsonb_build_object(
    'alpha_customer',jsonb_build_object('external_code',v_stage.external_code,'display_name',v_stage.display_name,'source_tax_id',v_stage.tax_id,'commercial_type',v_stage.commercial_type,'credit_limit',v_stage.credit_limit,'credit_term_days',v_stage.credit_term_days,'document_mode',v_stage.document_mode,'reported_open_amount',v_stage.reported_open_amount),
    'differences',coalesce((select jsonb_agg(jsonb_build_object('code',d.difference_code,'message',d.message,'evidence',d.evidence) order by d.created_at) from public.alpha_customer_migration_differences d where d.batch_id=p_batch_id and d.customer_external_code=v_stage.external_code),'[]'::jsonb),
    'candidates',public.alpha_customer_identity_candidates(v_batch.company_id,v_stage.external_code,v_stage.display_name,v_stage.tax_id)
  );

  if p_decision='leave_pending' then
    insert into public.alpha_customer_migration_identity_decisions(company_id,batch_id,customer_external_code,decision,target_customer_id,reason,evidence,decided_by)
    values(v_batch.company_id,p_batch_id,v_stage.external_code,p_decision,null,trim(p_reason),v_evidence,auth.uid()) on conflict do nothing;
    perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.identity_left_pending','alpha_customer_migration_identity_decisions',p_batch_id,jsonb_build_object('customer_external_code',v_stage.external_code));
    return jsonb_build_object('batch_id',p_batch_id,'customer_external_code',v_stage.external_code,'decision',p_decision,'status','pending');
  elsif p_decision='link_existing' then
    if p_target_customer_id is null then raise exception 'Selecciona el cliente existente que deseas vincular.'; end if;
    select * into v_target from public.customers where id=p_target_customer_id and company_id=v_batch.company_id for update;
    if not found then raise exception 'El cliente seleccionado no pertenece a esta empresa.'; end if;
    if not exists (
      select 1 from public.customers c where c.id=p_target_customer_id and c.company_id=v_batch.company_id and (
        c.code=v_stage.external_code
        or (nullif(trim(coalesce(v_stage.tax_id,'')),'') is not null and lower(coalesce(c.tax_id,''))=lower(trim(v_stage.tax_id)))
        or (public.alpha_customer_identity_name(c.display_name)=public.alpha_customer_identity_name(v_stage.display_name) and public.alpha_customer_identity_name(v_stage.display_name)<>'')
      )
    ) then raise exception 'El cliente seleccionado no es un candidato verificable para este conflicto.'; end if;
    select customer_id into v_existing_link from public.alpha_customer_identity_links where company_id=v_batch.company_id and external_code=v_stage.external_code for update;
    if v_existing_link is not null and v_existing_link is distinct from p_target_customer_id then raise exception 'La clave Alpha ya fue vinculada a otro cliente canónico.'; end if;
    insert into public.alpha_customer_identity_links(company_id,external_code,customer_id,created_by)
    values(v_batch.company_id,v_stage.external_code,p_target_customer_id,auth.uid()) on conflict (company_id,external_code) do nothing;
    v_customer_id:=p_target_customer_id;
  else
    -- Contado is a creation-only decision.  A pre-existing code is an
    -- identity conflict, never permission to erase its fiscal or credit data.
    select customer_id into v_existing_link
    from public.alpha_customer_identity_links
    where company_id=v_batch.company_id and external_code=v_stage.external_code
    for update;
    if v_existing_link is not null then
      raise exception 'La clave Alpha ya está vinculada a un cliente existente; usa la opción Vincular.';
    end if;
    select * into v_target from public.customers where company_id=v_batch.company_id and code=v_stage.external_code for update;
    if found then
      raise exception 'La clave Alpha ya pertenece a un cliente existente; usa la opción Vincular.';
    end if;
    insert into public.customers(company_id,code,display_name,tax_id,credit_enabled,credit_limit,credit_term_days,is_active,created_by,alpha_external_code,alpha_source_row_hash,bank_reference,payment_manager,sales_agent,migration_status)
    values(v_batch.company_id,v_stage.external_code,v_stage.display_name,null,false,0,0,true,auth.uid(),v_stage.external_code,v_stage.source_row_hash,v_stage.bank_reference,v_stage.payment_manager,v_stage.sales_agent,'promoted') returning id into v_customer_id;
    if nullif(trim(coalesce(v_stage.address_line,'')),'') is not null then
      insert into public.customer_addresses(company_id,customer_id,label,address_line,neighborhood,municipality,state_name,postal_code,is_primary)
      values(v_batch.company_id,v_customer_id,'Principal',trim(v_stage.address_line),nullif(trim(v_stage.neighborhood),''),nullif(trim(v_stage.municipality),''),nullif(trim(v_stage.state_name),''),nullif(trim(v_stage.postal_code),''),true);
    end if;
    if nullif(trim(coalesce(v_stage.phone,'')),'') is not null then
      insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,is_primary)
      values(v_batch.company_id,v_customer_id,coalesce(nullif(trim(v_stage.contact_name),''),v_stage.display_name),'Contacto principal',trim(v_stage.phone),true);
    end if;
    insert into public.alpha_customer_identity_links(company_id,external_code,customer_id,created_by)
    values(v_batch.company_id,v_stage.external_code,v_customer_id,auth.uid()) on conflict (company_id,external_code) do nothing;
  end if;

  insert into public.alpha_customer_migration_identity_decisions(company_id,batch_id,customer_external_code,decision,target_customer_id,reason,evidence,decided_by)
  values(v_batch.company_id,p_batch_id,v_stage.external_code,p_decision,v_customer_id,trim(p_reason),v_evidence,auth.uid()) on conflict do nothing;
  update public.alpha_customer_migration_customers set status='promoted',promoted_customer_id=v_customer_id,discrepancy='[]'::jsonb where id=v_stage.id;
  update public.alpha_customer_migration_differences set severity='warning'
  where batch_id=p_batch_id and customer_external_code=v_stage.external_code and difference_code='PROMOTION_FAILED';
  select count(*) filter(where status='discrepancy'),count(*) filter(where status='promoted') into v_blocked,v_promoted from public.alpha_customer_migration_customers where batch_id=p_batch_id;
  update public.alpha_customer_migration_batches
  set status=case when v_blocked=0 then 'completed' else 'completed_with_discrepancies' end,
    records_promoted=v_promoted,
    summary=summary || jsonb_build_object('promoted_customers',v_promoted,'blocked_customers',v_blocked,'customer_identity_repair',jsonb_build_object('status','completed','source','identity_conflict_inbox','updated_at',now(),'updated_by',auth.uid()))
  where id=p_batch_id;
  perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.identity_decided','alpha_customer_migration_identity_decisions',p_batch_id,jsonb_build_object('customer_external_code',v_stage.external_code,'decision',p_decision,'target_customer_id',v_customer_id,'remaining_conflicts',v_blocked));
  return jsonb_build_object('batch_id',p_batch_id,'customer_external_code',v_stage.external_code,'decision',p_decision,'status','resolved','promoted_customer_id',v_customer_id,'remaining_conflicts',v_blocked);
end $$;

-- Backfill is incremental.  It is only completed once no staged document is
-- still held by a pending identity conflict; later resolutions can add their
-- verified documents without duplicating those already recorded.
create or replace function public.apply_alpha_repaired_customer_receivable_backfill(
  p_batch_id uuid,
  p_ledger_file_sha256 text,
  p_documents jsonb
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype;
  v_preview jsonb;
  v_inserted integer;
  v_inserted_total numeric;
  v_total_after numeric;
  v_prior_inserted integer;
  v_prior_amount numeric;
  v_remaining_documents integer;
  v_remaining_amount numeric;
  v_status text;
begin
  select * into v_batch from public.alpha_customer_migration_batches where id=p_batch_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para incorporar CxC.';
  end if;
  if v_batch.summary#>>'{receivable_backfill,status}'='completed' then
    return jsonb_build_object('status','already_applied','batch_id',p_batch_id,'summary',v_batch.summary->'receivable_backfill');
  end if;
  v_preview:=public.preview_alpha_repaired_customer_receivable_backfill(p_batch_id,p_ledger_file_sha256,p_documents);
  if not coalesce((v_preview->>'can_apply')::boolean,false) then
    raise exception 'La incorporación fue bloqueada: hay una clave, staging o documento existente incompatible.';
  end if;
  v_remaining_documents:=coalesce((v_preview->>'excluded_unresolved_customer_documents')::integer,0);
  v_remaining_amount:=coalesce((v_preview->>'excluded_unresolved_customer_amount')::numeric,0);

  with payload as materialized (
    select trim(p.customer_external_code) customer_external_code,
      trim(p.source_row_hash) source_row_hash,
      trim(p.folio) folio,
      p.document_date,
      round(p.original_amount,2) original_amount,
      round(p.outstanding_amount,2) outstanding_amount,
      encode(digest(concat_ws('|',trim(p.customer_external_code),coalesce(nullif(trim(p.source_code),''),'F'),trim(p.folio),p.document_date::text,upper(trim(p.currency_code)),(round(p.original_amount,2)*100)::bigint::text),'sha256'),'hex') source_document_key
    from jsonb_to_recordset(coalesce(p_documents,'[]'::jsonb)) p(
      customer_external_code text,folio text,source_code text,document_date date,
      original_amount numeric,outstanding_amount numeric,source_row_hash text,currency_code text
    )
  ), eligible as materialized (
    select p.*,c.promoted_customer_id
    from payload p
    join public.alpha_customer_migration_customers c
      on c.batch_id=p_batch_id and c.external_code=p.customer_external_code
    where c.status='promoted' and c.promoted_customer_id is not null
      and exists(
        select 1 from public.alpha_customer_migration_documents d
        where d.batch_id=p_batch_id
          and d.customer_external_code=p.customer_external_code
          and d.source_document_key=p.source_document_key
      )
  ), inserted as (
    insert into public.customer_receivables(company_id,customer_id,sale_id,issued_at,due_date,original_amount,outstanding_amount,source_kind,source_document_key,source_row_hash,source_reference,source_cutoff_date)
    select v_batch.company_id,e.promoted_customer_id,null,e.document_date,e.document_date,e.original_amount,e.outstanding_amount,
      'alpha_document',e.source_document_key,e.source_row_hash,e.folio,v_batch.cutoff_date
    from eligible e
    where not exists (
      select 1 from public.customer_receivables r
      where r.company_id=v_batch.company_id
        and r.source_kind in ('alpha_document','alpha_opening_balance')
        and r.source_document_key=e.source_document_key
    )
    on conflict (company_id,source_document_key) where source_kind in ('alpha_document','alpha_opening_balance') do nothing
    returning outstanding_amount
  ) select count(*),coalesce(sum(outstanding_amount),0) into v_inserted,v_inserted_total from inserted;

  select coalesce(sum(outstanding_amount),0) into v_total_after
  from public.customer_receivables
  where company_id=v_batch.company_id and source_kind='alpha_document';
  v_prior_inserted:=coalesce((v_batch.summary#>>'{receivable_backfill,documents_inserted}')::integer,0);
  v_prior_amount:=coalesce((v_batch.summary#>>'{receivable_backfill,amount_inserted}')::numeric,0);
  v_status:=case when v_remaining_documents=0 then 'completed' else 'partial' end;

  update public.alpha_customer_migration_batches
  set summary=summary || jsonb_build_object('receivable_backfill',jsonb_build_object(
    'status',v_status,'file_sha256',p_ledger_file_sha256,
    'documents_inserted',v_prior_inserted+v_inserted,'amount_inserted',v_prior_amount+v_inserted_total,
    'last_documents_inserted',v_inserted,'last_amount_inserted',v_inserted_total,
    'remaining_customer_documents',v_remaining_documents,'remaining_customer_amount',v_remaining_amount,
    'total_after',v_total_after,'validation','final_ledger_key_v2',
    'completed_at',case when v_status='completed' then now() else null end,
    'updated_at',now(),'updated_by',auth.uid()
  )) where id=p_batch_id;
  perform public.write_sales_audit(v_batch.company_id,'alpha_customer_migration.receivables_backfilled','alpha_customer_migration_batches',p_batch_id,jsonb_build_object(
    'file_sha256',p_ledger_file_sha256,'status',v_status,'documents_inserted',v_inserted,
    'amount_inserted',v_inserted_total,'remaining_customer_documents',v_remaining_documents,
    'remaining_customer_amount',v_remaining_amount,'total_after',v_total_after,'validation','final_ledger_key_v2'
  ));
  return jsonb_build_object('status',v_status,'batch_id',p_batch_id,'documents_inserted',v_inserted,'amount_inserted',v_inserted_total,'remaining_customer_documents',v_remaining_documents,'remaining_customer_amount',v_remaining_amount,'total_after',v_total_after);
end $$;

-- A decision is durable: a later cumulative Alpha export must promote into
-- the linked canonical customer, even when its source-row hash has changed.
-- This replaces only the customer lookup in the chunked promoter.
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
      -- Única adición a la versión canónica: reutilizar el vínculo decidido.
      select c.* into v_customer
      from public.alpha_customer_identity_links l
      join public.customers c on c.id=l.customer_id
      where l.company_id=v_batch.company_id and l.external_code=v_stage.external_code
      for update of c;
      if found then
        v_customer_id:=v_customer.id;
      else
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

revoke all on public.alpha_customer_identity_links,public.alpha_customer_migration_identity_decisions from authenticated;
grant select on public.alpha_customer_identity_links,public.alpha_customer_migration_identity_decisions to authenticated;
revoke all on function public.alpha_customer_identity_candidates(uuid,text,text,text),public.list_alpha_customer_identity_conflicts(uuid),public.decide_alpha_customer_identity_conflict(uuid,text,text,uuid,text) from public;
grant execute on function public.list_alpha_customer_identity_conflicts(uuid),public.decide_alpha_customer_identity_conflict(uuid,text,text,uuid,text) to authenticated;

commit;
