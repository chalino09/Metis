--hay  Task 28 · Purchase units convert to the product's canonical inventory/sales unit.
-- Existing quantities remain canonical: historical and open records default to factor 1.

begin;

create table if not exists public.product_purchase_units (
  product_id uuid primary key references public.products(id) on delete cascade,
  purchase_unit_id uuid not null references public.units_of_measure(id) on delete restrict,
  base_units_per_purchase_unit numeric(18,6) not null check (base_units_per_purchase_unit > 0),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid()
);

alter table public.purchase_order_lines
  add column if not exists purchase_unit_id uuid references public.units_of_measure(id) on delete restrict,
  add column if not exists base_units_per_purchase_unit numeric(18,6) not null default 1 check (base_units_per_purchase_unit > 0);

alter table public.purchase_receipt_lines
  add column if not exists base_units_per_purchase_unit numeric(18,6) not null default 1 check (base_units_per_purchase_unit > 0),
  add column if not exists inventory_quantity numeric(18,6) generated always as (round(quantity*base_units_per_purchase_unit,6)) stored;

update public.products product
set purchase_unit_id = coalesce(product.purchase_unit_id, product.base_unit_id, product.sales_unit_id)
where product.purchase_unit_id is null;

insert into public.product_purchase_units(product_id, purchase_unit_id, base_units_per_purchase_unit)
select product.id, coalesce(product.purchase_unit_id, product.base_unit_id, product.sales_unit_id), 1
from public.products product
where coalesce(product.purchase_unit_id, product.base_unit_id, product.sales_unit_id) is not null
on conflict(product_id) do nothing;

-- No se reescriben OC existentes: las aprobadas son inmutables. Sus nuevas
-- columnas conservan el factor 1 por defecto y toda OC creada después de esta
-- migración guarda su unidad de compra y equivalencia como evidencia propia.

create or replace function public.assert_product_purchase_unit_company()
returns trigger language plpgsql set search_path=public as $$
declare v_company uuid;
begin
  select company_id into v_company from public.products where id=new.product_id;
  if v_company is null or not exists(select 1 from public.units_of_measure where id=new.purchase_unit_id and company_id=v_company and is_active) then
    raise exception 'La unidad de compra no pertenece al producto o está inactiva.';
  end if;
  return new;
end $$;

drop trigger if exists product_purchase_units_company_guard on public.product_purchase_units;
create trigger product_purchase_units_company_guard
before insert or update on public.product_purchase_units
for each row execute function public.assert_product_purchase_unit_company();

