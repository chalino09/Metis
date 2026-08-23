-- Satrapy · Revisión y ajuste de mensajes para cotización.
-- Recalcula siempre con identidades, precios, impuestos y existencias canónicas.

begin;

create or replace function public.review_sales_quote_intake(
  p_company_id uuid,
  p_request_id uuid,
  p_location_id uuid,
  p_customer_id uuid,
  p_lines jsonb
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_request public.sales_quote_intake_requests%rowtype;
  v_input jsonb;
  v_prepared jsonb := '[]'::jsonb;
  v_price_list_id uuid;
  v_currency text;
  v_product_id uuid;
  v_product_name text;
  v_product_code text;
  v_product_unit text;
  v_inventory_tracked boolean;
  v_quantity numeric;
  v_price numeric;
  v_rate numeric;
  v_quantity_on_hand numeric;
  v_unresolved integer := 0;
  v_status text;
begin
  if auth.uid() is null
    or not public.has_company_permission(p_company_id,'manage_sales_quotes') then
    raise exception 'No autorizado para revisar solicitudes de cotización.';
  end if;

  select * into v_request
  from public.sales_quote_intake_requests
  where id=p_request_id and company_id=p_company_id
  for update;

  if not found
    or v_request.status not in ('review_required','ready')
    or not public.can_access_location(v_request.location_id) then
    raise exception 'La solicitud ya no está disponible para revisión.';
  end if;

  if not exists(
    select 1 from public.locations
    where id=p_location_id and company_id=p_company_id and is_active
      and public.can_access_location(id)
  ) then
    raise exception 'Sucursal no disponible.';
  end if;

  if p_customer_id is not null and not exists(
    select 1 from public.customers
    where id=p_customer_id and company_id=p_company_id and is_active
  ) then
    raise exception 'Cliente no disponible.';
  end if;

  if jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array'
    or jsonb_array_length(p_lines)=0
    or jsonb_array_length(p_lines)>100 then
    raise exception 'La revisión debe contener entre 1 y 100 partidas.';
  end if;

  select coalesce(customer_data.price_list_id,location_data.default_price_list_id,company_data.default_price_list_id)
    into v_price_list_id
  from public.locations location_data
  join public.companies company_data on company_data.id=location_data.company_id
  left join public.customers customer_data
    on customer_data.id=p_customer_id and customer_data.company_id=p_company_id
  where location_data.id=p_location_id and company_data.id=p_company_id;

  select currency_code into v_currency
  from public.price_lists
  where id=v_price_list_id and company_id=p_company_id and is_active and status='active';

  for v_input in select value from jsonb_array_elements(p_lines) loop
    begin
      v_quantity := (v_input->>'quantity')::numeric;
    exception when others then
      raise exception 'Todas las partidas necesitan una cantidad válida.';
    end;
    if v_quantity is null or v_quantity<=0 or v_quantity>999999999 then
      raise exception 'Todas las partidas necesitan una cantidad mayor que cero.';
    end if;

    v_product_id := nullif(v_input->>'product_id','')::uuid;
    if v_product_id is null then
      v_unresolved := v_unresolved+1;
      v_prepared := v_prepared||jsonb_build_array(jsonb_build_object(
        'raw_text',coalesce(nullif(trim(v_input->>'raw_text'),''),'Producto por identificar'),
        'quantity',v_quantity,
        'requested_unit',nullif(trim(v_input->>'requested_unit'),''),
        'product_id',null,
        'match_confidence',0,
        'alternatives','[]'::jsonb
      ));
      continue;
    end if;

    select product_data.name,coalesce(product_data.internal_sku,product_data.barcode),product_data.unit,
      product_data.is_inventory_tracked,price.amount,tax.rate,coalesce(balance.quantity_on_hand,0)
      into v_product_name,v_product_code,v_product_unit,v_inventory_tracked,v_price,v_rate,v_quantity_on_hand
    from public.products product_data
    join public.product_prices price
      on price.product_id=product_data.id
      and price.price_list_id=v_price_list_id
      and price.currency_code=v_currency
      and price.valid_from<=clock_timestamp()
      and (price.valid_to is null or price.valid_to>clock_timestamp())
    join lateral(
      select rate from public.tax_rates
      where tax_category_id=product_data.tax_category_id
        and valid_from<=clock_timestamp()
        and (valid_to is null or valid_to>clock_timestamp())
      order by valid_from desc limit 1
    ) tax on true
    left join public.inventory_balances balance
      on balance.location_id=p_location_id and balance.product_id=product_data.id
    where product_data.id=v_product_id
      and product_data.company_id=p_company_id
      and product_data.is_active
      and product_data.is_sellable
      and not product_data.commercial_review_required
      and product_data.sales_unit_id is not null
    order by price.valid_from desc
    limit 1;

    if not found then
      raise exception 'Uno de los productos seleccionados ya no tiene precio o impuestos vigentes.';
    end if;

    v_prepared := v_prepared||jsonb_build_array(jsonb_build_object(
      'raw_text',coalesce(nullif(trim(v_input->>'raw_text'),''),v_product_name),
      'quantity',v_quantity,
      'requested_unit',nullif(trim(v_input->>'requested_unit'),''),
      'product_id',v_product_id,
      'product_code',v_product_code,
      'product_name',v_product_name,
      'unit_name',v_product_unit,
      'base_price_amount',round(v_price,2),
      'tax_amount',round(v_price*v_rate,2),
      'unit_total_amount',round(v_price*(1+v_rate),2),
      'currency_code',v_currency,
      'inventory_tracked',v_inventory_tracked,
      'quantity_on_hand',v_quantity_on_hand,
      'match_confidence',1,
      'alternatives','[]'::jsonb
    ));
  end loop;

  v_status := case
    when p_customer_id is not null and v_currency is not null and v_unresolved=0 then 'ready'
    else 'review_required'
  end;

  update public.sales_quote_intake_requests
  set location_id=p_location_id,
      customer_id=p_customer_id,
      prepared_lines=v_prepared,
      status=v_status,
      updated_at=clock_timestamp()
  where id=v_request.id;

  perform public.write_sales_audit(
    p_company_id,
    'sales_quote_intake.reviewed',
    'sales_quote_intake_requests',
    v_request.id,
    jsonb_build_object(
      'status',v_status,
      'location_id',p_location_id,
      'customer_id',p_customer_id,
      'line_count',jsonb_array_length(v_prepared),
      'unresolved_lines',v_unresolved
    )
  );

  return public.get_sales_quote_intake(p_company_id,v_request.id);
end;
$$;

create or replace function public.convert_sales_quote_intake(
  p_company_id uuid,
  p_request_id uuid,
  p_location_id uuid,
  p_customer_id uuid,
  p_valid_until date,
  p_lines jsonb
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_review jsonb;
  v_quote jsonb;
  v_quote_lines jsonb;
  v_quote_id uuid;
begin
  v_review := public.review_sales_quote_intake(
    p_company_id,p_request_id,p_location_id,p_customer_id,p_lines
  );

  if v_review->>'status'<>'ready' then
    raise exception 'Resuelve el cliente y todos los productos antes de crear la cotización.';
  end if;

  select jsonb_agg(jsonb_build_object(
    'product_id',line->>'product_id',
    'quantity',(line->>'quantity')::numeric
  )) into v_quote_lines
  from jsonb_array_elements(v_review->'prepared_lines') line;

  v_quote := public.save_sales_quote(
    p_company_id,null,p_location_id,p_customer_id,p_valid_until,v_quote_lines
  );
  v_quote_id := (v_quote->>'id')::uuid;

  update public.sales_quote_intake_requests
  set status='converted',quote_id=v_quote_id,updated_at=clock_timestamp()
  where id=p_request_id and company_id=p_company_id and status='ready';

  if not found then
    raise exception 'La solicitud cambió antes de crear la cotización.';
  end if;

  perform public.write_sales_audit(
    p_company_id,
    'sales_quote_intake.converted',
    'sales_quote_intake_requests',
    p_request_id,
    jsonb_build_object('quote_id',v_quote_id,'line_count',jsonb_array_length(v_quote_lines))
  );

  return jsonb_build_object(
    'request',public.get_sales_quote_intake(p_company_id,p_request_id),
    'quote',v_quote
  );
end;
$$;

revoke all on function public.review_sales_quote_intake(uuid,uuid,uuid,uuid,jsonb) from public,anon;
revoke all on function public.convert_sales_quote_intake(uuid,uuid,uuid,uuid,date,jsonb) from public,anon;
grant execute on function public.review_sales_quote_intake(uuid,uuid,uuid,uuid,jsonb) to authenticated;
grant execute on function public.convert_sales_quote_intake(uuid,uuid,uuid,uuid,date,jsonb) to authenticated;

commit;
