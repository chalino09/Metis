-- Cobertura granular de migración inicial y revisión versionada de configuración contable.
-- Las versiones aprobadas permanecen inmutables; cualquier cambio nace como una nueva versión.

alter table public.accounting_config_versions
  add column if not exists updated_at timestamptz not null default now();

drop trigger if exists accounting_config_versions_updated_at on public.accounting_config_versions;
create trigger accounting_config_versions_updated_at before update on public.accounting_config_versions
for each row execute function public.set_updated_at();

create unique index if not exists audit_accounting_config_revision_request_uidx
  on public.audit_log(company_id,action,(metadata->>'request_id'))
  where action in ('accounting.config_revision_started','accounting.config_revision_saved') and metadata ? 'request_id';

create or replace function public.start_accounting_config_revision(
  p_company_id uuid,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_current public.accounting_config_versions%rowtype;v_draft public.accounting_config_versions%rowtype;v_version integer;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting') then raise exception 'No autorizado para configurar contabilidad.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'El motivo de la nueva versión es obligatorio.';end if;
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,91));
  select c.* into v_draft from public.audit_log a join public.accounting_config_versions c on c.id=a.entity_id
    where a.company_id=p_company_id and a.action='accounting.config_revision_started' and a.metadata->>'request_id'=p_client_request_id::text limit 1;
  if found then return to_jsonb(v_draft)||jsonb_build_object('idempotent',true);end if;
  select * into v_draft from public.accounting_config_versions where company_id=p_company_id and status='draft' order by version desc limit 1;
  if found then return to_jsonb(v_draft)||jsonb_build_object('idempotent',true,'existing_draft',true);end if;
  select * into v_current from public.accounting_config_versions where company_id=p_company_id and status='approved' for update;
  if not found then raise exception 'No existe una configuración aprobada para versionar.';end if;
  select coalesce(max(version),0)+1 into v_version from public.accounting_config_versions where company_id=p_company_id;
  insert into public.accounting_config_versions(company_id,version,base_currency,cutoff_date,catalog_structure,tax_treatment,responsibilities,change_reason)
  values(p_company_id,v_version,v_current.base_currency,v_current.cutoff_date,v_current.catalog_structure,v_current.tax_treatment,v_current.responsibilities,trim(p_reason)) returning * into v_draft;
  insert into public.accounting_control_accounts(config_version_id,company_id,control_key,account_id)
  select v_draft.id,company_id,control_key,account_id from public.accounting_control_accounts where config_version_id=v_current.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'accounting.config_revision_started','accounting_config_version',v_draft.id,jsonb_build_object('request_id',p_client_request_id,'previous_version',v_current.version,'new_version',v_version,'reason',trim(p_reason)));
  return to_jsonb(v_draft)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.save_accounting_config_revision(
  p_config_id uuid,p_base_currency text,p_cutoff_date date,p_catalog_structure jsonb,
  p_tax_treatment jsonb,p_responsibilities jsonb,p_control_accounts jsonb,p_change_reason text,
  p_expected_updated_at timestamptz,p_client_request_id uuid,p_approve boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_config public.accounting_config_versions%rowtype;v_key text;v_account uuid;v_result jsonb;
begin
  if p_client_request_id is null then raise exception 'Falta la referencia idempotente.';end if;
  select to_jsonb(c) into v_result from public.audit_log a join public.accounting_config_versions c on c.id=a.entity_id
    where c.id=p_config_id and a.action='accounting.config_revision_saved' and a.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_result is not null then return v_result||jsonb_build_object('idempotent',true);end if;
  select * into v_config from public.accounting_config_versions where id=p_config_id for update;
  if not found or auth.uid() is null or not public.has_company_permission(v_config.company_id,'configure_accounting') then raise exception 'Configuración no disponible.';end if;
  if v_config.status<>'draft' then raise exception 'La versión aprobada es inmutable; inicia una nueva versión.';end if;
  if p_expected_updated_at is null or v_config.updated_at<>p_expected_updated_at then raise exception 'La configuración cambió mientras la editabas. Actualiza y vuelve a intentarlo.';end if;
  if upper(trim(coalesce(p_base_currency,'')))!~'^[A-Z]{3}$' or p_cutoff_date is null then raise exception 'Moneda base y fecha de corte son obligatorias.';end if;
  if not (coalesce(p_catalog_structure,'{}') ? 'format') then raise exception 'Declara la estructura del catálogo.';end if;
  if not (coalesce(p_tax_treatment,'{}') ?& array['vat_pending','vat_collected','vat_paid','withholdings']) then raise exception 'Declara el tratamiento completo de IVA y retenciones.';end if;
  if not (coalesce(p_responsibilities,'{}') ?& array['adjustments','close','reopen']) then raise exception 'Declara responsables de ajustes, cierre y reapertura.';end if;
  if nullif(trim(coalesce(p_change_reason,'')),'') is null then raise exception 'El motivo del cambio es obligatorio.';end if;
  if (select count(*) from jsonb_object_keys(coalesce(p_control_accounts,'{}')))<>9 then raise exception 'Asigna las nueve cuentas de control.';end if;
  for v_key,v_account in select key,value::text::uuid from jsonb_each_text(p_control_accounts) loop
    if v_key not in ('accounts_receivable','accounts_payable','inventory','cash','banks','vat_pending','vat_collected','vat_paid','withholdings')
      or not exists(select 1 from public.accounting_accounts where id=v_account and company_id=v_config.company_id and accepts_posting and is_active)
    then raise exception 'Cuenta de control inválida para %.',v_key;end if;
  end loop;
  update public.accounting_config_versions set base_currency=upper(trim(p_base_currency)),cutoff_date=p_cutoff_date,catalog_structure=p_catalog_structure,
    tax_treatment=p_tax_treatment,responsibilities=p_responsibilities,change_reason=trim(p_change_reason) where id=v_config.id returning * into v_config;
  delete from public.accounting_control_accounts where config_version_id=v_config.id;
  for v_key,v_account in select key,value::text::uuid from jsonb_each_text(p_control_accounts) loop
    insert into public.accounting_control_accounts(config_version_id,company_id,control_key,account_id) values(v_config.id,v_config.company_id,v_key,v_account);
  end loop;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_config.company_id,auth.uid(),'accounting.config_revision_saved','accounting_config_version',v_config.id,jsonb_build_object('request_id',p_client_request_id,'version',v_config.version,'reason',trim(p_change_reason),'approve',coalesce(p_approve,false)));
  if coalesce(p_approve,false) then return public.complete_accounting_config(v_config.id,p_control_accounts,p_change_reason);end if;
  return to_jsonb(v_config)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.coverage_check(p_code text,p_label text,p_count bigint)