create or replace function public.get_product_purchase_unit(p_company_id uuid, p_product_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_product public.products%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_products') then raise exception 'No autorizado para consultar la unidad de compra.'; end if;
  select * into v_product from public.products where id=p_product_id and company_id=p_company_id;
  if not found then raise exception 'Producto no encontrado.'; end if;
  return jsonb_build_object(
    'base_unit', (select code from public.units_of_measure where id=v_product.base_unit_id),
    'purchase_unit', (select code from public.units_of_measure where id=coalesce(v_product.purchase_unit_id,v_product.base_unit_id)),
    'base_units_per_purchase_unit', coalesce((select base_units_per_purchase_unit from public.product_purchase_units where product_id=v_product.id),1)
  );
end $$;

create or replace function public.set_product_purchase_unit(
  p_company_id uuid, p_product_id uuid, p_purchase_unit_code text,
  p_base_units_per_purchase_unit numeric, p_reason text, p_client_request_id uuid
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_product public.products%rowtype; v_unit public.units_of_measure%rowtype; v_previous jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then raise exception 'No autorizado para configurar unidades de compra.'; end if;
  if nullif(trim(coalesce(p_purchase_unit_code,'')),'') is null or length(trim(p_purchase_unit_code))>80 then raise exception 'La unidad de compra es obligatoria.'; end if;
  if coalesce(p_base_units_per_purchase_unit,0)<=0 then raise exception 'La equivalencia debe ser mayor a cero.'; end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Motivo y referencia idempotente son obligatorios.'; end if;
  select * into v_product from public.products where id=p_product_id and company_id=p_company_id for update;
  if not found or v_product.base_unit_id is null then raise exception 'Primero define la unidad base del producto.'; end if;
  select to_jsonb(purchase) into v_previous from public.product_purchase_units purchase where purchase.product_id=v_product.id;
  insert into public.units_of_measure(company_id,code,name,source)
  values(p_company_id,upper(trim(p_purchase_unit_code)),upper(trim(p_purchase_unit_code)),'manual')
  on conflict(company_id,code) do update set name=excluded.name
  returning * into v_unit;
  insert into public.product_purchase_units(product_id,purchase_unit_id,base_units_per_purchase_unit,updated_at,updated_by)
  values(v_product.id,v_unit.id,p_base_units_per_purchase_unit,now(),auth.uid())
  on conflict(product_id) do update set purchase_unit_id=excluded.purchase_unit_id,base_units_per_purchase_unit=excluded.base_units_per_purchase_unit,updated_at=now(),updated_by=auth.uid();
  update public.products set purchase_unit_id=v_unit.id, sales_unit_id=coalesce(base_unit_id,sales_unit_id), updated_at=now() where id=v_product.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'product.purchase_unit_configured','product',v_product.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'previous',v_previous,'purchase_unit',v_unit.code,'base_units_per_purchase_unit',p_base_units_per_purchase_unit));
  return public.get_product_purchase_unit(p_company_id,v_product.id);
end $$;

create or replace function public.search_purchase_order_products(p_company_id uuid,p_query text,p_limit integer default 30)
returns jsonb language plpgsql stable security definer set search_path=public,extensions as $$
declare v_query text:=lower(trim(coalesce(p_query,'')));v_limit integer:=least(greatest(coalesce(p_limit,30),1),50);v_items jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'view_products') or public.has_company_permission(p_company_id,'create_purchase_orders') or public.has_company_permission(p_company_id,'edit_purchase_orders')) then raise exception 'No autorizado para seleccionar productos de la OC.';end if;
  if length(v_query)<2 then return jsonb_build_object('items','[]'::jsonb);end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',item.id,'alpha_sku',item.alpha_sku,'internal_sku',item.internal_sku,'barcode',item.barcode,'name',item.name,'unit',item.purchase_unit,'base_unit',item.base_unit,'base_units_per_purchase_unit',item.base_units_per_purchase_unit,'is_inventory_tracked',item.is_inventory_tracked) order by item.search_rank,item.name,item.id),'[]'::jsonb) into v_items
  from (select product.id,product.alpha_sku,product.internal_sku,product.barcode,product.name,product.is_inventory_tracked,purchase.code purchase_unit,base.code base_unit,coalesce(config.base_units_per_purchase_unit,1) base_units_per_purchase_unit,
    case when lower(coalesce(product.barcode,''))=v_query or lower(coalesce(product.internal_sku,''))=v_query or lower(product.alpha_sku)=v_query then 0 when lower(coalesce(product.internal_sku,'')) like v_query||'%' or lower(product.alpha_sku) like v_query||'%' then 1 when lower(product.name) like v_query||'%' then 2 when exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like '%'||v_query||'%') then 3 else 4 end search_rank
    from public.products product left join public.product_purchase_units config on config.product_id=product.id left join public.units_of_measure purchase on purchase.id=coalesce(config.purchase_unit_id,product.purchase_unit_id,product.base_unit_id) left join public.units_of_measure base on base.id=product.base_unit_id
    where product.company_id=p_company_id and product.is_active and product.is_inventory_tracked and (lower(product.name) like '%'||v_query||'%' or lower(product.alpha_sku) like '%'||v_query||'%' or lower(coalesce(product.internal_sku,'')) like '%'||v_query||'%' or lower(coalesce(product.barcode,''))=v_query or exists(select 1 from public.product_aliases alias where alias.product_id=product.id and alias.normalized_value like '%'||v_query||'%')) order by search_rank,product.name,product.id limit v_limit) item;
  return jsonb_build_object('items',v_items);
