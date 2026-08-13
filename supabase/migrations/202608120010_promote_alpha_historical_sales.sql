-- Promote reconciled Alpha sales evidence into the canonical sales ledger.
-- Historical origin is explicit: it never creates payments, cash movements,
-- receivables, inventory movements, print outbox events or accounting events.

alter table public.sales
  add column if not exists source_kind text not null default 'operational',
  add column if not exists source_import_batch_id uuid references public.import_batches(id) on delete restrict,
  add column if not exists source_document_key text;

alter table public.sales alter column cash_register_id drop not null;
alter table public.sales alter column cash_session_id drop not null;

alter table public.sales drop constraint if exists sales_source_kind_check;
alter table public.sales add constraint sales_source_kind_check
  check (source_kind in ('operational','alpha_historical'));

alter table public.sales drop constraint if exists sales_check;
alter table public.sales drop constraint if exists sales_settlement_shape_check;
alter table public.sales add constraint sales_settlement_shape_check check (
  source_kind='alpha_historical'
  or (sale_type='cash' and due_date is null)
  or (sale_type='credit' and customer_id is not null and due_date is not null)
);

alter table public.sales drop constraint if exists sales_operational_provenance_check;
alter table public.sales add constraint sales_operational_provenance_check check (
  (source_kind='operational' and cash_register_id is not null and cash_session_id is not null
    and source_import_batch_id is null and source_document_key is null)
  or
  (source_kind='alpha_historical' and cash_register_id is null and cash_session_id is null
    and source_import_batch_id is not null and nullif(trim(source_document_key),'') is not null)
);

create unique index if not exists sales_alpha_historical_source_key
  on public.sales(company_id,source_import_batch_id,source_document_key)
  where source_kind='alpha_historical';

create or replace function public.alpha_historical_sales_lines(p_import_batch_id uuid)
returns table(
  staging_row_id uuid,
  row_number integer,
  document_key text,
  sale_date date,
  source_folio text,
  source_invoice text,
  source_status text,
  source_customer_code text,
  source_customer_name text,
  location_id uuid,
  customer_id uuid,
  product_id uuid,
  product_code text,
  product_name text,
  unit_name text,
  quantity numeric,
  unit_price numeric,
  taxable_amount numeric,
  tax_amount numeric,
  total_amount numeric
)
language sql
stable
security definer
set search_path=public
as $$
  with source_lines as (
    select
      row_data.id,
      row_data.row_number,
      row_data.normalized_data,
      row_data.resolved_product_id,
      batch.company_id,
      regexp_replace(coalesce(row_data.normalized_data->>'customerExternalCode',''),'^0+','','g') normalized_customer_code,
      round(coalesce(nullif(row_data.normalized_data->>'lineTotal','')::numeric,0),2) source_total,
      round(greatest(coalesce(
        nullif(row_data.normalized_data->>'taxAmount','')::numeric,
        nullif(row_data.normalized_data->>'discountAmount','')::numeric,
        coalesce(nullif(row_data.normalized_data->>'lineTotal','')::numeric,0)
          - coalesce(nullif(row_data.normalized_data->>'unitPrice','')::numeric,0)
            * coalesce(nullif(row_data.normalized_data->>'quantity','')::numeric,0),
        0
      ),0),2) source_tax
    from public.import_staging_rows row_data
    join public.import_batches batch on batch.id=row_data.import_batch_id
    where row_data.import_batch_id=p_import_batch_id
      and row_data.detected_type='sales'
      and row_data.normalized_data->>'evidenceKind'='sale_line'
      and coalesce(nullif(row_data.normalized_data->>'quantity','')::numeric,0)>0
  )
  select
    source.id,
    source.row_number,
    encode(extensions.digest(concat_ws('|',
      source.normalized_data->>'saleDate',
      source.normalized_data->>'sourceFolio',
      upper(trim(coalesce(source.normalized_data->>'locationCode',''))),
      upper(trim(coalesce(source.normalized_data->>'warehouseName',''))),
      coalesce(source.normalized_customer_code,''),
      coalesce(source.normalized_data->>'sourceInvoice','')
    ),'sha256'),'hex'),
    nullif(source.normalized_data->>'saleDate','')::date,
    source.normalized_data->>'sourceFolio',
    nullif(source.normalized_data->>'sourceInvoice',''),
    nullif(source.normalized_data->>'sourceStatus',''),
    nullif(source.normalized_customer_code,''),
    nullif(source.normalized_data->>'customerName',''),
    nullif(source.normalized_data->>'canonicalLocationId','')::uuid,
    customer_match.id,
    coalesce(source.resolved_product_id,product_data.id),
    coalesce(product_data.internal_sku,product_data.alpha_sku),
    product_data.name,
    coalesce(nullif(source.normalized_data->>'unit',''),product_data.unit),
    (source.normalized_data->>'quantity')::numeric,
    round(greatest(source.source_total-source.source_tax,0)
      /(source.normalized_data->>'quantity')::numeric,2),
    round(greatest(source.source_total-source.source_tax,0),2),
    least(source.source_tax,source.source_total),
    source.source_total
  from source_lines source
  left join public.products direct_product
    on direct_product.company_id=source.company_id
   and direct_product.alpha_sku=source.normalized_data->>'alphaSku'
  left join public.products product_data
    on product_data.id=coalesce(source.resolved_product_id,direct_product.id)
   and product_data.company_id=source.company_id
  left join lateral (
    select candidate.id
    from (
      select linked.customer_id id,0 priority
      from public.alpha_customer_identity_links linked
      where linked.company_id=source.company_id
        and regexp_replace(linked.external_code,'^0+','','g')=source.normalized_customer_code
      union all
      select customer_data.id,1 priority
      from public.customers customer_data
      where customer_data.company_id=source.company_id
        and regexp_replace(coalesce(customer_data.alpha_external_code,''),'^0+','','g')=source.normalized_customer_code
    ) candidate
    order by candidate.priority,candidate.id
    limit 1
  ) customer_match on nullif(source.normalized_customer_code,'') is not null;
