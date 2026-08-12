-- Identificadores internos: se generan por empresa en el servidor.
-- Los códigos externos e importados permanecen intactos.

create or replace function public.next_company_internal_code(p_company_id uuid,p_prefix text,p_table regclass,p_column text)
returns text language plpgsql security definer set search_path=public as $$
declare v_next bigint;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||p_prefix,0));
  execute format(
    'select coalesce(max(nullif(regexp_replace(%1$I,''[^0-9]'','''',''g''),'''')::bigint),0)+1 from %2$s where company_id=$1 and upper(%1$I) ~ $2',
    p_column,p_table
  ) into v_next using p_company_id, '^'||p_prefix||'-[0-9]+$';
  return p_prefix||'-'||lpad(v_next::text,6,'0');
end $$;

create or replace function public.save_product(
  p_company_id uuid,p_product_id uuid,p_internal_sku text,p_name text,p_barcode text,p_unit text,p_product_group text,p_is_inventory_tracked boolean,p_is_sellable boolean,p_is_active boolean,p_tax_category_id uuid,p_reason text,p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_product public.products%rowtype;v_previous jsonb;v_replayed jsonb;v_code text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_products') then raise exception 'No autorizado para administrar productos.';end if;
  if nullif(trim(p_name),'') is null or length(trim(p_name))>240 then raise exception 'El nombre es obligatorio y admite hasta 240 caracteres.';end if;
  if nullif(trim(p_reason),'') is null or p_client_request_id is null then raise exception 'Captura un motivo y vuelve a intentar.';end if;
  if p_tax_category_id is not null and not exists(select 1 from public.tax_categories where id=p_tax_category_id and company_id=p_company_id and is_active) then raise exception 'La categoría fiscal no pertenece a esta empresa o está inactiva.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,0));
  select to_jsonb(product) into v_replayed from public.audit_log audit join public.products product on product.id=audit.entity_id and product.company_id=audit.company_id where audit.company_id=p_company_id and audit.action='product.admin_saved' and audit.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replayed is not null then return v_replayed||jsonb_build_object('idempotent',true);end if;
  if p_product_id is null then
    v_code:=coalesce(nullif(upper(trim(p_internal_sku)),''),public.next_company_internal_code(p_company_id,'PROD','public.products'::regclass,'internal_sku'));
    insert into public.products(company_id,internal_sku,alpha_sku,name,barcode,unit,product_group,is_inventory_tracked,is_sellable,is_active,commercial_review_required,tax_category_id)
    values(p_company_id,v_code,null,trim(p_name),nullif(trim(p_barcode),''),nullif(trim(p_unit),''),nullif(trim(p_product_group),''),coalesce(p_is_inventory_tracked,false),coalesce(p_is_sellable,false),coalesce(p_is_active,true),false,p_tax_category_id) returning * into v_product;
    v_previous:=null;
  else
    select * into v_product from public.products where id=p_product_id and company_id=p_company_id for update;
    if not found then raise exception 'El producto ya no está disponible.';end if;
    if p_expected_updated_at is null or v_product.updated_at<>p_expected_updated_at then raise exception 'El producto cambió mientras lo editabas. Actualiza y vuelve a intentarlo.';end if;
    v_previous:=to_jsonb(v_product);
    update public.products set name=trim(p_name),barcode=nullif(trim(p_barcode),''),unit=nullif(trim(p_unit),''),product_group=nullif(trim(p_product_group),''),is_inventory_tracked=coalesce(p_is_inventory_tracked,false),is_sellable=coalesce(p_is_sellable,false),is_active=coalesce(p_is_active,true),tax_category_id=p_tax_category_id where id=p_product_id returning * into v_product;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'product.admin_saved','product',v_product.id,jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'origin','manual','previous',v_previous,'current',to_jsonb(v_product)));
  return to_jsonb(v_product)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.upsert_payment_method(p_company_id uuid,p_payment_method_id uuid default null,p_code text default null,p_display_name text default null,p_settlement_kind text default null,p_is_active boolean default true)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_code text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_payment_methods') then raise exception 'No autorizado para configurar medios de pago.';end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null or p_settlement_kind not in('cash_drawer','external') then raise exception 'Configuración de medio de pago inválida.';end if;
  if p_payment_method_id is null then
    v_code:=coalesce(nullif(upper(trim(p_code)),''),public.next_company_internal_code(p_company_id,'PAGO','public.payment_methods'::regclass,'code'));
    insert into public.payment_methods(company_id,code,display_name,settlement_kind,is_active) values(p_company_id,v_code,trim(p_display_name),p_settlement_kind,coalesce(p_is_active,true)) returning id into v_id;
  else
    update public.payment_methods set display_name=trim(p_display_name),settlement_kind=p_settlement_kind,is_active=coalesce(p_is_active,true) where id=p_payment_method_id and company_id=p_company_id returning id into v_id;
    if v_id is null then raise exception 'Medio de pago no encontrado.';end if;
    select code into v_code from public.payment_methods where id=v_id;
  end if;
  perform public.write_sales_audit(p_company_id,'payment_method.configured','payment_methods',v_id,jsonb_build_object('code',v_code,'settlement_kind',p_settlement_kind,'is_active',coalesce(p_is_active,true)));
  return v_id;
end $$;

create or replace function public.upsert_cash_register(p_company_id uuid,p_cash_register_id uuid default null,p_location_id uuid default null,p_code text default null,p_display_name text default null,p_currency_code text default 'MXN',p_is_active boolean default true)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_code text;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_locations') then raise exception 'No autorizado para configurar cajas.';end if;
  if p_location_id is null or not exists(select 1 from public.locations where id=p_location_id and company_id=p_company_id and is_active) then raise exception 'Ubicación de caja inválida.';end if;
  if nullif(trim(coalesce(p_display_name,'')),'') is null or length(trim(coalesce(p_currency_code,'')))<>3 then raise exception 'Configuración de caja inválida.';end if;
  if p_cash_register_id is null then
    v_code:=coalesce(nullif(upper(trim(p_code)),''),public.next_company_internal_code(p_company_id,'CAJA','public.cash_registers'::regclass,'code'));
    insert into public.cash_registers(company_id,location_id,code,display_name,currency_code,is_active) values(p_company_id,p_location_id,v_code,trim(p_display_name),upper(trim(p_currency_code)),coalesce(p_is_active,true)) returning id into v_id;
  else
    if exists(select 1 from public.cash_sessions where cash_register_id=p_cash_register_id and status in('open','pending_variance_approval')) then raise exception 'No se puede reconfigurar una caja con sesión pendiente.';end if;
    update public.cash_registers set location_id=p_location_id,display_name=trim(p_display_name),currency_code=upper(trim(p_currency_code)),is_active=coalesce(p_is_active,true) where id=p_cash_register_id and company_id=p_company_id returning id into v_id;
    if v_id is null then raise exception 'Caja no encontrada.';end if;
    select code into v_code from public.cash_registers where id=v_id;
  end if;
  perform public.write_sales_audit(p_company_id,'cash_register.configured','cash_registers',v_id,jsonb_build_object('location_id',p_location_id,'code',v_code));
  return v_id;
end $$;

revoke all on function public.next_company_internal_code(uuid,text,regclass,text) from public,anon,authenticated;
grant execute on function public.save_product(uuid,uuid,text,text,text,text,text,boolean,boolean,boolean,uuid,text,timestamptz,uuid),public.upsert_payment_method(uuid,uuid,text,text,text,boolean),public.upsert_cash_register(uuid,uuid,uuid,text,text,text,boolean) to authenticated;