end $$;

create or replace function public.save_purchase_order(p_company_id uuid,p_purchase_order_id uuid,p_supplier_id uuid,p_currency_code text,p_ordered_date date,p_expected_date date default null,p_supplier_reference text default null,p_requisition_reference text default null,p_notes text default null,p_order_discount_percent numeric default 0,p_lines jsonb default '[]'::jsonb,p_expected_updated_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_before jsonb;v_after jsonb;v_line jsonb;v_line_no int:=0;v_status text;v_currency text:=upper(trim(coalesce(p_currency_code,'')));v_product public.products%rowtype;v_purchase public.product_purchase_units%rowtype;v_unit text;v_factor numeric;
begin
  if auth.uid() is null then raise exception 'No autorizado.';end if;
  if p_purchase_order_id is null and not public.has_company_permission(p_company_id,'create_purchase_orders') then raise exception 'No autorizado para crear órdenes de compra.';end if;
  if p_purchase_order_id is not null and not public.has_company_permission(p_company_id,'edit_purchase_orders') then raise exception 'No autorizado para editar órdenes de compra.';end if;
  if v_currency!~'^[A-Z]{3}$' or p_ordered_date is null or (p_expected_date is not null and p_expected_date<p_ordered_date) then raise exception 'Los datos generales de la OC no son válidos.';end if;
  if coalesce(p_order_discount_percent,0) not between 0 and 100 or jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La OC requiere partidas y un descuento válido.';end if;
  if not exists(select 1 from public.suppliers where id=p_supplier_id and company_id=p_company_id and is_active) then raise exception 'Selecciona un proveedor activo de la empresa.';end if;
  if p_purchase_order_id is null then insert into public.purchase_orders(company_id,supplier_id,folio,currency_code,ordered_date,expected_date,supplier_reference,requisition_reference,notes,order_discount_percent) values(p_company_id,p_supplier_id,public.next_purchase_order_folio(p_company_id,false),v_currency,p_ordered_date,p_expected_date,nullif(trim(p_supplier_reference),''),nullif(trim(p_requisition_reference),''),nullif(trim(p_notes),''),coalesce(p_order_discount_percent,0)) returning id into v_id;
  else select to_jsonb(po),po.status into v_before,v_status from public.purchase_orders po where po.id=p_purchase_order_id and po.company_id=p_company_id for update;if not found or v_status not in ('draft','rejected') then raise exception 'La OC ya fue enviada y no admite edición.';end if;if p_expected_updated_at is not null and (v_before->>'updated_at')::timestamptz is distinct from p_expected_updated_at then raise exception 'La OC cambió desde que la abriste.';end if;v_id:=p_purchase_order_id;update public.purchase_orders set supplier_id=p_supplier_id,currency_code=v_currency,ordered_date=p_ordered_date,expected_date=p_expected_date,supplier_reference=nullif(trim(p_supplier_reference),''),requisition_reference=nullif(trim(p_requisition_reference),''),notes=nullif(trim(p_notes),''),order_discount_percent=coalesce(p_order_discount_percent,0),status='draft',updated_by=auth.uid() where id=v_id;delete from public.purchase_order_lines where purchase_order_id=v_id;end if;
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_line_no:=v_line_no+1;select * into v_product from public.products where id=nullif(v_line->>'product_id','')::uuid and company_id=p_company_id; if not found then raise exception 'Cada partida debe usar un producto canónico.';end if;select * into v_purchase from public.product_purchase_units where product_id=v_product.id;v_factor:=coalesce(v_purchase.base_units_per_purchase_unit,1);select code into v_unit from public.units_of_measure where id=coalesce(v_purchase.purchase_unit_id,v_product.purchase_unit_id,v_product.base_unit_id);if v_unit is null then raise exception 'Configura la unidad de compra de %.',v_product.name;end if;
    insert into public.purchase_order_lines(company_id,purchase_order_id,line_number,product_id,description,unit,purchase_unit_id,base_units_per_purchase_unit,quantity,unit_cost,discount_percent_1,discount_percent_2,expected_date,requisition_reference) values(p_company_id,v_id,v_line_no,v_product.id,trim(coalesce(v_line->>'description',v_product.name)),v_unit,coalesce(v_purchase.purchase_unit_id,v_product.purchase_unit_id,v_product.base_unit_id),v_factor,(v_line->>'quantity')::numeric,(v_line->>'unit_cost')::numeric,coalesce((v_line->>'discount_percent_1')::numeric,0),coalesce((v_line->>'discount_percent_2')::numeric,0),nullif(v_line->>'expected_date','')::date,nullif(trim(v_line->>'requisition_reference'),''));
  end loop;
  perform public.recalculate_purchase_order(v_id);select to_jsonb(po) into v_after from public.purchase_orders po where po.id=v_id;insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_purchase_order_id is null then 'purchase_order.created' else 'purchase_order.updated' end,'purchase_order',v_id,jsonb_build_object('before',v_before,'after',v_after,'line_count',v_line_no));return v_after;