returns jsonb language sql immutable set search_path=public as $$
  select jsonb_build_object('code',p_code,'label',p_label,'count',coalesce(p_count,0),'status',case when coalesce(p_count,0)>0 then 'ready' else 'pending' end)
$$;

create or replace function public.get_initial_migration_readiness(p_company_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_modules jsonb;v_ready integer;v_total integer;v_files bigint;
begin
  if auth.uid() is null or not public.has_company_access(p_company_id) then raise exception 'Empresa no disponible.';end if;
  select count(*) into v_files from public.import_batches where company_id=p_company_id;
  v_modules:=jsonb_build_array(
    jsonb_build_object('code','company','label','Empresa y acceso','description','Estructura y personas que pueden operar.','href','/satrapy/configuracion/empresa/sucursales','checks',jsonb_build_array(
      public.coverage_check('locations','Sucursales activas',(select count(*) from public.locations where company_id=p_company_id and is_active)),
      public.coverage_check('users','Usuarios vinculados',(select count(distinct user_id) from public.user_roles where company_id=p_company_id))
    )),
    jsonb_build_object('code','inventory','label','Productos e inventario','description','Catálogo, precios y existencias de origen.','href','/satrapy/configuracion/importaciones','checks',jsonb_build_array(
      public.coverage_check('products','Productos canónicos',(select count(*) from public.products where company_id=p_company_id)),
      public.coverage_check('prices','Precios registrados',(select count(*) from public.product_prices pp join public.products p on p.id=pp.product_id where p.company_id=p_company_id)),
      public.coverage_check('snapshots','Cortes de inventario promovidos',(select count(*) from public.inventory_snapshots where company_id=p_company_id and status='completed')),
      public.coverage_check('balances','Existencias con saldo',(select count(*) from public.inventory_balances where company_id=p_company_id and quantity_on_hand<>0))
    )),
    jsonb_build_object('code','sales','label','Ventas y cuentas por cobrar','description','Configuración comercial e historia de clientes.','href','/satrapy/configuracion/ventas','checks',jsonb_build_array(
      public.coverage_check('customers','Clientes',(select count(*) from public.customers where company_id=p_company_id)),
      public.coverage_check('sales','Ventas confirmadas',(select count(*) from public.sales where company_id=p_company_id and status='confirmed')),
      public.coverage_check('receivables','Documentos por cobrar',(select count(*) from public.customer_receivables where company_id=p_company_id)),
      public.coverage_check('payment_methods','Métodos de pago activos',(select count(*) from public.payment_methods where company_id=p_company_id and is_active)),
      public.coverage_check('cash_registers','Cajas activas',(select count(*) from public.cash_registers where company_id=p_company_id and is_active))
    )),
    jsonb_build_object('code','purchasing','label','Compras y cuentas por pagar','description','Proveedores, documentos, cuentas y pagos.','href','/satrapy/configuracion/importaciones','checks',jsonb_build_array(
      public.coverage_check('suppliers','Proveedores',(select count(*) from public.suppliers where company_id=p_company_id)),
      public.coverage_check('purchase_orders','Órdenes de compra',(select count(*) from public.purchase_orders where company_id=p_company_id)),
      public.coverage_check('payables','Documentos por pagar',(select count(*) from public.accounts_payable where company_id=p_company_id)),
      public.coverage_check('paying_accounts','Cuentas pagadoras activas',(select count(*) from public.supplier_paying_accounts where company_id=p_company_id and is_active)),
      public.coverage_check('supplier_payments','Pagos confirmados',(select count(*) from public.supplier_payments where company_id=p_company_id and status='confirmed'))
    )),
    jsonb_build_object('code','accounting','label','Contabilidad','description','Configuración, catálogo, periodos y automatización.','href','/satrapy/contabilidad/configuracion','checks',jsonb_build_array(
      public.coverage_check('accounting_config','Configuración aprobada',(select count(*) from public.accounting_config_versions where company_id=p_company_id and status='approved')),
      public.coverage_check('accounts','Cuentas contables',(select count(*) from public.accounting_accounts where company_id=p_company_id and is_active)),
      public.coverage_check('periods','Periodos creados',(select count(*) from public.accounting_periods where company_id=p_company_id)),
      public.coverage_check('journals','Pólizas contabilizadas',(select count(*) from public.accounting_journal_entries where company_id=p_company_id and status='posted')),
      public.coverage_check('event_rules','Reglas contables aprobadas',(select count(*) from public.accounting_event_rule_sets where company_id=p_company_id and status='approved'))
    )),
    jsonb_build_object('code','banking','label','Bancos y conciliación','description','Cuentas, estados, movimientos y evidencia conciliada.','href','/satrapy/contabilidad/bancos','checks',jsonb_build_array(
      public.coverage_check('financial_accounts','Cuentas financieras activas',(select count(*) from public.financial_accounts where company_id=p_company_id and is_active)),
      public.coverage_check('statements','Estados bancarios promovidos',(select count(*) from public.bank_statement_batches where company_id=p_company_id and status='promoted')),
      public.coverage_check('transactions','Movimientos bancarios',(select count(*) from public.bank_transactions where company_id=p_company_id)),
      public.coverage_check('reconciliations','Conciliaciones confirmadas',(select count(*) from public.bank_reconciliations where company_id=p_company_id and status='confirmed'))
    ))
  );
  select count(*) filter(where c->>'status'='ready'),count(*) into v_ready,v_total
  from jsonb_array_elements(v_modules) m cross join lateral jsonb_array_elements(m->'checks') c;
  return jsonb_build_object('observed_at',now(),'files',v_files,'ready_checks',v_ready,'total_checks',v_total,'modules',v_modules,
    'steps',(select jsonb_agg(jsonb_build_object('code',m->>'code','label',m->>'label','description',m->>'description','href',m->>'href','count',(select count(*) from jsonb_array_elements(m->'checks') c where c->>'status'='ready'),'ready',not exists(select 1 from jsonb_array_elements(m->'checks') c where c->>'status'<>'ready'))) from jsonb_array_elements(v_modules)m));
end $$;

revoke all on function public.start_accounting_config_revision(uuid,text,uuid) from public,anon;
revoke all on function public.save_accounting_config_revision(uuid,text,date,jsonb,jsonb,jsonb,jsonb,text,timestamptz,uuid,boolean) from public,anon;
revoke all on function public.coverage_check(text,text,bigint) from public,anon,authenticated;
grant execute on function public.start_accounting_config_revision(uuid,text,uuid) to authenticated;
grant execute on function public.save_accounting_config_revision(uuid,text,date,jsonb,jsonb,jsonb,jsonb,text,timestamptz,uuid,boolean) to authenticated;
