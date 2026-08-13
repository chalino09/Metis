-- Correcciones de costo como evidencia separada: las ventas POS permanecen inmutables.

create table if not exists public.sale_item_cost_correction_lines(
  correction_id uuid not null references public.sale_item_cost_corrections(id)on delete restrict,
  sale_item_id uuid not null references public.sale_items(id)on delete restrict,
  unit_cost numeric(18,6)not null check(unit_cost>0),
  cost_amount numeric(18,6)not null check(cost_amount>=0),
  primary key(correction_id,sale_item_id),unique(sale_item_id)
);
alter table public.sale_item_cost_correction_lines enable row level security;
revoke all on public.sale_item_cost_correction_lines from public,anon,authenticated;
create index if not exists sale_item_cost_correction_lines_item_idx on public.sale_item_cost_correction_lines(sale_item_id);

create or replace function public.bi_effective_sale_item_cost(p_sale_item_id uuid,p_recognized_cost numeric)
returns numeric language sql stable security definer set search_path=public as $$
  select coalesce(p_recognized_cost,(select line.cost_amount from public.sale_item_cost_correction_lines line where line.sale_item_id=p_sale_item_id));
$$;
revoke all on function public.bi_effective_sale_item_cost(uuid,numeric)from public,anon,authenticated;

create or replace function public.bi_list_missing_cost_products(
  p_company_id uuid,p_date_from date,p_date_to date,p_page integer default 1,p_page_size integer default 25
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,25),1),100);v_items jsonb;v_total bigint;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'view_costs')or not public.has_company_permission(p_company_id,'view_bi_alerts')then raise exception'No autorizado para consultar costos faltantes.';end if;
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to or p_date_to-p_date_from>366 then raise exception'Periodo inválido.';end if;
  with grouped as materialized(
    select item.product_id,item.product_code,item.product_name,count(*)item_count,sum(item.quantity)quantity,sum(item.taxable_amount)net_sales,min(sale.completed_at)::date first_sale_date,max(sale.completed_at)::date last_sale_date
    from public.sales sale join public.sale_items item on item.sale_id=sale.id
    where sale.company_id=p_company_id and sale.completed_at::date between p_date_from and p_date_to and item.recognized_cost_amount is null
      and not exists(select 1 from public.sale_item_cost_correction_lines line where line.sale_item_id=item.id)
      and public.can_access_location(sale.location_id)and not exists(select 1 from public.sale_cancellations cancel where cancel.sale_id=sale.id)
    group by item.product_id,item.product_code,item.product_name
  ),paged as(select grouped.*,cost.amount current_cost,cost.currency_code from grouped left join lateral(
    select product_cost.amount,product_cost.currency_code from public.product_costs product_cost where product_cost.company_id=p_company_id and product_cost.product_id=grouped.product_id and product_cost.valid_from<=now()and(product_cost.valid_to is null or product_cost.valid_to>now())order by product_cost.valid_from desc limit 1
  )cost on true order by item_count desc,product_name limit v_size offset(v_page-1)*v_size)
  select coalesce(jsonb_agg(to_jsonb(paged)order by item_count desc,product_name),'[]'),(select count(*)from grouped)into v_items,v_total from paged;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total),'trace','sale_items + sale_item_cost_correction_lines');
end$$;