exception when invalid_text_representation or numeric_value_out_of_range or not_null_violation or check_violation then raise exception 'Una o más partidas contienen datos inválidos.';end $$;

create or replace function public.save_purchase_receipt(p_company_id uuid,p_receipt_id uuid,p_purchase_order_id uuid,p_location_id uuid,p_receipt_date date,p_document_reference text default null,p_notes text default null,p_lines jsonb default '[]'::jsonb,p_client_request_id uuid default null,p_expected_updated_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_order public.purchase_orders%rowtype;v_id uuid;v_line jsonb;v_po_line public.purchase_order_lines%rowtype;v_qty numeric;v_previous numeric;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_before jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_purchase_receipt_drafts') then raise exception 'No autorizado para administrar borradores de recepción.';end if;if p_receipt_date is null or jsonb_typeof(coalesce(p_lines,'null'::jsonb))<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La recepción requiere fecha y al menos una partida.';end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id for update;if not found or v_order.status<>'approved' then raise exception 'Sólo una OC aprobada puede recibirse.';end if;if not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active and public.can_access_location(id)) then raise exception 'Ubicación no disponible.';end if;
  if p_receipt_id is null then select * into v_receipt from public.purchase_receipts where company_id=p_company_id and client_request_id=v_request;if found then return to_jsonb(v_receipt);end if;insert into public.purchase_receipts(company_id,purchase_order_id,supplier_id,location_id,folio,receipt_date,document_reference,notes,client_request_id) values(p_company_id,p_purchase_order_id,v_order.supplier_id,p_location_id,public.next_purchase_receipt_folio(p_company_id),p_receipt_date,nullif(trim(p_document_reference),''),nullif(trim(p_notes),''),v_request) returning id into v_id;
  else select to_jsonb(r) into v_before from public.purchase_receipts r where r.id=p_receipt_id and r.company_id=p_company_id;select * into v_receipt from public.purchase_receipts r where r.id=p_receipt_id and r.company_id=p_company_id for update;if not found or v_receipt.status<>'draft' or v_receipt.purchase_order_id<>p_purchase_order_id then raise exception 'La recepción ya no admite esta edición.';end if;if p_expected_updated_at is not null and v_receipt.updated_at is distinct from p_expected_updated_at then raise exception 'La recepción cambió desde que la abriste.';end if;v_id:=v_receipt.id;update public.purchase_receipts set location_id=p_location_id,receipt_date=p_receipt_date,document_reference=nullif(trim(p_document_reference),''),notes=nullif(trim(p_notes),''),updated_by=auth.uid() where id=v_id;delete from public.purchase_receipt_lines where purchase_receipt_id=v_id;end if;
  for v_line in select value from jsonb_array_elements(p_lines) loop begin v_qty:=(v_line->>'quantity')::numeric;exception when others then raise exception 'Cantidad de recepción inválida.';end;if v_qty<=0 then raise exception 'Las cantidades recibidas deben ser mayores a cero.';end if;select * into v_po_line from public.purchase_order_lines where id=nullif(v_line->>'purchase_order_line_id','')::uuid and purchase_order_id=p_purchase_order_id and company_id=p_company_id for update;if not found or v_po_line.product_id is null then raise exception 'La partida no pertenece a la OC.';end if;select coalesce(sum(rl.quantity),0) into v_previous from public.purchase_receipt_lines rl join public.purchase_receipts r on r.id=rl.purchase_receipt_id where rl.purchase_order_line_id=v_po_line.id and r.status='confirmed';if v_qty>v_po_line.quantity-v_previous then raise exception 'La cantidad recibida supera la cantidad pendiente.';end if;insert into public.purchase_receipt_lines(company_id,purchase_receipt_id,purchase_order_line_id,product_id,quantity,base_units_per_purchase_unit,unit_cost) values(p_company_id,v_id,v_po_line.id,v_po_line.product_id,v_qty,v_po_line.base_units_per_purchase_unit,round(v_po_line.unit_cost*(1-v_po_line.discount_percent_1/100)*(1-v_po_line.discount_percent_2/100)*(1-v_order.order_discount_percent/100),6));end loop;
  select * into v_receipt from public.purchase_receipts where id=v_id;insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_receipt_id is null then 'purchase_receipt.draft_created' else 'purchase_receipt.draft_updated' end,'purchase_receipt',v_id,jsonb_build_object('before',v_before,'line_count',jsonb_array_length(p_lines),'client_request_id',v_request));return to_jsonb(v_receipt);