$$;

revoke all on function public.alpha_historical_sales_lines(uuid) from public,anon,authenticated;

create or replace function public.preview_alpha_historical_sales_promotion(p_import_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_result jsonb;
begin
  select * into v_batch from public.import_batches where id=p_import_batch_id;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if v_batch.import_type<>'sales' then raise exception 'Este lote no contiene ventas históricas.'; end if;
  if auth.uid() is null or not (
    public.can_import_commercial(v_batch.company_id,'sales')
    or public.has_company_permission(v_batch.company_id,'view_import_audit')
  ) then raise exception 'No autorizado para revisar la promoción histórica.'; end if;

  with lines as materialized (
    select * from public.alpha_historical_sales_lines(p_import_batch_id)
  ), documents as materialized (
    select document_key,
      count(*) line_count,
      count(*) filter(where location_id is null) missing_location_lines,
      count(distinct location_id) location_count,
      count(*) filter(where product_id is null) missing_product_lines,
      bool_or(customer_id is not null) customer_linked,
      round(sum(taxable_amount),2) taxable_amount,
      round(sum(tax_amount),2) tax_amount,
      round(sum(total_amount),2) total_amount
    from lines group by document_key
  ), summary as (
    select
      count(*)::integer document_count,
      coalesce(sum(line_count),0)::integer line_count,
      count(*) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0)::integer eligible_documents,
      coalesce(sum(line_count) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0),0)::integer eligible_lines,
      count(*) filter(where missing_location_lines>0 or location_count<>1)::integer excluded_location_documents,
      coalesce(sum(line_count) filter(where missing_location_lines>0 or location_count<>1),0)::integer excluded_location_lines,
      coalesce(sum(missing_product_lines),0)::integer missing_product_lines,
      count(*) filter(where customer_linked)::integer linked_customer_documents,
      count(*) filter(where not customer_linked)::integer unlinked_customer_documents,
      round(coalesce(sum(taxable_amount) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0),0),2) taxable_amount,
      round(coalesce(sum(tax_amount) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0),0),2) tax_amount,
      round(coalesce(sum(total_amount) filter(where missing_location_lines=0 and location_count=1 and missing_product_lines=0),0),2) total_amount
    from documents
  )
  select jsonb_build_object(
    'document_count',summary.document_count,
    'line_count',summary.line_count,
    'eligible_documents',summary.eligible_documents,
    'eligible_lines',summary.eligible_lines,
    'excluded_location_documents',summary.excluded_location_documents,
    'excluded_location_lines',summary.excluded_location_lines,
    'missing_product_lines',summary.missing_product_lines,
    'linked_customer_documents',summary.linked_customer_documents,
    'unlinked_customer_documents',summary.unlinked_customer_documents,
    'taxable_amount',summary.taxable_amount,
    'tax_amount',summary.tax_amount,
    'total_amount',summary.total_amount,
    'already_promoted_documents',(select count(*) from public.sales sale_data where sale_data.source_kind='alpha_historical' and sale_data.source_import_batch_id=p_import_batch_id),
    'has_sales',exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^nvtadesg_'),
    'has_collections',exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^cob_cte_'),
    'can_promote',
      v_batch.status in ('staged','validation_failed')
      and v_batch.blocking_error_count=0
      and v_batch.pending_warning_count=0
      and summary.eligible_documents>0
      and summary.missing_product_lines=0
      and exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^nvtadesg_')
      and exists(select 1 from public.import_files where import_batch_id=p_import_batch_id and original_name~*'^cob_cte_')
  ) into v_result from summary;
  return coalesce(v_result,'{}'::jsonb);
