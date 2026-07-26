-- El trigger comparte dos tablas con columnas distintas; separamos sus ramas
-- para que aprobar una incidencia no intente leer campos de una ausencia.

create or replace function public.ensure_collaborator_payroll_editable()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_movement_id uuid:=coalesce(new.id,old.id);v_time_off_id uuid:=coalesce(new.id,old.id);
begin
  if tg_table_name='payroll_movements' then
    if exists(
      select 1 from public.payroll_period_line_concepts c
      join public.payroll_period_lines l on l.id=c.payroll_period_line_id
      join public.payroll_periods p on p.id=l.payroll_period_id
      where c.payroll_movement_id=v_movement_id and p.status in ('approved','paid')
    ) then raise exception 'El movimiento pertenece a una nómina aprobada o pagada; registra un ajuste en otro periodo.'; end if;
  elsif tg_table_name='collaborator_time_off' then
    if exists(
      select 1 from public.payroll_periods p
      where p.company_id=coalesce(new.company_id,old.company_id) and p.status in ('approved','paid')
        and daterange(p.starts_on,p.ends_on,'[]') && daterange(coalesce(new.starts_on,old.starts_on),coalesce(new.ends_on,old.ends_on),'[]')
    ) then raise exception 'La ausencia cruza una nómina aprobada o pagada; registra un ajuste en otro periodo.'; end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;