end $$;

create or replace function public.confirm_purchase_receipt(p_company_id uuid,p_receipt_id uuid,p_client_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_order public.purchase_orders%rowtype;v_line record;v_balance numeric;v_pending numeric;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_fulfillment text;v_now timestamptz:=clock_timestamp();v_old_cost numeric;v_cost_id uuid;v_cost record;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_purchase_receipts') then raise exception 'No autorizado para confirmar recepciones.';end if;select * into v_receipt from public.purchase_receipts where id=p_receipt_id and company_id=p_company_id for update;if not found then raise exception 'Recepción no encontrada.';end if;if v_receipt.confirm_request_id=v_request and v_receipt.status in ('confirmed','reversed') then return jsonb_build_object('receipt_id',v_receipt.id,'status',v_receipt.status,'idempotent',true,'fulfillment_status',(select fulfillment_status from public.purchase_orders where id=v_receipt.purchase_order_id));end if;if v_receipt.status<>'draft' or not public.can_access_location(v_receipt.location_id) then raise exception 'La recepción no está disponible para confirmarse.';end if;select * into v_order from public.purchase_orders where id=v_receipt.purchase_order_id and company_id=p_company_id for update;if v_order.status<>'approved' or not exists(select 1 from public.purchase_receipt_lines where purchase_receipt_id=v_receipt.id) then raise exception 'La recepción no se puede confirmar.';end if;
  for v_line in select rl.*,pol.quantity ordered_quantity from public.purchase_receipt_lines rl join public.purchase_order_lines pol on pol.id=rl.purchase_order_line_id where rl.purchase_receipt_id=v_receipt.id order by rl.purchase_order_line_id for update of pol loop select v_line.ordered_quantity-coalesce(sum(other.quantity),0) into v_pending from public.purchase_receipt_lines other join public.purchase_receipts r on r.id=other.purchase_receipt_id where other.purchase_order_line_id=v_line.purchase_order_line_id and r.status='confirmed';if v_line.quantity>v_pending then raise exception 'La cantidad recibida supera la cantidad pendiente.';end if;insert into public.inventory_balances(company_id,location_id,product_id,quantity_on_hand) values(p_company_id,v_receipt.location_id,v_line.product_id,0) on conflict(location_id,product_id) do nothing;select quantity_on_hand into v_balance from public.inventory_balances where location_id=v_receipt.location_id and product_id=v_line.product_id for update;update public.inventory_balances set quantity_on_hand=v_balance+v_line.inventory_quantity,updated_at=v_now where location_id=v_receipt.location_id and product_id=v_line.product_id;insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,purchase_receipt_line_id,purchase_receipt_id,purchase_order_id,supplier_id,occurred_at,actor_id) values(p_company_id,v_receipt.location_id,v_line.product_id,v_line.inventory_quantity,v_balance+v_line.inventory_quantity,'purchase_receipt',v_line.id,v_receipt.id,v_order.id,v_order.supplier_id,v_now,auth.uid());end loop;
  for v_cost in select rl.product_id,v_order.currency_code,round(sum(rl.line_cost)/sum(rl.inventory_quantity),6) amount from public.purchase_receipt_lines rl where rl.purchase_receipt_id=v_receipt.id group by rl.product_id loop select amount into v_old_cost from public.product_costs where company_id=p_company_id and product_id=v_cost.product_id and cost_type='replacement_cost' and currency_code=v_cost.currency_code and valid_from<=v_now and (valid_to is null or valid_to>v_now) order by valid_from desc limit 1 for update;update public.product_costs set valid_to=v_now where company_id=p_company_id and product_id=v_cost.product_id and cost_type='replacement_cost' and currency_code=v_cost.currency_code and valid_to is null and valid_from<v_now;insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,source_file_name,created_by) values(p_company_id,v_cost.product_id,'replacement_cost',v_cost.amount,v_cost.currency_code,v_now,'purchase_receipt:'||v_receipt.folio,auth.uid()) returning id into v_cost_id;insert into public.purchase_receipt_cost_changes(company_id,purchase_receipt_id,product_id,currency_code,previous_amount,applied_amount,applied_product_cost_id) values(p_company_id,v_receipt.id,v_cost.product_id,v_cost.currency_code,v_old_cost,v_cost.amount,v_cost_id);end loop;
  update public.purchase_receipts set status='confirmed',confirmed_at=v_now,confirmed_by=auth.uid(),confirm_request_id=v_request,updated_by=auth.uid() where id=v_receipt.id;v_fulfillment:=public.recalculate_purchase_order_fulfillment(v_order.id);insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'purchase_receipt.confirmed','purchase_receipt',v_receipt.id,jsonb_build_object('purchase_order_id',v_order.id,'supplier_id',v_order.supplier_id,'location_id',v_receipt.location_id,'fulfillment_status',v_fulfillment,'client_request_id',v_request));return jsonb_build_object('receipt_id',v_receipt.id,'status','confirmed','idempotent',false,'fulfillment_status',v_fulfillment);
