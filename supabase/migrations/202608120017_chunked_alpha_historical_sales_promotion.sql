-- Large historical sales packages are promoted in bounded, atomic chunks.
-- Each request is resumable and idempotent; a failed chunk rolls back without
-- undoing prior completed chunks or leaving a partial sale.

create table if not exists public.alpha_historical_sales_promotion_progress (
  import_batch_id uuid primary key references public.import_batches(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete restrict,
  reason text not null check (length(trim(reason)) > 0),
  status text not null default 'processing' check (status in ('processing','completed')),
  total_documents integer not null check (total_documents >= 0),
  total_lines integer not null check (total_lines >= 0),
  excluded_location_documents integer not null default 0 check (excluded_location_documents >= 0),
  excluded_location_lines integer not null default 0 check (excluded_location_lines >= 0),
  taxable_amount numeric(18,2) not null default 0,
  tax_amount numeric(18,2) not null default 0,
  total_amount numeric(18,2) not null default 0,
  started_at timestamptz not null default now(),
  last_chunk_at timestamptz,
  completed_at timestamptz
);

alter table public.alpha_historical_sales_promotion_progress enable row level security;

drop policy if exists alpha_historical_sales_promotion_progress_read
  on public.alpha_historical_sales_promotion_progress;
create policy alpha_historical_sales_promotion_progress_read
  on public.alpha_historical_sales_promotion_progress
  for select to authenticated
  using (public.can_access_import_batch(import_batch_id));

create or replace function public.promote_alpha_historical_sales_chunk(
  p_import_batch_id uuid,
  p_reason text,
  p_chunk_size integer default 750
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_progress public.alpha_historical_sales_promotion_progress%rowtype;
  v_preview jsonb;
  v_currency text;
  v_chunk_size integer:=least(greatest(coalesce(p_chunk_size,750),100),1000);
  v_chunk_documents integer:=0;
  v_inserted_sales integer:=0;
  v_inserted_items integer:=0;
  v_inserted_tickets integer:=0;
  v_processed_documents integer:=0;
  v_processed_lines integer:=0;
  v_total_items integer:=0;
  v_percent numeric:=0;
begin
  if nullif(trim(coalesce(p_reason,'')),'') is null then
    raise exception 'Indica el motivo de la importación histórica.';
  end if;

  select * into v_batch
  from public.import_batches
  where id=p_import_batch_id
  for update;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if v_batch.import_type<>'sales' then raise exception 'Este lote no contiene ventas históricas.'; end if;
  if auth.uid() is null or not public.can_import_commercial(v_batch.company_id,'sales') then
    raise exception 'No autorizado para importar ventas históricas.';
  end if;

  select * into v_progress
  from public.alpha_historical_sales_promotion_progress
  where import_batch_id=p_import_batch_id
  for update;

  if found and v_progress.status='completed' then
    select count(*) into v_total_items
    from public.sale_items item
    join public.sales sale_data on sale_data.id=item.sale_id
    where sale_data.source_import_batch_id=p_import_batch_id;
    return jsonb_build_object(
      'status','completed','idempotent',true,
      'sales_imported',v_progress.total_documents,
      'items_imported',v_total_items,
      'processed_documents',v_progress.total_documents,
      'total_documents',v_progress.total_documents,
      'processed_lines',v_progress.total_lines,
      'total_lines',v_progress.total_lines,
      'percent',100,
      'excluded_location_documents',v_progress.excluded_location_documents,
      'total_amount',v_progress.total_amount
    );
  end if;

  if v_batch.status not in ('staged','validation_failed') then
    raise exception 'El lote ya no admite promoción.';
  end if;
  if v_batch.blocking_error_count>0 or v_batch.pending_warning_count>0 then
    raise exception 'El lote no está listo: resuelve o reconoce sus incidencias.';
  end if;
  if not exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^nvtadesg_')
    or not exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^cob_cte_') then
    raise exception 'El paquete histórico requiere nvtadesg y cob_cte.';
  end if;

  if v_progress.import_batch_id is null then
    v_preview:=public.preview_alpha_historical_sales_promotion(p_import_batch_id);
    if not coalesce((v_preview->>'can_promote')::boolean,false) then
      raise exception 'El lote no está listo para importar el historial.';
    end if;
    insert into public.alpha_historical_sales_promotion_progress(
      import_batch_id,company_id,requested_by,reason,total_documents,total_lines,
      excluded_location_documents,excluded_location_lines,taxable_amount,tax_amount,total_amount
    ) values (
      p_import_batch_id,v_batch.company_id,auth.uid(),trim(p_reason),
      coalesce((v_preview->>'eligible_documents')::integer,0),
      coalesce((v_preview->>'eligible_lines')::integer,0),
      coalesce((v_preview->>'excluded_location_documents')::integer,0),
      coalesce((v_preview->>'excluded_location_lines')::integer,0),
      coalesce((v_preview->>'taxable_amount')::numeric,0),
      coalesce((v_preview->>'tax_amount')::numeric,0),
      coalesce((v_preview->>'total_amount')::numeric,0)
    ) returning * into v_progress;
  elsif trim(p_reason)<>v_progress.reason then
    raise exception 'La importación ya inició con otro motivo auditado.';
  end if;

  select coalesce(base_currency_code,'MXN') into v_currency
  from public.companies where id=v_batch.company_id;

  drop table if exists pg_temp._alpha_historical_chunk_documents;
  drop table if exists pg_temp._alpha_historical_chunk_lines;
  create temporary table _alpha_historical_chunk_lines on commit drop as
  select * from public.alpha_historical_sales_lines(p_import_batch_id);
  create index on _alpha_historical_chunk_lines(document_key,row_number);

  create temporary table _alpha_historical_chunk_documents on commit drop as
  select line.document_key,
    min(line.sale_date) sale_date,min(line.source_folio) source_folio,
    min(line.source_invoice) source_invoice,min(line.source_status) source_status,
    min(line.source_customer_code) source_customer_code,min(line.source_customer_name) source_customer_name,
    (array_agg(line.location_id) filter(where line.location_id is not null))[1] location_id,
    (array_agg(line.customer_id) filter(where line.customer_id is not null))[1] customer_id,
    round(sum(line.taxable_amount),2) taxable_amount,
    round(sum(line.tax_amount),2) tax_amount,
    round(sum(line.total_amount),2) total_amount,
    count(*)::integer line_count
  from _alpha_historical_chunk_lines line
  where not exists (
    select 1 from public.sales sale_data
    where sale_data.company_id=v_batch.company_id
      and sale_data.source_kind='alpha_historical'
      and sale_data.source_import_batch_id=p_import_batch_id
      and sale_data.source_document_key=line.document_key
  )
  group by line.document_key
  having count(*) filter(where line.location_id is null)=0
    and count(distinct line.location_id)=1
    and count(*) filter(where line.product_id is null)=0
  order by line.document_key
  limit v_chunk_size;
  alter table _alpha_historical_chunk_documents add primary key(document_key);
  select count(*) into v_chunk_documents from _alpha_historical_chunk_documents;

  insert into public.sales(
    company_id,location_id,cash_register_id,cash_session_id,cashier_id,customer_id,
    sale_type,status,currency_code,subtotal_amount,discount_amount,tax_amount,total_amount,
    due_date,client_request_id,completed_at,source_kind,source_import_batch_id,source_document_key
  )
  select v_batch.company_id,document.location_id,null,null,auth.uid(),document.customer_id,
    case when lower(coalesce(document.source_status,'')) like 'cr%' then 'credit' else 'cash' end,
    'completed',v_currency,document.taxable_amount,0,document.tax_amount,document.total_amount,
    null,gen_random_uuid(),document.sale_date::timestamp at time zone 'America/Mexico_City',
    'alpha_historical',p_import_batch_id,document.document_key
  from _alpha_historical_chunk_documents document
  on conflict (company_id,source_import_batch_id,source_document_key)
    where source_kind='alpha_historical' do nothing;
  get diagnostics v_inserted_sales=row_count;

  with inserted_items as (
    insert into public.sale_items(
      sale_id,product_id,product_code,product_name,unit_name,quantity,price_list_id,
      unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount
    )
    select sale_data.id,line.product_id,line.product_code,line.product_name,line.unit_name,line.quantity,null,
      line.unit_price,line.taxable_amount,0,0,line.taxable_amount,line.tax_amount,line.total_amount
    from _alpha_historical_chunk_lines line
    join _alpha_historical_chunk_documents document on document.document_key=line.document_key
    join public.sales sale_data on sale_data.company_id=v_batch.company_id
      and sale_data.source_kind='alpha_historical'
      and sale_data.source_import_batch_id=p_import_batch_id
      and sale_data.source_document_key=line.document_key
    where not exists(select 1 from public.sale_items existing where existing.sale_id=sale_data.id)
    order by line.document_key,line.row_number
    returning id,sale_id,product_id,taxable_amount,tax_amount
  ), inserted_taxes as (
    insert into public.sale_item_taxes(sale_item_id,tax_category_id,tax_category_code,rate,tax_amount)
    select item.id,category.id,category.code,
      case when item.taxable_amount>0 then round(item.tax_amount/item.taxable_amount,6) else 0 end,
      item.tax_amount
    from inserted_items item
    join public.products product_data on product_data.id=item.product_id
    left join public.tax_categories category on category.id=product_data.tax_category_id
    where item.tax_amount>0 and category.id is not null
    returning 1
  )
  select count(*) into v_inserted_items from inserted_items;

  with ticket_payloads as materialized (
    select sale_data.id sale_id,sale_data.location_id,
      concat('ALPHA-',coalesce(nullif(regexp_replace(document.source_folio,'[^[:alnum:]-]','','g'),''),'S/F'),'-',upper(left(document.document_key,8))) folio,
      jsonb_build_object(
        'schema_version',1,
        'folio',concat('ALPHA-',coalesce(nullif(regexp_replace(document.source_folio,'[^[:alnum:]-]','','g'),''),'S/F'),'-',upper(left(document.document_key,8))),
        'issued_at',sale_data.completed_at,
        'company_id',sale_data.company_id,
        'location_id',sale_data.location_id,
        'source',jsonb_build_object('kind','alpha_historical','import_batch_id',p_import_batch_id,
          'source_folio',document.source_folio,'source_invoice',document.source_invoice,
          'source_status',document.source_status,'cash_provenance_available',false),
        'sale',jsonb_build_object('id',sale_data.id,'type',sale_data.sale_type,
          'currency_code',sale_data.currency_code,'subtotal_amount',sale_data.subtotal_amount,
          'discount_amount',sale_data.discount_amount,'tax_amount',sale_data.tax_amount,
          'total_amount',sale_data.total_amount,
          'customer',case when document.source_customer_name is null and document.source_customer_code is null then null else jsonb_build_object(
            'id',sale_data.customer_id,'code',document.source_customer_code,'display_name',document.source_customer_name) end),
        'payment',jsonb_build_object('type','historical_evidence','source_status',document.source_status,
          'cash_or_bank_movement_created',false,'receivable_created',false),
        'items',coalesce((select jsonb_agg(jsonb_build_object(
          'product_id',item.product_id,'product_code',item.product_code,'product_name',item.product_name,
          'unit_name',item.unit_name,'quantity',item.quantity,'unit_price_amount',item.unit_price_amount,
          'taxable_amount',item.taxable_amount,'tax_amount',item.tax_amount,'total_amount',item.total_amount
        ) order by item.created_at,item.id) from public.sale_items item where item.sale_id=sale_data.id),'[]'::jsonb)
      ) payload
    from _alpha_historical_chunk_documents document
    join public.sales sale_data on sale_data.company_id=v_batch.company_id
      and sale_data.source_kind='alpha_historical'
      and sale_data.source_import_batch_id=p_import_batch_id
      and sale_data.source_document_key=document.document_key
  )
  insert into public.canonical_tickets(sale_id,company_id,location_id,folio,schema_version,payload,content_sha256,issued_at)
  select payload.sale_id,v_batch.company_id,payload.location_id,payload.folio,1,payload.payload,
    encode(extensions.digest(payload.payload::text,'sha256'),'hex'),(payload.payload->>'issued_at')::timestamptz
  from ticket_payloads payload
  on conflict (sale_id) do nothing;
  get diagnostics v_inserted_tickets=row_count;

  select count(*),coalesce(sum(document.line_count),0)::integer
  into v_processed_documents,v_processed_lines
  from public.sales sale_data
  join (
    select document_key,count(*)::integer line_count
    from _alpha_historical_chunk_lines group by document_key
  ) document on document.document_key=sale_data.source_document_key
  where sale_data.source_kind='alpha_historical'
    and sale_data.source_import_batch_id=p_import_batch_id;

  update public.alpha_historical_sales_promotion_progress
  set last_chunk_at=now()
  where import_batch_id=p_import_batch_id;

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_batch.company_id,auth.uid(),'sales_history.promotion_chunk_applied','import_batch',p_import_batch_id,
    jsonb_build_object('reason',v_progress.reason,'chunk_size',v_chunk_size,
      'sales_inserted',v_inserted_sales,'items_inserted',v_inserted_items,
      'tickets_inserted',v_inserted_tickets,'processed_documents',v_processed_documents,
      'total_documents',v_progress.total_documents));

  if v_processed_documents>=v_progress.total_documents then
    select count(*) into v_total_items
    from public.sale_items item
    join public.sales sale_data on sale_data.id=item.sale_id
    where sale_data.source_import_batch_id=p_import_batch_id;

    update public.alpha_historical_sales_promotion_progress
    set status='completed',last_chunk_at=now(),completed_at=now()
    where import_batch_id=p_import_batch_id;

    update public.import_batches set
      status='completed',records_imported=v_processed_documents,completed_at=now(),closed_at=now(),last_activity_at=now(),
      notes=jsonb_build_object(
        'kind','alpha_historical_sales_promotion',
        'excluded_location_documents',v_progress.excluded_location_documents,
        'excluded_location_lines',v_progress.excluded_location_lines,
        'cash_movements_created',0,'payments_created',0,'receivables_created',0,'inventory_movements_created',0
      )::text
    where id=p_import_batch_id;

    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
    values(v_batch.company_id,auth.uid(),'sales_history.promoted','import_batch',p_import_batch_id,
      jsonb_build_object('reason',v_progress.reason,'sales_imported',v_processed_documents,
        'items_imported',v_total_items,'taxable_amount',v_progress.taxable_amount,
        'tax_amount',v_progress.tax_amount,'total_amount',v_progress.total_amount,
        'excluded_location_documents',v_progress.excluded_location_documents,
        'cash_movements_created',0,'payments_created',0,'receivables_created',0,'inventory_movements_created',0));

    return jsonb_build_object(
      'status','completed','idempotent',false,
      'sales_imported',v_processed_documents,'items_imported',v_total_items,
      'processed_documents',v_processed_documents,'total_documents',v_progress.total_documents,
      'processed_lines',v_progress.total_lines,'total_lines',v_progress.total_lines,
      'percent',100,'excluded_location_documents',v_progress.excluded_location_documents,
      'total_amount',v_progress.total_amount
    );
  end if;

  v_percent:=case when v_progress.total_documents=0 then 100
    else round(v_processed_documents::numeric*100/v_progress.total_documents,1) end;
  return jsonb_build_object(
    'status','processing','idempotent',false,
    'chunk_sales_inserted',v_inserted_sales,'chunk_items_inserted',v_inserted_items,
    'chunk_tickets_inserted',v_inserted_tickets,
    'processed_documents',v_processed_documents,'total_documents',v_progress.total_documents,
    'processed_lines',v_processed_lines,'total_lines',v_progress.total_lines,
    'percent',v_percent,'excluded_location_documents',v_progress.excluded_location_documents,
    'total_amount',v_progress.total_amount
  );
end;
$$;

revoke all on function public.promote_alpha_historical_sales(uuid,text) from authenticated;
revoke all on function public.promote_alpha_historical_sales_chunk(uuid,text,integer) from public,anon;
grant execute on function public.promote_alpha_historical_sales_chunk(uuid,text,integer) to authenticated;