drop function if exists public.bi_apply_missing_sale_cost(uuid,uuid,date,date,numeric,text,text);
create or replace function public.bi_apply_missing_sale_cost(
  p_company_id uuid,p_product_id uuid,p_date_from date,p_date_to date,p_unit_cost numeric,p_reason text,p_comparison_mode text default'previous_period',
  p_evaluation_from date default null,p_evaluation_to date default null
)returns jsonb language plpgsql security definer set search_path=public as $$
declare v_rule public.accounting_event_rule_sets%rowtype;v_currency text;v_correction_id uuid;v_count integer;v_quantity numeric;v_eval jsonb;
begin
  if auth.uid()is null or not public.has_company_permission(p_company_id,'import_costs')or not public.has_company_permission(p_company_id,'manage_bi_alerts')then raise exception'No autorizado para corregir costos históricos.';end if;
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to or p_date_to-p_date_from>366 then raise exception'Periodo inválido.';end if;
  if p_unit_cost is null or p_unit_cost<=0 then raise exception'El costo unitario debe ser mayor que cero.';end if;
  if length(trim(coalesce(p_reason,'')))<10 then raise exception'Indica una justificación de al menos 10 caracteres.';end if;
  if p_comparison_mode not in('previous_period','previous_year')then raise exception'Comparación inválida.';end if;
  if not exists(select 1 from public.products where id=p_product_id and company_id=p_company_id)then raise exception'Producto no disponible.';end if;
  select*into v_rule from public.accounting_event_rule_sets where company_id=p_company_id and status='approved';if not found then raise exception'Primero aprueba la matriz contable.';end if;
  select base_currency into v_currency from public.accounting_config_versions where id=v_rule.accounting_config_version_id and status='approved';if v_currency is null then raise exception'Configuración contable no disponible.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':missing-sale-cost:'||p_product_id::text,0));
  insert into public.sale_item_cost_corrections(company_id,product_id,period_from,period_to,unit_cost,cost_method,currency_code,reason,created_by)
  values(p_company_id,p_product_id,p_date_from,p_date_to,round(p_unit_cost,6),v_rule.cost_method,v_currency,trim(p_reason),auth.uid())returning id into v_correction_id;
  with corrected as(
    insert into public.sale_item_cost_correction_lines(correction_id,sale_item_id,unit_cost,cost_amount)
    select v_correction_id,item.id,round(p_unit_cost,6),round(item.quantity*p_unit_cost,6)
    from public.sales sale join public.sale_items item on item.sale_id=sale.id
    where sale.company_id=p_company_id and sale.currency_code=v_currency and item.product_id=p_product_id and item.recognized_cost_amount is null
      and sale.completed_at::date between p_date_from and p_date_to and public.can_access_location(sale.location_id)
      and not exists(select 1 from public.sale_item_cost_correction_lines line where line.sale_item_id=item.id)
      and not exists(select 1 from public.sale_cancellations cancel where cancel.sale_id=sale.id)
    returning sale_item_id,cost_amount
  )select count(*),coalesce(sum(item.quantity),0)into v_count,v_quantity from corrected join public.sale_items item on item.id=corrected.sale_item_id;
  if v_count=0 then raise exception'No quedan partidas sin costo para este producto y periodo.';end if;
  perform public.write_sales_audit(p_company_id,'bi.missing_sale_cost_corrected','sale_item_cost_corrections',v_correction_id,jsonb_build_object('product_id',p_product_id,'date_from',p_date_from,'date_to',p_date_to,'unit_cost',p_unit_cost,'item_count',v_count,'quantity',v_quantity,'reason',trim(p_reason),'document_mutated',false));
  v_eval:=public.bi_evaluate_company_alerts(p_company_id,coalesce(p_evaluation_from,p_date_from),coalesce(p_evaluation_to,p_date_to),p_comparison_mode,auth.uid());
  return jsonb_build_object('correction_id',v_correction_id,'corrected_item_count',v_count,'corrected_quantity',v_quantity,'evaluation',v_eval);
end$$;

create or replace function public.sale_margin_coverage(p_company_id uuid,p_date_from date,p_date_to date,p_currency_code text,p_location_id uuid default null,p_product_id uuid default null,p_customer_id uuid default null)
returns table(net_sales numeric,recognized_cost numeric,gross_margin numeric,item_count bigint,costed_item_count bigint,missing_cost_item_count bigint)
language sql stable security definer set search_path=public as $$
  with scoped as(
    select si.taxable_amount,public.bi_effective_sale_item_cost(si.id,si.recognized_cost_amount)effective_cost
    from public.sales s join public.sale_items si on si.sale_id=s.id
    where s.company_id=p_company_id and s.currency_code=p_currency_code and s.completed_at::date between p_date_from and p_date_to
      and public.can_access_location(s.location_id)and(p_location_id is null or s.location_id=p_location_id)and(p_product_id is null or si.product_id=p_product_id)
      and(p_customer_id is null or s.customer_id=p_customer_id)and not exists(select 1 from public.sale_cancellations sc where sc.sale_id=s.id)
  )select coalesce(sum(taxable_amount),0),coalesce(sum(effective_cost),0),case when count(*)filter(where effective_cost is null)=0 then coalesce(sum(taxable_amount-effective_cost),0)end,
    count(*),count(effective_cost),count(*)filter(where effective_cost is null)from scoped;
$$;

revoke all on function public.bi_list_missing_cost_products(uuid,date,date,integer,integer)from public,anon;
revoke all on function public.bi_apply_missing_sale_cost(uuid,uuid,date,date,numeric,text,text,date,date)from public,anon;
grant execute on function public.bi_list_missing_cost_products(uuid,date,date,integer,integer)to authenticated;
grant execute on function public.bi_apply_missing_sale_cost(uuid,uuid,date,date,numeric,text,text,date,date)to authenticated;
notify pgrst,'reload schema';
