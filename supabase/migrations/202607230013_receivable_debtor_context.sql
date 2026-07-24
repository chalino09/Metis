-- CxC uses a compact, permissioned debtor snapshot. It keeps the customer master
-- canonical while avoiding client-side joins and per-field reads during collection.
create or replace function public.get_receivable_customer_context(
  p_company_id uuid,
  p_customer_id uuid
) returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare
  v_customer public.customers%rowtype;
  v_summary jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_customer_credit') then
    raise exception 'No autorizado para consultar cuentas por cobrar.';
  end if;

  select * into v_customer
  from public.customers
  where id=p_customer_id and company_id=p_company_id and is_active;

  if not found then
    raise exception 'Cliente no encontrado.';
  end if;

  select jsonb_build_object(
    'document_count',count(*),
    'outstanding_amount',coalesce(sum(outstanding_amount),0),
    'overdue_count',count(*) filter(where due_date<current_date),
    'overdue_amount',coalesce(sum(outstanding_amount) filter(where due_date<current_date),0),
    'next_due_date',min(due_date)
  ) into v_summary
  from public.customer_receivables
  where company_id=p_company_id and customer_id=p_customer_id and outstanding_amount>0;

  return jsonb_build_object(
    'customer',jsonb_build_object(
      'id',v_customer.id,
      'code',v_customer.code,
      'display_name',v_customer.display_name,
      'tax_id',v_customer.tax_id,
      'payment_manager',v_customer.payment_manager,
      'credit_term_days',v_customer.credit_term_days
    ),
    'contact',coalesce((
      select jsonb_build_object(
        'id',c.id,'display_name',c.display_name,'role_name',c.role_name,
        'phone',c.phone,'email',c.email,'is_primary',c.is_primary
      )
      from public.customer_contacts c
      where c.company_id=p_company_id and c.customer_id=p_customer_id
      order by c.is_primary desc,c.created_at,c.id
      limit 1
    ),'null'::jsonb),
    'address',coalesce((
      select jsonb_build_object(
        'id',a.id,'label',a.label,'address_line',a.address_line,
        'neighborhood',a.neighborhood,'municipality',a.municipality,
        'state_name',a.state_name,'postal_code',a.postal_code,'is_primary',a.is_primary
      )
      from public.customer_addresses a
      where a.company_id=p_company_id and a.customer_id=p_customer_id
      order by a.is_primary desc,a.created_at,a.id
      limit 1
    ),'null'::jsonb),
    'summary',coalesce(v_summary,'{}'::jsonb)
  );
end $$;

revoke all on function public.get_receivable_customer_context(uuid,uuid) from public;
grant execute on function public.get_receivable_customer_context(uuid,uuid) to authenticated;
