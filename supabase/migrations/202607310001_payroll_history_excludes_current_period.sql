-- El historial contiene periodos anteriores; la corrida vigente se presenta por separado.

create or replace function public.search_payroll_periods(
  p_company_id uuid,p_page integer default 1,p_page_size integer default 50
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_frequency text;v_start date;v_end date;v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_collaborators') then
    raise exception 'No autorizado.';
  end if;
  select coalesce((select payment_frequency from public.payroll_schedules where company_id=p_company_id),'weekly')
  into v_frequency;
  select starts_on,ends_on into v_start,v_end
  from public.payroll_period_bounds(v_frequency,current_date);
  with filtered as materialized(
    select p.*,
      coalesce((select sum(total_pay) from public.payroll_period_lines l where l.payroll_period_id=p.id),0) total_pay,
      coalesce((select count(*) from public.payroll_period_lines l where l.payroll_period_id=p.id),0) collaborator_count
    from public.payroll_periods p
    where p.company_id=p_company_id
      and not (p.payment_frequency=v_frequency and p.starts_on=v_start and p.ends_on=v_end)
  ),paged as(
    select * from filtered order by starts_on desc,id desc limit v_size offset (v_page-1)*v_size
  )
  select
    (select count(*) from filtered),
    coalesce(jsonb_agg(to_jsonb(paged) order by starts_on desc,id desc),'[]'::jsonb)
  into v_total,v_items from paged;
  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',coalesce(v_total,0))
  );
end $$;
