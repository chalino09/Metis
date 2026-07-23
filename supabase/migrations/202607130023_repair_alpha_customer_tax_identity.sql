-- Recover Alpha customers blocked only by repeated or generic RFC values.
-- Source RFC values remain in staging. Satrapy writes only canonical tax IDs.

create or replace function public.alpha_customer_identity_name(p_value text)
returns text language sql immutable parallel safe as $$
  select regexp_replace(
    translate(upper(trim(coalesce(p_value,''))), 'ÁÉÍÓÚÜÑ', 'AEIOUUN'),
    '[^A-Z0-9]', '', 'g'
  )
$$;

create or replace function public.alpha_customer_noncanonical_tax_id(p_tax_id text)
returns boolean language sql immutable parallel safe as $$
  -- Alpha uses X-prefixed placeholders with a synthetic numeric body. XAXX is
  -- the official generic prefix; Alpha also exported malformed 010101 variants.
  -- Neither form identifies a fiscal person in the canonical customer master.
  select upper(trim(coalesce(p_tax_id,''))) ~ '^X[A-Z]*010101[0-9]*$'
      or upper(trim(coalesce(p_tax_id,''))) ~ '^XAXX[0-9]+$'
$$;

create or replace function public.preview_alpha_customer_identity_repair(p_batch_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype;
  v_result jsonb;
begin
  select * into v_batch
  from public.alpha_customer_migration_batches
  where id=p_batch_id;

  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para revisar la reparación de identidades Alpha.';
  end if;

  with blocked as materialized (
    select c.*
    from public.alpha_customer_migration_customers c
    where c.batch_id=p_batch_id
      and c.status='discrepancy'
      and exists (
        select 1
        from public.alpha_customer_migration_differences d
        where d.batch_id=c.batch_id
          and d.customer_external_code=c.external_code
          and d.difference_code='PROMOTION_FAILED'
          and d.message like '%customers_company_tax_id_key%'
      )
  ), classified as materialized (
    select b.external_code,b.display_name,b.tax_id,
      case
        when public.alpha_customer_noncanonical_tax_id(b.tax_id) then 'promote_without_tax_id'
        when winner.promoted_customer_id is not null then 'link_to_promoted_customer'
        else 'ambiguous'
      end as resolution,
      winner.promoted_customer_id as target_customer_id
    from blocked b
    left join lateral (
      select w.promoted_customer_id
      from public.alpha_customer_migration_customers w
      where w.batch_id=b.batch_id
        and w.status='promoted'
        and w.promoted_customer_id is not null
        and lower(coalesce(w.tax_id,''))=lower(coalesce(b.tax_id,''))
        and public.alpha_customer_identity_name(w.display_name)=public.alpha_customer_identity_name(b.display_name)
      order by w.external_code
      limit 1
    ) winner on true
  )
  select jsonb_build_object(
    'batch_id',p_batch_id,
    'status','preview',
    'canonicalize_existing_generic_tax_ids',(
      select count(*)
      from public.alpha_customer_migration_customers existing
      where existing.batch_id=p_batch_id
        and existing.status='promoted'
        and public.alpha_customer_noncanonical_tax_id(existing.tax_id)
    ),
    'promote_without_tax_id',count(*) filter(where resolution='promote_without_tax_id'),
    'link_to_promoted_customer',count(*) filter(where resolution='link_to_promoted_customer'),
    'ambiguous_customers',count(*) filter(where resolution='ambiguous'),
    'ambiguous_groups',count(distinct tax_id) filter(where resolution='ambiguous'),
    'examples',coalesce((
      select jsonb_agg(jsonb_build_object(
        'external_code',external_code,
        'display_name',display_name,
        'source_tax_id',tax_id,
        'resolution',resolution,
        'target_customer_id',target_customer_id
      ) order by resolution,external_code)
      from (
        select * from classified
        order by resolution,external_code
        limit 25
      ) samples
    ),'[]'::jsonb)
  ) into v_result
  from classified;

  return v_result;
end $$;

create or replace function public.apply_alpha_customer_identity_repair(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_batch public.alpha_customer_migration_batches%rowtype;
  v_stage public.alpha_customer_migration_customers%rowtype;
  v_customer public.customers%rowtype;
  v_customer_id uuid;
  v_canonicalized_existing_generic integer:=0;
  v_promoted_without_tax_id integer:=0;
  v_linked integer:=0;
  v_promoted integer:=0;
  v_blocked integer:=0;
  v_result jsonb;
begin
  select * into v_batch
  from public.alpha_customer_migration_batches
  where id=p_batch_id
  for update;

  if not found or auth.uid() is null or not public.has_company_permission(v_batch.company_id,'import_data') then
    raise exception 'No autorizado para reparar identidades Alpha.';
  end if;
  if v_batch.status <> 'completed_with_discrepancies' then
    raise exception 'El lote no está disponible para esta reparación de clientes.';
  end if;
  if v_batch.summary#>>'{customer_identity_repair,status}'='completed' then
    return jsonb_build_object('status','already_applied','batch_id',p_batch_id,'summary',v_batch.summary->'customer_identity_repair');
  end if;

  -- The first row of each generic RFC group was promoted before the duplicate
  -- collision surfaced. Canonicalize it too; otherwise the placeholder would
  -- remain as a false fiscal identity in the customer master.
  with changed as (
    update public.customers customer_row
    set tax_id=null,credit_enabled=false,credit_limit=0,credit_term_days=0
    from public.alpha_customer_migration_customers staged
    where staged.batch_id=p_batch_id
      and staged.status='promoted'
      and staged.promoted_customer_id=customer_row.id
      and customer_row.company_id=v_batch.company_id
      and public.alpha_customer_noncanonical_tax_id(staged.tax_id)
      and (
        customer_row.tax_id is not null
        or customer_row.credit_enabled
        or customer_row.credit_limit <> 0
        or customer_row.credit_term_days <> 0
      )
    returning 1
  ) select count(*) into v_canonicalized_existing_generic from changed;

  -- Generic Alpha RFCs identify no fiscal person. Create one canonical cash
  -- customer per Alpha code with a NULL tax_id; the source value stays staged.
  for v_stage in
    select c.*
    from public.alpha_customer_migration_customers c
    where c.batch_id=p_batch_id
      and c.status='discrepancy'
      and public.alpha_customer_noncanonical_tax_id(c.tax_id)
      and exists (
        select 1 from public.alpha_customer_migration_differences d
        where d.batch_id=c.batch_id
          and d.customer_external_code=c.external_code
          and d.difference_code='PROMOTION_FAILED'
          and d.message like '%customers_company_tax_id_key%'
      )
    order by c.external_code
    for update
  loop
    select * into v_customer
    from public.customers
    where company_id=v_batch.company_id and code=v_stage.external_code
    for update;

    if found then
      if v_customer.alpha_external_code is distinct from v_stage.external_code
        or v_customer.alpha_source_row_hash is distinct from v_stage.source_row_hash then
        raise exception 'Existe un cliente con la misma clave y una fuente incompatible: %.',v_stage.external_code;
      end if;
      v_customer_id:=v_customer.id;
    else
      insert into public.customers(
        company_id,code,display_name,tax_id,credit_enabled,credit_limit,
        credit_term_days,is_active,created_by,alpha_external_code,
        alpha_source_row_hash,bank_reference,payment_manager,sales_agent,
        migration_status
      ) values (
        v_batch.company_id,v_stage.external_code,v_stage.display_name,null,
        false,0,0,true,auth.uid(),v_stage.external_code,
        v_stage.source_row_hash,v_stage.bank_reference,v_stage.payment_manager,
        v_stage.sales_agent,'promoted'
      ) returning id into v_customer_id;

      if nullif(trim(coalesce(v_stage.address_line,'')),'') is not null then
        insert into public.customer_addresses(company_id,customer_id,label,address_line,neighborhood,municipality,state_name,postal_code,is_primary)
        values(v_batch.company_id,v_customer_id,'Principal',trim(v_stage.address_line),nullif(trim(v_stage.neighborhood),''),nullif(trim(v_stage.municipality),''),nullif(trim(v_stage.state_name),''),nullif(trim(v_stage.postal_code),''),true);
      end if;
      if nullif(trim(coalesce(v_stage.phone,'')),'') is not null then
        insert into public.customer_contacts(company_id,customer_id,display_name,role_name,phone,is_primary)
        values(v_batch.company_id,v_customer_id,coalesce(nullif(trim(v_stage.contact_name),''),v_stage.display_name),'Contacto principal',trim(v_stage.phone),true);
      end if;
    end if;

    update public.alpha_customer_migration_customers
    set status='promoted',promoted_customer_id=v_customer_id
    where id=v_stage.id;
    update public.alpha_customer_migration_differences
    set severity='warning'
    where batch_id=p_batch_id
      and customer_external_code=v_stage.external_code
      and difference_code='PROMOTION_FAILED'
      and message like '%customers_company_tax_id_key%';
    v_promoted_without_tax_id:=v_promoted_without_tax_id+1;
  end loop;

  -- A repeated fiscal identity is never another canonical customer. Link it
  -- only when its normalized name agrees with an already promoted Alpha row.
  with links as materialized (
    select c.id,w.promoted_customer_id
    from public.alpha_customer_migration_customers c
    join lateral (
      select winner.promoted_customer_id
      from public.alpha_customer_migration_customers winner
      where winner.batch_id=c.batch_id
        and winner.status='promoted'
        and winner.promoted_customer_id is not null
        and lower(coalesce(winner.tax_id,''))=lower(coalesce(c.tax_id,''))
        and public.alpha_customer_identity_name(winner.display_name)=public.alpha_customer_identity_name(c.display_name)
      order by winner.external_code
      limit 1
    ) w on true
    where c.batch_id=p_batch_id
      and c.status='discrepancy'
      and not public.alpha_customer_noncanonical_tax_id(c.tax_id)
      and exists (
        select 1 from public.alpha_customer_migration_differences d
        where d.batch_id=c.batch_id
          and d.customer_external_code=c.external_code
          and d.difference_code='PROMOTION_FAILED'
          and d.message like '%customers_company_tax_id_key%'
      )
  ), linked as (
    update public.alpha_customer_migration_customers c
    set status='promoted',promoted_customer_id=links.promoted_customer_id
    from links
    where c.id=links.id
    returning c.external_code
  ), audited as (
    update public.alpha_customer_migration_differences d
    set severity='warning'
    where d.batch_id=p_batch_id
      and d.difference_code='PROMOTION_FAILED'
      and d.message like '%customers_company_tax_id_key%'
      and exists(select 1 from linked l where l.external_code=d.customer_external_code)
    returning 1
  ) select count(*) into v_linked from linked;

  select count(*) filter(where status='promoted'),count(*) filter(where status='discrepancy')
    into v_promoted,v_blocked
  from public.alpha_customer_migration_customers
  where batch_id=p_batch_id;

  update public.alpha_customer_migration_batches
  set status=case when v_blocked>0 then 'completed_with_discrepancies' else 'completed' end,
    records_promoted=v_promoted,
    summary=summary || jsonb_build_object(
      'promoted_customers',v_promoted,
      'blocked_customers',v_blocked,
      'customer_identity_repair',jsonb_build_object(
        'status','completed',
        'canonicalized_existing_generic_tax_ids',v_canonicalized_existing_generic,
        'promoted_without_tax_id',v_promoted_without_tax_id,
        'linked_to_promoted_customer',v_linked,
        'ambiguous_customers',v_blocked,
        'completed_at',now(),
        'completed_by',auth.uid()
      )
    )
  where id=p_batch_id;

  perform public.write_sales_audit(
    v_batch.company_id,
    'alpha_customer_migration.identities_repaired',
    'alpha_customer_migration_batches',
    p_batch_id,
    jsonb_build_object(
      'promoted_without_tax_id',v_promoted_without_tax_id,
      'canonicalized_existing_generic_tax_ids',v_canonicalized_existing_generic,
      'linked_to_promoted_customer',v_linked,
      'ambiguous_customers',v_blocked,
      'credit_enabled',false
    )
  );

  v_result:=public.preview_alpha_customer_identity_repair(p_batch_id);
  return v_result || jsonb_build_object(
    'status','completed',
    'promoted_customers',v_promoted,
    'blocked_customers',v_blocked,
    'promoted_without_tax_id',v_promoted_without_tax_id,
    'canonicalized_existing_generic_tax_ids',v_canonicalized_existing_generic,
    'linked_to_promoted_customer',v_linked
  );
end $$;

revoke all on function public.alpha_customer_identity_name(text),public.alpha_customer_noncanonical_tax_id(text),public.preview_alpha_customer_identity_repair(uuid),public.apply_alpha_customer_identity_repair(uuid) from public;
grant execute on function public.preview_alpha_customer_identity_repair(uuid),public.apply_alpha_customer_identity_repair(uuid) to authenticated;