end;
$$;

create or replace function public.promote_alpha_historical_sales(
  p_import_batch_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_batch public.import_batches%rowtype;
  v_preview jsonb;
  v_currency text;
  v_inserted_sales integer:=0;
  v_inserted_items integer:=0;
  v_inserted_tickets integer:=0;
  v_existing_sales integer:=0;
begin
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Indica el motivo de la importación histórica.'; end if;
  select * into v_batch from public.import_batches where id=p_import_batch_id for update;
  if not found then raise exception 'Lote no encontrado.'; end if;
  if v_batch.import_type<>'sales' then raise exception 'Este lote no contiene ventas históricas.'; end if;
  if auth.uid() is null or not public.can_import_commercial(v_batch.company_id,'sales') then
    raise exception 'No autorizado para importar ventas históricas.';
  end if;

  select count(*) into v_existing_sales
  from public.sales where source_kind='alpha_historical' and source_import_batch_id=p_import_batch_id;
  if v_batch.status='completed' and v_existing_sales>0 then
    return jsonb_build_object('status','completed','idempotent',true,'sales_imported',v_existing_sales,
      'items_imported',(select count(*) from public.sale_items item join public.sales sale_data on sale_data.id=item.sale_id where sale_data.source_import_batch_id=p_import_batch_id),
      'excluded_location_documents',coalesce((v_batch.notes::jsonb->>'excluded_location_documents')::integer,0));
  end if;
  if v_batch.status not in ('staged','validation_failed') then raise exception 'El lote ya no admite promoción.'; end if;

  v_preview:=public.preview_alpha_historical_sales_promotion(p_import_batch_id);
  if not coalesce((v_preview->>'can_promote')::boolean,false) then
    raise exception 'El lote no está listo: completa los archivos y resuelve o reconoce sus incidencias.';
  end if;
  select coalesce(base_currency_code,'MXN') into v_currency from public.companies where id=v_batch.company_id;

  with lines as materialized (
    select * from public.alpha_historical_sales_lines(p_import_batch_id)
  ), eligible_documents as materialized (
    select document_key,min(sale_date) sale_date,min(source_folio) source_folio,
      min(source_invoice) source_invoice,min(source_status) source_status,
      min(source_customer_code) source_customer_code,min(source_customer_name) source_customer_name,
      (array_agg(location_id) filter(where location_id is not null))[1] location_id,
      (array_agg(customer_id) filter(where customer_id is not null))[1] customer_id,
      round(sum(taxable_amount),2) taxable_amount,round(sum(tax_amount),2) tax_amount,round(sum(total_amount),2) total_amount
    from lines group by document_key
    having count(*) filter(where location_id is null)=0
      and count(distinct location_id)=1
      and count(*) filter(where product_id is null)=0
  )
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
  from eligible_documents document
  on conflict (company_id,source_import_batch_id,source_document_key)
    where source_kind='alpha_historical' do nothing;
  get diagnostics v_inserted_sales=row_count;

  with lines as materialized (
    select * from public.alpha_historical_sales_lines(p_import_batch_id)
  ), eligible_documents as materialized (
    select document_key from lines group by document_key
    having count(*) filter(where location_id is null)=0
      and count(distinct location_id)=1
      and count(*) filter(where product_id is null)=0
  ), inserted_items as (
    insert into public.sale_items(
      sale_id,product_id,product_code,product_name,unit_name,quantity,price_list_id,
      unit_price_amount,gross_amount,discount_percent,discount_amount,taxable_amount,tax_amount,total_amount
    )
    select sale_data.id,line.product_id,line.product_code,line.product_name,line.unit_name,line.quantity,null,
      line.unit_price,line.taxable_amount,0,0,line.taxable_amount,line.tax_amount,line.total_amount
    from lines line
    join eligible_documents document on document.document_key=line.document_key
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

  with lines as materialized (
    select * from public.alpha_historical_sales_lines(p_import_batch_id)
  ), documents as materialized (
    select document_key,min(sale_date) sale_date,min(source_folio) source_folio,
      min(source_invoice) source_invoice,min(source_status) source_status,
      min(source_customer_code) source_customer_code,min(source_customer_name) source_customer_name,
      (array_agg(location_id) filter(where location_id is not null))[1] location_id
    from lines group by document_key
    having count(*) filter(where location_id is null)=0
      and count(distinct location_id)=1
      and count(*) filter(where product_id is null)=0
  ), ticket_payloads as materialized (
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
    from documents document
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

  select count(*) into v_existing_sales from public.sales
  where source_kind='alpha_historical' and source_import_batch_id=p_import_batch_id;

  update public.import_batches set
    status='completed',records_imported=v_existing_sales,completed_at=now(),closed_at=now(),last_activity_at=now(),
    notes=jsonb_build_object(
      'kind','alpha_historical_sales_promotion',
      'excluded_location_documents',coalesce((v_preview->>'excluded_location_documents')::integer,0),
      'excluded_location_lines',coalesce((v_preview->>'excluded_location_lines')::integer,0),
      'cash_movements_created',0,'payments_created',0,'receivables_created',0,'inventory_movements_created',0
    )::text
  where id=p_import_batch_id;

  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_batch.company_id,auth.uid(),'sales_history.promoted','import_batch',p_import_batch_id,
    jsonb_build_object('reason',trim(p_reason),'sales_imported',v_existing_sales,'sales_inserted',v_inserted_sales,
      'items_inserted',v_inserted_items,'tickets_inserted',v_inserted_tickets,
      'taxable_amount',v_preview->'taxable_amount','tax_amount',v_preview->'tax_amount','total_amount',v_preview->'total_amount',
      'excluded_location_documents',v_preview->'excluded_location_documents',
      'cash_movements_created',0,'payments_created',0,'receivables_created',0,'inventory_movements_created',0));

  return jsonb_build_object('status','completed','idempotent',false,'sales_imported',v_existing_sales,
    'sales_inserted',v_inserted_sales,'items_imported',v_inserted_items,'tickets_imported',v_inserted_tickets,
    'excluded_location_documents',coalesce((v_preview->>'excluded_location_documents')::integer,0),
    'total_amount',(v_preview->>'total_amount')::numeric);
end;
$$;

-- Historical rows are reporting evidence, not newly confirmed operations.
create or replace function public.enforce_credit_sale_visibility()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.source_kind<>'alpha_historical' and new.sale_type='credit'
    and not public.has_company_permission(new.company_id,'view_customer_credit') then
    raise exception 'No autorizado para consultar y usar crédito de clientes.';
  end if;
  return new;
end $$;

create or replace function public.assert_alpha_customer_credit_eligibility()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.source_kind<>'alpha_historical' and new.sale_type='credit' and new.customer_id is not null
    and exists(select 1 from public.customers customer_data where customer_data.id=new.customer_id
      and customer_data.alpha_external_code is not null and customer_data.migration_status<>'promoted') then
    raise exception 'El cliente Alpha debe estar promovido y sin ajuste pendiente para vender a crédito.';
  end if;
  return new;
end $$;

create or replace function public.capture_sale_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare
  v_set public.accounting_event_rule_sets%rowtype;
  v_config public.accounting_config_versions%rowtype;
  v_payment public.sale_payments%rowtype;
  v_cost numeric:=0;
  v_items bigint:=0;
  v_costed bigint:=0;
  v_settlement text;
  v_tax_role text;
  v_lines jsonb;
begin
  if new.source_kind='alpha_historical' then return new; end if;
  if not public.accounting_operational_matrix_active(new.company_id) then return new; end if;
  select * into v_set from public.accounting_event_rule_sets where company_id=new.company_id and status='approved';
  select * into v_config from public.accounting_config_versions where id=v_set.accounting_config_version_id;
  if new.currency_code<>v_config.base_currency then raise exception 'La venta debe estar en la moneda base contable.'; end if;
  select coalesce(sum(item.recognized_cost_amount),0),count(*),count(item.recognized_cost_amount)
    into v_cost,v_items,v_costed from public.sale_items item where item.sale_id=new.id;
  if v_items=0 or v_costed<>v_items then raise exception 'La venta no puede contabilizarse: falta costo reconocido para una o más partidas.'; end if;
  if new.sale_type='cash' then
    select * into v_payment from public.sale_payments where sale_id=new.id;
    if not found then raise exception 'La venta de contado no tiene liquidación.'; end if;
    v_settlement:=case when v_payment.settlement_kind='cash_drawer' then 'cash' else 'banks' end;
    v_tax_role:='vat_collected';
  else v_settlement:='accounts_receivable';v_tax_role:='vat_pending'; end if;
  v_lines:=jsonb_build_array(jsonb_build_object('role',v_settlement,'debit',new.total_amount,'credit',0,'description','Liquidación de venta'));
  if new.discount_amount>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','sales_discounts','debit',new.discount_amount,'credit',0,'description','Descuento comercial')); end if;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','sales_revenue','debit',0,'credit',new.subtotal_amount,'description','Venta'));
  if new.tax_amount>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role',v_tax_role,'debit',0,'credit',new.tax_amount,'description','IVA de venta')); end if;
  if round(v_cost,6)>0 then v_lines:=v_lines||jsonb_build_array(
    jsonb_build_object('role','cost_of_goods_sold','debit',round(v_cost,6),'credit',0,'description','Costo de venta'),
    jsonb_build_object('role','inventory','debit',0,'credit',round(v_cost,6),'description','Salida de inventario')); end if;
  perform public.capture_accounting_event(new.company_id,'sale_confirmed','sale',new.id,1,new.completed_at::date,new.completed_at,v_lines,
    jsonb_build_object('description','Venta confirmada','cost_method',v_set.cost_method,'costed_item_count',v_costed,'item_count',v_items));
  return new;