end $$;

create or replace function public.reverse_purchase_receipt(p_company_id uuid,p_receipt_id uuid,p_reason text,p_client_request_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_receipt public.purchase_receipts%rowtype;v_order public.purchase_orders%rowtype;v_line record;v_balance numeric;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_fulfillment text;v_now timestamptz:=clock_timestamp();v_cost record;v_cost_id uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'reverse_purchase_receipts') then raise exception 'No autorizado para autorizar reversas.';end if;if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La reversa requiere un motivo.';end if;select * into v_receipt from public.purchase_receipts where id=p_receipt_id and company_id=p_company_id for update;if not found then raise exception 'Recepción no encontrada.';end if;if v_receipt.reverse_request_id=v_request and v_receipt.status='reversed' then return jsonb_build_object('receipt_id',v_receipt.id,'status','reversed','idempotent',true,'fulfillment_status',(select fulfillment_status from public.purchase_orders where id=v_receipt.purchase_order_id));end if;if v_receipt.status<>'confirmed' then raise exception 'Sólo una recepción confirmada puede revertirse.';end if;select * into v_order from public.purchase_orders where id=v_receipt.purchase_order_id for update;
  for v_line in select * from public.purchase_receipt_lines where purchase_receipt_id=v_receipt.id order by product_id,purchase_order_line_id loop select quantity_on_hand into v_balance from public.inventory_balances where location_id=v_receipt.location_id and product_id=v_line.product_id for update;if v_balance is null or v_balance<v_line.inventory_quantity then raise exception 'Existencia insuficiente para revertir la recepción.';end if;update public.inventory_balances set quantity_on_hand=v_balance-v_line.inventory_quantity,updated_at=v_now where location_id=v_receipt.location_id and product_id=v_line.product_id;insert into public.inventory_ledger(company_id,location_id,product_id,quantity_delta,balance_after,movement_type,purchase_receipt_line_id,purchase_receipt_id,purchase_order_id,supplier_id,occurred_at,actor_id) values(p_company_id,v_receipt.location_id,v_line.product_id,-v_line.inventory_quantity,v_balance-v_line.inventory_quantity,'purchase_receipt_reversal',v_line.id,v_receipt.id,v_order.id,v_order.supplier_id,v_now,auth.uid());end loop;
  for v_cost in select * from public.purchase_receipt_cost_changes where purchase_receipt_id=v_receipt.id for update loop if exists(select 1 from public.product_costs where id=v_cost.applied_product_cost_id and valid_to is null) then update public.product_costs set valid_to=v_now where id=v_cost.applied_product_cost_id;if v_cost.previous_amount is not null then insert into public.product_costs(company_id,product_id,cost_type,amount,currency_code,valid_from,source_file_name,created_by) values(p_company_id,v_cost.product_id,'replacement_cost',v_cost.previous_amount,v_cost.currency_code,v_now,'purchase_receipt_reversal:'||v_receipt.folio,auth.uid()) returning id into v_cost_id;update public.purchase_receipt_cost_changes set reversal_product_cost_id=v_cost_id where id=v_cost.id;end if;end if;end loop;
  update public.purchase_receipts set status='reversed',reversed_at=v_now,reversed_by=auth.uid(),reversal_reason=trim(p_reason),reverse_request_id=v_request,updated_by=auth.uid() where id=v_receipt.id;v_fulfillment:=public.recalculate_purchase_order_fulfillment(v_order.id);insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'purchase_receipt.reversed','purchase_receipt',v_receipt.id,jsonb_build_object('purchase_order_id',v_order.id,'supplier_id',v_order.supplier_id,'location_id',v_receipt.location_id,'reason',trim(p_reason),'fulfillment_status',v_fulfillment,'client_request_id',v_request));return jsonb_build_object('receipt_id',v_receipt.id,'status','reversed','idempotent',false,'fulfillment_status',v_fulfillment);
end $$;

revoke all on public.product_purchase_units from authenticated;
alter table public.product_purchase_units enable row level security;
create policy product_purchase_units_read on public.product_purchase_units for select to authenticated using(exists(select 1 from public.products p where p.id=product_id and public.has_company_permission(p.company_id,'view_products')));
grant execute on function public.get_product_purchase_unit(uuid,uuid),public.set_product_purchase_unit(uuid,uuid,text,numeric,text,uuid),public.search_purchase_order_products(uuid,text,integer),public.save_purchase_order(uuid,uuid,uuid,text,date,date,text,text,text,numeric,jsonb,timestamptz),public.save_purchase_receipt(uuid,uuid,uuid,uuid,date,text,text,jsonb,uuid,timestamptz),public.confirm_purchase_receipt(uuid,uuid,uuid),public.reverse_purchase_receipt(uuid,uuid,text,uuid) to authenticated;

commit;
