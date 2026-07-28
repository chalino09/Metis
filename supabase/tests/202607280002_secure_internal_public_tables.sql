-- Security Advisor remediation: internal tables stay behind authorized RPCs.
begin;

do $security$
declare
  v_table text;
  v_role text;
begin
  foreach v_table in array array[
    'public.receivable_receipt_sequences',
    'public.collaborator_positions'
  ] loop
    if not coalesce((
      select c.relrowsecurity
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname=split_part(v_table,'.',1)
        and c.relname=split_part(v_table,'.',2)
        and c.relkind in ('r','p')
    ),false) then
      raise exception 'RLS no está habilitado en %.',v_table;
    end if;

    foreach v_role in array array['anon','authenticated'] loop
      if has_table_privilege(v_role,v_table,'select')
        or has_table_privilege(v_role,v_table,'insert')
        or has_table_privilege(v_role,v_table,'update')
        or has_table_privilege(v_role,v_table,'delete') then
        raise exception '% conserva acceso directo a %.',v_role,v_table;
      end if;
    end loop;
  end loop;

  if not exists(
    select 1
    from pg_proc
    where oid='public.record_receivable_payment(uuid,uuid,uuid,numeric,uuid,uuid,text)'::regprocedure
      and prosecdef
  ) or not has_function_privilege(
    'authenticated',
    'public.record_receivable_payment(uuid,uuid,uuid,numeric,uuid,uuid,text)',
    'execute'
  ) then
    raise exception 'La emisión server-side de recibos perdió su contrato seguro.';
  end if;

  if not exists(
    select 1
    from pg_proc
    where oid='public.get_collaborator_position_options(uuid)'::regprocedure
      and prosecdef
  ) or not has_function_privilege(
    'authenticated',
    'public.get_collaborator_position_options(uuid)',
    'execute'
  ) then
    raise exception 'La consulta server-side de puestos perdió su contrato seguro.';
  end if;
end;
$security$;

rollback;