end $$;

create or replace function public.prevent_historical_sale_post_sale()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from public.sales sale_data where sale_data.id=new.sale_id and sale_data.source_kind='alpha_historical') then
    raise exception 'Las ventas históricas importadas son de solo consulta; no admiten cancelación ni devolución operativa.';
  end if;
  return new;
end $$;

drop trigger if exists sale_cancellations_historical_guard on public.sale_cancellations;
create trigger sale_cancellations_historical_guard before insert on public.sale_cancellations
for each row execute function public.prevent_historical_sale_post_sale();
drop trigger if exists sale_returns_historical_guard on public.sale_returns;
create trigger sale_returns_historical_guard before insert on public.sale_returns
for each row execute function public.prevent_historical_sale_post_sale();

create or replace function public.list_sales(
  p_company_id uuid,p_location_id uuid default null,p_query text default null,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));v_total integer;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_sales') then raise exception 'No autorizado.';end if;
  if p_location_id is not null and not public.can_access_location(p_location_id) then raise exception 'No autorizado para esta ubicación.';end if;
  with filtered as (
    select sale_data.id,sale_data.location_id,sale_data.sale_type,sale_data.source_kind,sale_data.currency_code,sale_data.total_amount,sale_data.completed_at,
      coalesce(customer_data.display_name,ticket.payload#>>'{sale,customer,display_name}') customer_name,ticket.folio,
      coalesce((select sum(return_data.total_amount) from public.sale_returns return_data where return_data.sale_id=sale_data.id),0) returned_amount,
      exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=sale_data.id) cancelled
    from public.sales sale_data join public.canonical_tickets ticket on ticket.sale_id=sale_data.id left join public.customers customer_data on customer_data.id=sale_data.customer_id
    where sale_data.company_id=p_company_id and public.can_access_location(sale_data.location_id) and (p_location_id is null or sale_data.location_id=p_location_id)
      and (v_query='' or lower(ticket.folio) like '%'||v_query||'%' or lower(coalesce(customer_data.display_name,ticket.payload#>>'{sale,customer,display_name}','')) like '%'||v_query||'%')
  ) select count(*) into v_total from filtered;
  with filtered as (
    select sale_data.id,sale_data.location_id,sale_data.sale_type,sale_data.source_kind,sale_data.currency_code,sale_data.total_amount,sale_data.completed_at,
      coalesce(customer_data.display_name,ticket.payload#>>'{sale,customer,display_name}') customer_name,ticket.folio,
      coalesce((select sum(return_data.total_amount) from public.sale_returns return_data where return_data.sale_id=sale_data.id),0) returned_amount,
      exists(select 1 from public.sale_cancellations cancellation where cancellation.sale_id=sale_data.id) cancelled
    from public.sales sale_data join public.canonical_tickets ticket on ticket.sale_id=sale_data.id left join public.customers customer_data on customer_data.id=sale_data.customer_id
    where sale_data.company_id=p_company_id and public.can_access_location(sale_data.location_id) and (p_location_id is null or sale_data.location_id=p_location_id)
      and (v_query='' or lower(ticket.folio) like '%'||v_query||'%' or lower(coalesce(customer_data.display_name,ticket.payload#>>'{sale,customer,display_name}','')) like '%'||v_query||'%')
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'sale_id',page_data.id,'folio',page_data.folio,'location_id',page_data.location_id,'sale_type',page_data.sale_type,'source_kind',page_data.source_kind,
    'customer_name',page_data.customer_name,'currency_code',page_data.currency_code,'total_amount',page_data.total_amount,
    'returned_amount',page_data.returned_amount,'cancelled',page_data.cancelled,'completed_at',page_data.completed_at
  ) order by page_data.completed_at desc),'[]'::jsonb) into v_items
  from(select * from filtered order by completed_at desc limit v_size offset(v_page-1)*v_size)page_data;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end $$;

revoke all on function public.preview_alpha_historical_sales_promotion(uuid) from public,anon;
revoke all on function public.promote_alpha_historical_sales(uuid,text) from public,anon;
grant execute on function public.preview_alpha_historical_sales_promotion(uuid) to authenticated;
grant execute on function public.promote_alpha_historical_sales(uuid,text) to authenticated;
