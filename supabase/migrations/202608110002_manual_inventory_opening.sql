-- Inventario inicial manual por ubicación.
-- Caso previsto: altas de operación con hasta 500 productos. Volúmenes mayores
-- continúan entrando por la frontera de importación, no registro por registro.

begin;

alter table public.inventory_ledger
  drop constraint if exists inventory_ledger_movement_type_check,
  drop constraint if exists inventory_ledger_source_check;

alter table public.inventory_ledger
  add constraint inventory_ledger_movement_type_check check(movement_type in (
    'opening_snapshot','opening_manual','sale','sale_reversal','sale_return','controlled_adjustment',
    'physical_count_adjustment','transfer_out','transfer_in','purchase_receipt','purchase_receipt_reversal'
  )),
  add constraint inventory_ledger_source_check check(
    (movement_type='opening_snapshot' and source_snapshot_item_id is not null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type='opening_manual' and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type='sale' and sale_item_id is not null and source_snapshot_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type='sale_reversal' and sale_cancellation_item_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_return_item_id is null)
    or (movement_type='sale_return' and sale_return_item_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null)
    or (movement_type='controlled_adjustment' and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type='physical_count_adjustment' and inventory_count_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_transfer_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type in ('transfer_out','transfer_in') and inventory_transfer_line_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and purchase_receipt_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
    or (movement_type in ('purchase_receipt','purchase_receipt_reversal') and purchase_receipt_line_id is not null and purchase_receipt_id is not null and purchase_order_id is not null and supplier_id is not null and source_snapshot_item_id is null and sale_item_id is null and inventory_count_line_id is null and inventory_transfer_line_id is null and sale_cancellation_item_id is null and sale_return_item_id is null)
  );

create unique index if not exists audit_inventory_manual_opening_request_uidx
  on public.audit_log(company_id,(metadata->>'request_id'))
  where action='inventory.manual_opening_registered' and metadata?'request_id';

create or replace function public.search_manual_inventory_opening_products(
  p_company_id uuid,
  p_location_id uuid,
  p_query text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=public
as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_query text:=lower(trim(coalesce(p_query,'')));
  v_total bigint;
  v_items jsonb;
  v_eligible boolean;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'operate_inventory') then
    raise exception 'No autorizado para registrar inventario inicial.';
  end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active and public.can_access_location(id)) then
    raise exception 'Ubicación no disponible.';
  end if;

  v_eligible:=not exists(select 1 from public.inventory_ledger where company_id=p_company_id and location_id=p_location_id)
    and not exists(select 1 from public.inventory_balances where company_id=p_company_id and location_id=p_location_id and quantity_on_hand<>0);

  with scope as materialized (
    select product.id product_id,coalesce(product.internal_sku,product.alpha_sku) product_code,product.name,product.unit
    from public.products product
    where product.company_id=p_company_id and product.is_active and product.is_inventory_tracked
      and (v_query='' or lower(product.name) like '%'||v_query||'%' or lower(coalesce(product.internal_sku,'')) like '%'||v_query||'%' or lower(coalesce(product.alpha_sku,'')) like '%'||v_query||'%' or lower(coalesce(product.barcode,''))=v_query)
  ), paged as (
    select * from scope order by name,product_id limit v_size offset (v_page-1)*v_size
  )
  select (select count(*) from scope),coalesce(jsonb_agg(to_jsonb(paged) order by name,product_id),'[]'::jsonb)
  into v_total,v_items from paged;

  return jsonb_build_object('eligible',v_eligible,'items',v_items,'total',coalesce(v_total,0),'page',v_page,'page_size',v_size);
end;
$$;

create or replace function public.initialize_inventory_location(
  p_company_id uuid,
  p_location_id uuid,
  p_lines jsonb,
  p_reason text,
  p_client_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_count integer;
  v_total numeric(18,6);
  v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'operate_inventory') then
    raise exception 'No autorizado para registrar inventario inicial.';
  end if;
  if p_client_request_id is null then raise exception 'Falta la identidad de la operación.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'El motivo es obligatorio.'; end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<1 or jsonb_array_length(p_lines)>500 then
    raise exception 'Registra entre 1 y 500 productos; para más productos usa la importación.';
  end if;
  if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active and public.can_access_location(id)) then
    raise exception 'Ubicación no disponible.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||p_location_id::text,0));
  select metadata->'result' into v_result from public.audit_log
  where company_id=p_company_id and action='inventory.manual_opening_registered' and metadata->>'request_id'=p_client_request_id::text
  limit 1;
  if v_result is not null then return v_result; end if;

  if exists(select 1 from public.inventory_ledger where company_id=p_company_id and location_id=p_location_id)
    or exists(select 1 from public.inventory_balances where company_id=p_company_id and location_id=p_location_id and quantity_on_hand<>0) then
    raise exception 'Esta ubicación ya tiene movimientos. Usa una recepción o un conteo físico para ajustar existencias.';
  end if;

  create temporary table opening_lines(product_id uuid primary key,quantity numeric(18,6) not null) on commit drop;
  insert into opening_lines(product_id,quantity)
  select line.product_id,line.quantity
  from jsonb_to_recordset(p_lines) as line(product_id uuid,quantity numeric);

  if (select count(*) from opening_lines)<>jsonb_array_length(p_lines) then raise exception 'No repitas productos en el inventario inicial.'; end if;
  if exists(select 1 from opening_lines where product_id is null or quantity<=0) then raise exception 'Todas las cantidades deben ser mayores a cero.'; end if;
  if exists(select 1 from opening_lines line left join public.products product on product.id=line.product_id and product.company_id=p_company_id and product.is_active and product.is_inventory_tracked where product.id is null) then
    raise exception 'Hay productos que no están activos o no controlan existencias.';
  end if;

  insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand,updated_at)
  select p_company_id,p_location_id,line.product_id,line.quantity,clock_timestamp() from opening_lines line
  on conflict(location_id,product_id) do update set quantity_on_hand=excluded.quantity_on_hand,updated_at=excluded.updated_at;

  insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,occurred_at,actor_id)
  select p_company_id,p_location_id,line.product_id,line.quantity,line.quantity,'opening_manual',clock_timestamp(),auth.uid() from opening_lines line;

  select count(*),sum(quantity) into v_count,v_total from opening_lines;
  v_result:=jsonb_build_object('location_id',p_location_id,'item_count',v_count,'total_units',v_total,'registered_at',clock_timestamp());
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'inventory.manual_opening_registered','location',p_location_id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'result',v_result));
  return v_result;
end;
$$;

revoke all on function public.search_manual_inventory_opening_products(uuid,uuid,text,integer,integer) from public,anon;
grant execute on function public.search_manual_inventory_opening_products(uuid,uuid,text,integer,integer) to authenticated;
revoke all on function public.initialize_inventory_location(uuid,uuid,jsonb,text,uuid) from public,anon;
grant execute on function public.initialize_inventory_location(uuid,uuid,jsonb,text,uuid) to authenticated;

commit;
