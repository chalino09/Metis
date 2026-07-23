do $$
begin
  if (
    select count(*) from public.supplier_invoice_expense_lines
    where supplier_invoice_id='4d200000-0000-4000-8000-000000000007'
      and expense_category_id='4d200000-0000-4000-8000-000000000004'
  )<>2000 then
    raise exception 'La asignación concurrente no cubrió exactamente 2,000 líneas.';
  end if;
  if (
    select count(*) from public.audit_log
    where company_id='4d200000-0000-4000-8000-000000000001'
      and action='accounting.expense_category_bulk_assigned'
  )<>2 then
    raise exception 'La asignación concurrente no produjo exactamente dos lotes auditados.';
  end if;
end
$$;
