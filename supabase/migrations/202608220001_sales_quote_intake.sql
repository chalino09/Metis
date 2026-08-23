-- Satrapy · Mensajes por preparar para cotizaciones.
-- La IA interpreta texto; Satrapy resuelve identidades, precios, impuestos y existencias.

begin;

create table public.sales_quote_intake_requests (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete restrict,
  source text not null default 'manual' check(source in ('manual','whatsapp')),
  original_message text not null check(char_length(trim(original_message)) between 3 and 4000),
  status text not null default 'processing' check(status in ('processing','review_required','ready','dismissed','failed','converted')),
  intent text check(intent is null or intent in ('quotation_request','order','product_question','general_question','support','other')),
  intent_confidence numeric(5,4) check(intent_confidence is null or intent_confidence between 0 and 1),
  customer_hint text,
  extracted_items jsonb not null default '[]'::jsonb check(jsonb_typeof(extracted_items)='array'),
  prepared_lines jsonb not null default '[]'::jsonb check(jsonb_typeof(prepared_lines)='array'),
  raw_model_output jsonb,
  model text,
  prompt_version text,
  input_tokens integer check(input_tokens is null or input_tokens>=0),
  output_tokens integer check(output_tokens is null or output_tokens>=0),
  estimated_cost_usd numeric(14,6) check(estimated_cost_usd is null or estimated_cost_usd>=0),
  provider_trace_id text,
  latency_ms integer check(latency_ms is null or latency_ms>=0),
  error_message text,
  quote_id uuid references public.sales_quotes(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  processed_at timestamptz
);

create index sales_quote_intake_inbox_idx on public.sales_quote_intake_requests(company_id,status,created_at desc,id desc);
create index sales_quote_intake_location_idx on public.sales_quote_intake_requests(company_id,location_id,created_at desc);
alter table public.sales_quote_intake_requests enable row level security;
revoke all on public.sales_quote_intake_requests from public,anon,authenticated;

create or replace function public.start_sales_quote_intake(p_company_id uuid,p_location_id uuid,p_customer_id uuid default null,p_message text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.sales_quote_intake_requests%rowtype;begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_sales_quotes') or not public.can_access_location(p_location_id) then raise exception 'No autorizado para preparar cotizaciones.';end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active) then raise exception 'Sucursal no disponible.';end if;
  if p_customer_id is not null and not exists(select 1 from public.customers where id=p_customer_id and company_id=p_company_id and is_active) then raise exception 'Cliente no disponible.';end if;
  if char_length(trim(coalesce(p_message,''))) not between 3 and 4000 then raise exception 'Captura un mensaje de entre 3 y 4,000 caracteres.';end if;
  insert into public.sales_quote_intake_requests(company_id,location_id,customer_id,original_message) values(p_company_id,p_location_id,p_customer_id,trim(p_message)) returning * into v;
  perform public.write_sales_audit(p_company_id,'sales_quote_intake.started','sales_quote_intake_requests',v.id,jsonb_build_object('source','manual','location_id',p_location_id,'customer_selected',p_customer_id is not null));
  return jsonb_build_object('id',v.id,'status',v.status);
end$$;

create or replace function public.complete_sales_quote_intake(
  p_company_id uuid,p_request_id uuid,p_intent text,p_intent_confidence numeric,p_customer_hint text,p_items jsonb,
  p_model text,p_prompt_version text,p_raw_output jsonb,p_input_tokens integer,p_output_tokens integer,
  p_estimated_cost_usd numeric,p_trace_id text,p_latency_ms integer
) returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v public.sales_quote_intake_requests%rowtype;v_price_list_id uuid;v_currency text;v_item jsonb;v_lines jsonb:='[]'::jsonb;v_line jsonb;v_match_count integer:=0;v_low_count integer:=0;v_status text;begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_sales_quotes') then raise exception 'No autorizado para preparar cotizaciones.';end if;
  select * into v from public.sales_quote_intake_requests where id=p_request_id and company_id=p_company_id and status='processing' for update;
  if not found or not public.can_access_location(v.location_id) then raise exception 'El mensaje ya no está disponible para procesar.';end if;
  if p_intent not in('quotation_request','order','product_question','general_question','support','other') or p_intent_confidence not between 0 and 1 or jsonb_typeof(coalesce(p_items,'null'::jsonb))<>'array' then raise exception 'La interpretación recibida no es válida.';end if;
  select coalesce(customer_data.price_list_id,location_data.default_price_list_id,company_data.default_price_list_id) into v_price_list_id
  from public.locations location_data join public.companies company_data on company_data.id=location_data.company_id
  left join public.customers customer_data on customer_data.id=v.customer_id and customer_data.company_id=p_company_id where location_data.id=v.location_id and company_data.id=p_company_id;
  select currency_code into v_currency from public.price_lists where id=v_price_list_id and company_id=p_company_id and is_active and status='active';

  for v_item in select value from jsonb_array_elements(p_items) loop
    with input as (
      select lower(trim(regexp_replace(coalesce(v_item->>'raw_text',''),'\s+',' ','g'))) q
    ),ranked as (
      select product.id,coalesce(product.internal_sku,product.barcode) code,product.name,product.unit,product.is_inventory_tracked,
        coalesce(balance.quantity_on_hand,0) quantity_on_hand,price.amount base_price_amount,round(price.amount*tax.rate,2) tax_amount,round(price.amount*(1+tax.rate),2) price_amount,
        case when lower(coalesce(product.barcode,''))=input.q or lower(coalesce(product.internal_sku,''))=input.q then 1.0
          when lower(product.name)=input.q then .99
          when exists(select 1 from public.product_aliases a where a.product_id=product.id and a.normalized_value=input.q) then .98
          when lower(product.name) like '%'||input.q||'%' then .92
          else greatest(extensions.similarity(lower(product.name),input.q),coalesce((select max(extensions.similarity(a.normalized_value,input.q)) from public.product_aliases a where a.product_id=product.id),0)) end match_confidence
      from public.products product cross join input
      join public.product_prices price on price.product_id=product.id and price.price_list_id=v_price_list_id and price.currency_code=v_currency and price.valid_from<=clock_timestamp() and(price.valid_to is null or price.valid_to>clock_timestamp())
      join lateral(select rate from public.tax_rates where tax_category_id=product.tax_category_id and valid_from<=clock_timestamp() and(valid_to is null or valid_to>clock_timestamp()) order by valid_from desc limit 1)tax on true
      left join public.inventory_balances balance on balance.location_id=v.location_id and balance.product_id=product.id
      where product.company_id=p_company_id and product.is_active and product.is_sellable and not product.commercial_review_required and product.sales_unit_id is not null
        and(input.q='' or lower(product.name) like '%'||input.q||'%' or lower(coalesce(product.internal_sku,'')) like '%'||input.q||'%' or lower(coalesce(product.barcode,''))=input.q
          or extensions.similarity(lower(product.name),input.q)>=.22 or exists(select 1 from public.product_aliases a where a.product_id=product.id and(a.normalized_value like '%'||input.q||'%' or extensions.similarity(a.normalized_value,input.q)>=.22)))
      order by match_confidence desc,product.name limit 5
    ),chosen as (select * from ranked order by match_confidence desc,name limit 1),alternatives as (
      select coalesce(jsonb_agg(jsonb_build_object('product_id',id,'code',code,'name',name,'unit',unit,'price_amount',price_amount,'currency_code',v_currency,'quantity_on_hand',quantity_on_hand,'inventory_tracked',is_inventory_tracked,'confidence',round(match_confidence::numeric,4)) order by match_confidence desc,name),'[]'::jsonb) value from ranked
    ) select jsonb_build_object('raw_text',v_item->>'raw_text','quantity',(v_item->>'quantity')::numeric,'requested_unit',v_item->>'unit','brand',v_item->>'brand','presentation',v_item->>'presentation',
      'product_id',chosen.id,'product_code',chosen.code,'product_name',chosen.name,'unit_name',chosen.unit,'base_price_amount',chosen.base_price_amount,'tax_amount',chosen.tax_amount,'unit_total_amount',chosen.price_amount,
      'currency_code',v_currency,'inventory_tracked',chosen.is_inventory_tracked,'quantity_on_hand',chosen.quantity_on_hand,'match_confidence',round(chosen.match_confidence::numeric,4),'alternatives',alternatives.value)
      into v_line from chosen cross join alternatives;
    if v_line is null then
      v_line:=jsonb_build_object('raw_text',v_item->>'raw_text','quantity',(v_item->>'quantity')::numeric,'requested_unit',v_item->>'unit','brand',v_item->>'brand','presentation',v_item->>'presentation','product_id',null,'match_confidence',0,'alternatives','[]'::jsonb);
      v_low_count:=v_low_count+1;
    else
      v_match_count:=v_match_count+1;if coalesce((v_line->>'match_confidence')::numeric,0)<.9 then v_low_count:=v_low_count+1;end if;
    end if;
    v_lines:=v_lines||jsonb_build_array(v_line);
  end loop;
  v_status:=case when p_intent<>'quotation_request' then'dismissed' when jsonb_array_length(p_items)=0 or v_low_count>0 or v_currency is null then'review_required' else'ready'end;
  update public.sales_quote_intake_requests set status=v_status,intent=p_intent,intent_confidence=p_intent_confidence,customer_hint=nullif(trim(p_customer_hint),''),extracted_items=p_items,prepared_lines=v_lines,raw_model_output=p_raw_output,
    model=nullif(trim(p_model),''),prompt_version=nullif(trim(p_prompt_version),''),input_tokens=p_input_tokens,output_tokens=p_output_tokens,estimated_cost_usd=p_estimated_cost_usd,provider_trace_id=nullif(trim(p_trace_id),''),latency_ms=p_latency_ms,processed_at=clock_timestamp(),updated_at=clock_timestamp()
  where id=v.id returning * into v;
  perform public.write_sales_audit(p_company_id,'sales_quote_intake.completed','sales_quote_intake_requests',v.id,jsonb_build_object('status',v.status,'intent',v.intent,'items',jsonb_array_length(p_items),'matched_items',v_match_count,'latency_ms',p_latency_ms));
  return jsonb_build_object('id',v.id,'status',v.status,'source',v.source,'original_message',v.original_message,'intent',v.intent,'intent_confidence',v.intent_confidence,'customer_hint',v.customer_hint,'prepared_lines',v.prepared_lines,'latency_ms',v.latency_ms,'error_message',v.error_message,'created_at',v.created_at,'processed_at',v.processed_at,
    'location',(select jsonb_build_object('id',l.id,'name',l.name,'code',l.external_code) from public.locations l where l.id=v.location_id),
    'customer',(select jsonb_build_object('id',c.id,'display_name',c.display_name,'code',c.code) from public.customers c where c.id=v.customer_id));
end$$;

create or replace function public.fail_sales_quote_intake(p_request_id uuid,p_error text,p_latency_ms integer default null)
returns void language plpgsql security definer set search_path=public as $$declare v public.sales_quote_intake_requests%rowtype;begin
  select * into v from public.sales_quote_intake_requests where id=p_request_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v.company_id,'manage_sales_quotes') then return;end if;
  update public.sales_quote_intake_requests set status='failed',error_message=left(coalesce(p_error,'No se pudo procesar.'),1000),latency_ms=p_latency_ms,processed_at=clock_timestamp(),updated_at=clock_timestamp() where id=v.id and status='processing';
  perform public.write_sales_audit(v.company_id,'sales_quote_intake.failed','sales_quote_intake_requests',v.id,jsonb_build_object('latency_ms',p_latency_ms));
end$$;

create or replace function public.get_sales_quote_intake(p_company_id uuid,p_request_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$declare v public.sales_quote_intake_requests%rowtype;begin
  select * into v from public.sales_quote_intake_requests where id=p_request_id and company_id=p_company_id;
  if not found or auth.uid() is null or not public.has_company_permission(p_company_id,'view_sales_quotes') or not public.can_access_location(v.location_id) then raise exception 'Solicitud no disponible.';end if;
  return jsonb_build_object('id',v.id,'status',v.status,'source',v.source,'original_message',v.original_message,'intent',v.intent,'intent_confidence',v.intent_confidence,'customer_hint',v.customer_hint,'prepared_lines',v.prepared_lines,'latency_ms',v.latency_ms,'error_message',v.error_message,'created_at',v.created_at,'processed_at',v.processed_at,
    'location',(select jsonb_build_object('id',l.id,'name',l.name,'code',l.external_code) from public.locations l where l.id=v.location_id),
    'customer',(select jsonb_build_object('id',c.id,'display_name',c.display_name,'code',c.code) from public.customers c where c.id=v.customer_id));
end$$;

create or replace function public.list_sales_quote_intakes(p_company_id uuid,p_status text default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_sales_quotes') then raise exception 'No autorizado para consultar mensajes por preparar.';end if;
  select count(*) into v_total from public.sales_quote_intake_requests r where r.company_id=p_company_id and public.can_access_location(r.location_id) and(p_status is null or r.status=p_status);
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'status',x.status,'original_message',x.original_message,'intent',x.intent,'intent_confidence',x.intent_confidence,'line_count',jsonb_array_length(x.prepared_lines),'estimated_total',x.estimated_total,'currency_code',x.currency_code,'latency_ms',x.latency_ms,'created_at',x.created_at,'location_name',x.location_name,'customer_name',x.customer_name) order by x.created_at desc),'[]'::jsonb) into v_items from(
    select r.*,l.name location_name,c.display_name customer_name,coalesce((select sum(coalesce((line->>'quantity')::numeric,0)*coalesce((line->>'unit_total_amount')::numeric,0)) from jsonb_array_elements(r.prepared_lines)line),0) estimated_total,
      (select line->>'currency_code' from jsonb_array_elements(r.prepared_lines)line where line->>'currency_code' is not null limit 1)currency_code
    from public.sales_quote_intake_requests r join public.locations l on l.id=r.location_id left join public.customers c on c.id=r.customer_id
    where r.company_id=p_company_id and public.can_access_location(r.location_id) and(p_status is null or r.status=p_status) order by r.created_at desc,r.id desc limit v_size offset(v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'total',v_total,'page',v_page,'page_size',v_size);
end$$;

grant execute on function public.start_sales_quote_intake(uuid,uuid,uuid,text),public.complete_sales_quote_intake(uuid,uuid,text,numeric,text,jsonb,text,text,jsonb,integer,integer,numeric,text,integer),public.fail_sales_quote_intake(uuid,text,integer),public.get_sales_quote_intake(uuid,uuid),public.list_sales_quote_intakes(uuid,text,integer,integer) to authenticated;

commit;
