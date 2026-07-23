-- M4D2 · Clasificación contable comprensible y automática.
-- Reutiliza accounting_accounts, los campos históricos de gasto y la matriz M4B.

begin;

create table public.accounting_expense_category_versions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  category_id uuid not null,
  version integer not null check(version>0),
  code text not null check(nullif(trim(code),'') is not null and length(code)<=80),
  display_name text not null check(nullif(trim(display_name),'') is not null and length(display_name)<=240),
  account_id uuid not null,
  status text not null check(status in ('active','inactive')),
  valid_from date not null,
  valid_to date,
  change_reason text not null check(nullif(trim(change_reason),'') is not null),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  unique(company_id,category_id,version),
  foreign key(company_id,account_id) references public.accounting_accounts(company_id,id) on delete restrict,
  check(valid_to is null or valid_to>=valid_from)
);
create unique index accounting_expense_category_current_uidx
  on public.accounting_expense_category_versions(company_id,category_id) where valid_to is null;
create unique index accounting_expense_category_code_current_uidx
  on public.accounting_expense_category_versions(company_id,lower(code)) where valid_to is null;
create index accounting_expense_category_lookup_idx
  on public.accounting_expense_category_versions(company_id,category_id,valid_from desc);

alter table public.supplier_invoice_expense_lines
  add column expense_category_id uuid,
  add column expense_category_version_id uuid references public.accounting_expense_category_versions(id) on delete restrict,
  add column resolved_account_id uuid,
  add column classification_reason text,
  add foreign key(company_id,resolved_account_id) references public.accounting_accounts(company_id,id) on delete restrict;

alter table public.accounting_journal_lines
  add column expense_category_version_id uuid references public.accounting_expense_category_versions(id) on delete restrict;

create index supplier_expense_classification_pending_idx
  on public.supplier_invoice_expense_lines(company_id,expense_category, supplier_invoice_id,id)
  where expense_category_version_id is null;
create index supplier_expense_classification_trace_idx
  on public.supplier_invoice_expense_lines(expense_category_version_id,supplier_invoice_id,id)
  where expense_category_version_id is not null;

create or replace function public.guard_accounting_account_history()
returns trigger language plpgsql set search_path=public as $$
declare v_used boolean;
begin
  if tg_op='DELETE' then
    if exists(select 1 from public.accounting_journal_lines where account_id=old.id) then
      raise exception 'Una cuenta utilizada nunca puede eliminarse.';
    end if;
    return old;
  end if;
  if new.company_id<>old.company_id then raise exception 'La cuenta no puede cambiar de empresa.';end if;
  select exists(select 1 from public.accounting_journal_lines where account_id=old.id) into v_used;
  if v_used and (
    new.account_type is distinct from old.account_type or
    new.normal_balance is distinct from old.normal_balance or
    new.parent_id is distinct from old.parent_id or
    new.level is distinct from old.level
  ) then
    raise exception 'La cuenta ya tiene movimientos; tipo, naturaleza, nivel y estructura son históricos.';
  end if;
  return new;
end $$;
drop trigger if exists accounting_accounts_history_guard on public.accounting_accounts;
create trigger accounting_accounts_history_guard before update or delete on public.accounting_accounts
for each row execute function public.guard_accounting_account_history();

create or replace function public.save_accounting_account(
  p_company_id uuid,p_account_id uuid,p_code text,p_name text,p_account_type text,p_normal_balance text,
  p_parent_id uuid,p_level integer,p_accepts_posting boolean,p_is_active boolean,p_reason text,
  p_expected_updated_at timestamptz,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_account public.accounting_accounts%rowtype;v_previous jsonb;v_replay jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting') then raise exception 'No autorizado para administrar el catálogo contable.';end if;
  if nullif(trim(p_code),'') is null or length(trim(p_code))>80 or nullif(trim(p_name),'') is null or length(trim(p_name))>240 then raise exception 'Código y nombre de cuenta son obligatorios.';end if;
  if p_account_type not in ('asset','liability','equity','revenue','expense','memorandum') or p_normal_balance not in ('debit','credit') or coalesce(p_level,0) not between 1 and 20 then raise exception 'La clasificación de la cuenta es inválida.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null or p_client_request_id is null then raise exception 'Motivo y referencia idempotente son obligatorios.';end if;
  if p_parent_id=p_account_id then raise exception 'Una cuenta no puede depender de sí misma.';end if;
  if p_parent_id is not null and not exists(select 1 from public.accounting_accounts where id=p_parent_id and company_id=p_company_id) then raise exception 'La cuenta padre no pertenece a esta empresa.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,92));
  select to_jsonb(a) into v_replay from public.audit_log l join public.accounting_accounts a on a.id=l.entity_id where l.company_id=p_company_id and l.action='accounting.account_saved' and l.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replay is not null then return v_replay||jsonb_build_object('idempotent',true);end if;
  if p_account_id is null then
    insert into public.accounting_accounts(company_id,code,name,account_type,normal_balance,parent_id,level,accepts_posting,is_active)
    values(p_company_id,trim(p_code),trim(p_name),p_account_type,p_normal_balance,p_parent_id,p_level,coalesce(p_accepts_posting,true),coalesce(p_is_active,true))
    returning * into v_account;
  else
    select * into v_account from public.accounting_accounts where id=p_account_id and company_id=p_company_id for update;
    if not found then raise exception 'Cuenta no disponible.';end if;
    if p_expected_updated_at is null or v_account.updated_at<>p_expected_updated_at then raise exception 'La cuenta cambió mientras la editabas.';end if;
    v_previous:=to_jsonb(v_account);
    update public.accounting_accounts set
      code=trim(p_code),name=trim(p_name),account_type=p_account_type,normal_balance=p_normal_balance,
      parent_id=p_parent_id,level=p_level,accepts_posting=coalesce(p_accepts_posting,true),
      is_active=coalesce(p_is_active,true)
    where id=p_account_id returning * into v_account;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'accounting.account_saved','accounting_account',v_account.id,
    jsonb_build_object('request_id',p_client_request_id,'reason',trim(p_reason),'previous',v_previous,'current',to_jsonb(v_account),'origin','manual'));
  return to_jsonb(v_account)||jsonb_build_object('idempotent',false);
end $$;

create unique index audit_expense_category_request_uidx
  on public.audit_log(company_id,action,(metadata->>'request_id'))
  where action='accounting.expense_category_versioned' and metadata?'request_id';

create or replace function public.save_accounting_expense_category(
  p_company_id uuid,p_category_id uuid,p_code text,p_display_name text,p_account_id uuid,
  p_status text,p_valid_from date,p_reason text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_category uuid:=coalesce(p_category_id,gen_random_uuid());v_current public.accounting_expense_category_versions%rowtype;v_new public.accounting_expense_category_versions%rowtype;v_replay jsonb;v_version int;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'configure_accounting') then raise exception 'No autorizado para administrar categorías contables.';end if;
  if p_client_request_id is null or nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Motivo y referencia idempotente son obligatorios.';end if;
  if nullif(trim(coalesce(p_code,'')),'') is null or nullif(trim(coalesce(p_display_name,'')),'') is null or p_status not in ('active','inactive') or p_valid_from is null then raise exception 'Código, nombre, estado y vigencia son obligatorios.';end if;
  if not exists(select 1 from public.accounting_accounts where id=p_account_id and company_id=p_company_id and account_type='expense' and accepts_posting and is_active) then raise exception 'Selecciona una cuenta de gasto afectable y activa.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||':'||v_category::text,151));
  select to_jsonb(c) into v_replay from public.audit_log l join public.accounting_expense_category_versions c on c.id=l.entity_id where l.company_id=p_company_id and l.action='accounting.expense_category_versioned' and l.metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replay is not null then return v_replay||jsonb_build_object('idempotent',true);end if;
  select * into v_current from public.accounting_expense_category_versions where company_id=p_company_id and category_id=v_category and valid_to is null for update;
  if found then
    if p_valid_from<=v_current.valid_from then raise exception 'La nueva vigencia debe iniciar después de la versión actual.';end if;
    update public.accounting_expense_category_versions set valid_to=p_valid_from-1 where id=v_current.id;
    v_version:=v_current.version+1;
  else
    if p_category_id is not null and exists(select 1 from public.accounting_expense_category_versions where category_id=p_category_id and company_id<>p_company_id) then raise exception 'La categoría pertenece a otra empresa.';end if;
    v_version:=1;
  end if;
  insert into public.accounting_expense_category_versions(company_id,category_id,version,code,display_name,account_id,status,valid_from,change_reason)
  values(p_company_id,v_category,v_version,trim(p_code),trim(p_display_name),p_account_id,p_status,p_valid_from,trim(p_reason))
  returning * into v_new;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'accounting.expense_category_versioned','accounting_expense_category',v_new.id,
    jsonb_build_object('request_id',p_client_request_id,'category_id',v_category,'version',v_version,'previous',case when v_current.id is null then null else to_jsonb(v_current) end,'current',to_jsonb(v_new),'reason',trim(p_reason)));
  return to_jsonb(v_new)||jsonb_build_object('idempotent',false);
end $$;

create unique index audit_expense_category_bulk_request_uidx
  on public.audit_log(company_id,action,(metadata->>'request_id'))
  where action='accounting.expense_category_bulk_assigned' and metadata?'request_id';

create or replace function public.bulk_assign_expense_category(
  p_company_id uuid,p_category_id uuid,p_invoice_id uuid default null,
  p_expense_category_text text default null,p_line_ids uuid[] default null,
  p_limit integer default 1000,p_client_request_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_limit int:=least(greatest(coalesce(p_limit,1000),1),5000);v_updated int:=0;v_remaining bigint:=0;v_result jsonb;v_replay jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'configure_accounting') or public.has_company_permission(p_company_id,'manage_supplier_invoice_drafts')) then raise exception 'No autorizado para clasificar gastos.';end if;
  if p_client_request_id is null or (p_invoice_id is null and p_expense_category_text is null and coalesce(cardinality(p_line_ids),0)=0) then raise exception 'Selector y referencia idempotente son obligatorios.';end if;
  if not exists(select 1 from public.accounting_expense_category_versions where company_id=p_company_id and category_id=p_category_id) then raise exception 'Categoría contable no disponible.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text,152));
  select metadata->'result' into v_replay from public.audit_log where company_id=p_company_id and action='accounting.expense_category_bulk_assigned' and metadata->>'request_id'=p_client_request_id::text limit 1;
  if v_replay is not null then return v_replay||jsonb_build_object('idempotent',true);end if;
  with candidates as (
    select line.id
    from public.supplier_invoice_expense_lines line
    join public.supplier_invoices invoice on invoice.id=line.supplier_invoice_id
    where line.company_id=p_company_id and invoice.status='draft' and invoice.source_kind='expense'
      and (p_invoice_id is null or invoice.id=p_invoice_id)
      and (p_expense_category_text is null or coalesce(line.expense_category,'')=p_expense_category_text)
      and (coalesce(cardinality(p_line_ids),0)=0 or line.id=any(p_line_ids))
      and line.expense_category_id is distinct from p_category_id
    order by line.id
    limit v_limit
    for update of line skip locked
  )
  update public.supplier_invoice_expense_lines line set
    expense_category_id=p_category_id,expense_category_version_id=null,resolved_account_id=null,classification_reason=null
  from candidates where line.id=candidates.id;
  get diagnostics v_updated=row_count;
  select count(*) into v_remaining
  from public.supplier_invoice_expense_lines line join public.supplier_invoices invoice on invoice.id=line.supplier_invoice_id
  where line.company_id=p_company_id and invoice.status='draft' and invoice.source_kind='expense'
    and (p_invoice_id is null or invoice.id=p_invoice_id)
    and (p_expense_category_text is null or coalesce(line.expense_category,'')=p_expense_category_text)
    and (coalesce(cardinality(p_line_ids),0)=0 or line.id=any(p_line_ids))
    and line.expense_category_id is distinct from p_category_id;
  v_result:=jsonb_build_object('updated',v_updated,'remaining',v_remaining,'category_id',p_category_id,'page_size',v_limit);
  insert into public.audit_log(company_id,actor_id,action,entity_type,metadata)
  values(p_company_id,auth.uid(),'accounting.expense_category_bulk_assigned','supplier_invoice_expense_line',
    jsonb_build_object('request_id',p_client_request_id,'selector',jsonb_build_object('invoice_id',p_invoice_id,'expense_category_text',p_expense_category_text,'line_count',coalesce(cardinality(p_line_ids),0)),'result',v_result));
  return v_result||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.list_expense_classification_work(p_company_id uuid,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),200);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'view_accounting') or public.has_company_permission(p_company_id,'view_supplier_invoices')) then raise exception 'No autorizado para consultar clasificación de gastos.';end if;
  with pending as (
    select coalesce(line.expense_category,'') preserved_text,count(*) line_count,count(distinct invoice.id) invoice_count,min(invoice.issued_date) oldest_date
    from public.supplier_invoice_expense_lines line join public.supplier_invoices invoice on invoice.id=line.supplier_invoice_id
    where line.company_id=p_company_id and invoice.status='draft' and invoice.source_kind='expense'
      and not exists(
        select 1 from public.accounting_expense_category_versions category join public.accounting_accounts account on account.id=category.account_id
        where category.company_id=p_company_id and category.category_id=line.expense_category_id and category.status='active'
          and invoice.issued_date between category.valid_from and coalesce(category.valid_to,'infinity'::date)
          and account.is_active and account.accepts_posting and account.account_type='expense'
      )
    group by coalesce(line.expense_category,'')
  ) select count(*) into v_total from pending;
  select coalesce(jsonb_agg(to_jsonb(item) order by item.oldest_date,item.preserved_text),'[]'::jsonb) into v_items
  from (
    select coalesce(line.expense_category,'') preserved_text,count(*) line_count,count(distinct invoice.id) invoice_count,min(invoice.issued_date) oldest_date
    from public.supplier_invoice_expense_lines line join public.supplier_invoices invoice on invoice.id=line.supplier_invoice_id
    where line.company_id=p_company_id and invoice.status='draft' and invoice.source_kind='expense'
      and not exists(
        select 1 from public.accounting_expense_category_versions category join public.accounting_accounts account on account.id=category.account_id
        where category.company_id=p_company_id and category.category_id=line.expense_category_id and category.status='active'
          and invoice.issued_date between category.valid_from and coalesce(category.valid_to,'infinity'::date)
          and account.is_active and account.accepts_posting and account.account_type='expense'
      )
    group by coalesce(line.expense_category,'')
    order by oldest_date,preserved_text limit v_size offset (v_page-1)*v_size
  ) item;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.resolve_expense_invoice_classification()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_missing int;v_trace jsonb;
begin
  if old.status=new.status or new.status<>'confirmed' or new.document_type<>'invoice' or new.source_kind<>'expense' then return new;end if;
  select count(*) into v_missing
  from public.supplier_invoice_expense_lines line
  where line.supplier_invoice_id=new.id and not exists(
    select 1 from public.accounting_expense_category_versions category join public.accounting_accounts account on account.id=category.account_id
    where category.company_id=new.company_id and category.category_id=line.expense_category_id and category.status='active'
      and new.issued_date between category.valid_from and coalesce(category.valid_to,'infinity'::date)
      and account.company_id=new.company_id and account.is_active and account.accepts_posting and account.account_type='expense'
  );
  if v_missing>0 then raise exception 'Clasificación pendiente: % concepto(s) no tienen categoría contable vigente; no se infirió por descripción, proveedor ni clave SAT.',v_missing;end if;
  with resolved as (
    select line.id,category.id category_version_id,category.account_id,
      format('%s · %s → %s',category.code,category.display_name,account.name) reason
    from public.supplier_invoice_expense_lines line
    join lateral(
      select value.* from public.accounting_expense_category_versions value
      where value.company_id=new.company_id and value.category_id=line.expense_category_id and value.status='active'
        and new.issued_date between value.valid_from and coalesce(value.valid_to,'infinity'::date)
      order by value.valid_from desc limit 1
    ) category on true
    join public.accounting_accounts account on account.id=category.account_id and account.company_id=new.company_id
    where line.supplier_invoice_id=new.id
  )
  update public.supplier_invoice_expense_lines line set expense_category_version_id=resolved.category_version_id,
    resolved_account_id=resolved.account_id,classification_reason=resolved.reason
  from resolved where line.id=resolved.id;
  select jsonb_agg(jsonb_build_object('line_id',line.id,'category_version_id',line.expense_category_version_id,'account_id',line.resolved_account_id,'reason',line.classification_reason) order by line.line_number)
  into v_trace from public.supplier_invoice_expense_lines line where line.supplier_invoice_id=new.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(new.company_id,auth.uid(),'supplier_expense_invoice.classified','supplier_invoice',new.id,jsonb_build_object('lines',v_trace,'basis','explicit category valid on issued_date'));
  return new;
end $$;
drop trigger if exists supplier_invoices_resolve_expense_classification on public.supplier_invoices;
create trigger supplier_invoices_resolve_expense_classification before update of status on public.supplier_invoices
for each row execute function public.resolve_expense_invoice_classification();

create or replace function public.build_expense_accounting_lines(p_invoice_id uuid,p_target_amount numeric,p_side text)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_lines jsonb;
begin
  if p_side not in ('debit','credit') or coalesce(p_target_amount,0)<=0 then raise exception 'Importe o naturaleza inválida para clasificar gasto.';end if;
  with weights as (
    select line.resolved_account_id account_id,line.expense_category_version_id,category.code,category.display_name,
      sum((line.subtotal-line.discount_amount)*invoice.exchange_rate) weight
    from public.supplier_invoice_expense_lines line
    join public.supplier_invoices invoice on invoice.id=line.supplier_invoice_id
    join public.accounting_expense_category_versions category on category.id=line.expense_category_version_id
    where line.supplier_invoice_id=p_invoice_id and line.resolved_account_id is not null and line.expense_category_version_id is not null
    group by line.resolved_account_id,line.expense_category_version_id,category.code,category.display_name
  ), shares as (
    select *,row_number() over(order by code,expense_category_version_id) rn,count(*) over() n,
      round(p_target_amount*weight/nullif(sum(weight) over(),0),6) rounded
    from weights where weight>0
  ), adjusted as (
    select *,case when rn=n then round(p_target_amount-coalesce(sum(rounded) over(order by rn rows between unbounded preceding and 1 preceding),0),6) else rounded end amount
    from shares
  )
  select jsonb_agg(jsonb_build_object(
    'account_id',account_id,'expense_category_version_id',expense_category_version_id,
    'role',null,'debit',case when p_side='debit' then amount else 0 end,
    'credit',case when p_side='credit' then amount else 0 end,
    'description',code||' · '||display_name
  ) order by rn) into v_lines from adjusted where amount>0;
  if coalesce(jsonb_array_length(v_lines),0)=0 then raise exception 'La factura no conserva clasificación contable resoluble.';end if;
  return v_lines;
end $$;

create or replace function public.post_pending_accounting_event(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare v_event public.accounting_events%rowtype;v_set public.accounting_event_rule_sets%rowtype;v_period public.accounting_periods%rowtype;v_entry public.accounting_journal_entries%rowtype;v_line record;v_account uuid;v_debit numeric:=0;v_credit numeric:=0;v_number int:=0;
begin
  select * into v_event from public.accounting_events where id=p_event_id for update;
  if not found then raise exception 'Evento contable no disponible.';end if;
  if v_event.status='posted' then return to_jsonb(v_event)||jsonb_build_object('idempotent',true);end if;
  select * into v_set from public.accounting_event_rule_sets where company_id=v_event.company_id and status='approved';if not found then return to_jsonb(v_event)||jsonb_build_object('waiting_for_matrix',true);end if;
  select * into v_period from public.accounting_periods where company_id=v_event.company_id and v_event.accounting_date between starts_on and ends_on for update;
  if not found or v_period.status<>'open' then raise exception 'El evento pertenece a un periodo inexistente o cerrado.';end if;
  if jsonb_array_length(v_event.requested_lines)<2 or jsonb_array_length(v_event.requested_lines)>1000 then raise exception 'El evento no contiene partidas válidas.';end if;
  for v_line in select * from jsonb_to_recordset(v_event.requested_lines)x(role text,account_id uuid,expense_category_version_id uuid,debit numeric,credit numeric,description text) loop
    if coalesce(v_line.debit,0)<0 or coalesce(v_line.credit,0)<0 or (coalesce(v_line.debit,0)>0)=(coalesce(v_line.credit,0)>0) then raise exception 'Partida operativa inválida.';end if;
    if v_line.account_id is not null then
      select id into v_account from public.accounting_accounts where id=v_line.account_id and company_id=v_event.company_id and accepts_posting;
      if v_account is null then raise exception 'La clasificación directa no pertenece a la empresa.';end if;
      if v_line.expense_category_version_id is not null and not exists(select 1 from public.accounting_expense_category_versions where id=v_line.expense_category_version_id and company_id=v_event.company_id and account_id=v_account) then raise exception 'La categoría no respalda la cuenta solicitada.';end if;
    else
      v_account:=public.resolve_accounting_event_role(v_set.id,v_line.role);
      if v_account is null then raise exception 'La matriz no resuelve el rol %.',v_line.role;end if;
    end if;
    v_debit:=v_debit+coalesce(v_line.debit,0);v_credit:=v_credit+coalesce(v_line.credit,0);
  end loop;
  if round(v_debit-v_credit,6)<>0 then raise exception 'El evento no cumple doble entrada.';end if;
  insert into public.accounting_journal_entries(company_id,period_id,entry_number,entry_date,description,source_type,status,immutable,client_request_id,accounting_event_id)
  values(v_event.company_id,v_period.id,nextval('public.accounting_entry_number_seq'),v_event.accounting_date,coalesce(nullif(v_event.payload->>'description',''),v_event.event_type),'operational_event','draft',false,v_event.id,v_event.id) returning * into v_entry;
  for v_line in select * from jsonb_to_recordset(v_event.requested_lines)x(role text,account_id uuid,expense_category_version_id uuid,debit numeric,credit numeric,description text) loop
    v_number:=v_number+1;
    v_account:=coalesce(v_line.account_id,public.resolve_accounting_event_role(v_set.id,v_line.role));
    insert into public.accounting_journal_lines(company_id,journal_entry_id,line_number,account_id,expense_category_version_id,description,debit,credit)
    values(v_event.company_id,v_entry.id,v_number,v_account,v_line.expense_category_version_id,v_line.description,coalesce(v_line.debit,0),coalesce(v_line.credit,0));
  end loop;
  update public.accounting_journal_entries set status='posted',immutable=true,posted_by=auth.uid(),posted_at=now(),
    content_sha256=encode(digest((select jsonb_agg(to_jsonb(line) order by line_number)::text from public.accounting_journal_lines line where journal_entry_id=v_entry.id),'sha256'),'hex')
  where id=v_entry.id;
  update public.accounting_events set status='posted',rule_set_id=v_set.id,journal_entry_id=v_entry.id,posted_at=now() where id=v_event.id returning * into v_event;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(v_event.company_id,auth.uid(),'accounting.operational_event_posted','accounting_event',v_event.id,jsonb_build_object('event_type',v_event.event_type,'source_type',v_event.source_entity_type,'source_id',v_event.source_entity_id,'journal_entry_id',v_entry.id));
  return to_jsonb(v_event)||jsonb_build_object('idempotent',false);
end $$;

create or replace function public.capture_exact_accounting_reversal(
  p_company_id uuid,p_original_event_type text,p_reversal_event_type text,
  p_source_entity_type text,p_source_entity_id uuid,p_accounting_date date,
  p_occurred_at timestamptz,p_description text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_original public.accounting_events%rowtype;v_lines jsonb;v_result jsonb;
begin
  select * into v_original from public.accounting_events where company_id=p_company_id and event_type=p_original_event_type and source_entity_type=p_source_entity_type and source_entity_id=p_source_entity_id and status='posted' order by source_version desc limit 1;
  if not found then raise exception 'No existe contabilización original para revertir.';end if;
  select jsonb_agg(jsonb_build_object(
    'role',line->>'role','account_id',line->>'account_id','expense_category_version_id',line->>'expense_category_version_id',
    'debit',coalesce((line->>'credit')::numeric,0),'credit',coalesce((line->>'debit')::numeric,0),
    'description',coalesce(nullif(line->>'description',''),p_description)
  ) order by ordinal) into v_lines from jsonb_array_elements(v_original.requested_lines) with ordinality as x(line,ordinal);
  v_result:=public.capture_accounting_event(p_company_id,p_reversal_event_type,p_source_entity_type,p_source_entity_id,1,p_accounting_date,p_occurred_at,v_lines,jsonb_build_object('description',p_description,'reverses_event_id',v_original.id));
  update public.accounting_events set original_event_id=v_original.id where id=(v_result->>'id')::uuid and original_event_id is null;
  return v_result;
end $$;

create or replace function public.capture_supplier_invoice_accounting_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_net numeric;v_tax numeric;v_withholding numeric;v_total numeric;v_received numeric:=0;v_variance numeric;v_lines jsonb;v_original_type text;v_origin public.supplier_invoices%rowtype;
begin
  if (tg_op='UPDATE' and old.status=new.status) or not public.accounting_operational_matrix_active(new.company_id) then return new;end if;
  if new.status='reversed' then
    v_original_type:=case when new.document_type='credit_note' then 'supplier_credit_note_confirmed' else 'supplier_invoice_confirmed' end;
    perform public.capture_exact_accounting_reversal(new.company_id,v_original_type,case when new.document_type='credit_note' then 'supplier_credit_note_reversed' else 'supplier_invoice_reversed' end,'supplier_invoice',new.id,new.reversed_at::date,new.reversed_at,'Reversa de documento de proveedor');
    return new;
  end if;
  if new.status<>'confirmed' then return new;end if;
  v_net:=round((new.subtotal-new.discount_total)*new.exchange_rate,6);v_tax:=round(new.tax_total*new.exchange_rate,6);v_withholding:=round(coalesce(new.withholding_total,0)*new.exchange_rate,6);v_total:=case when new.base_total>0 then new.base_total else round(new.total*new.exchange_rate,6) end;
  if new.document_type='credit_note' then
    v_lines:=jsonb_build_array(jsonb_build_object('role','accounts_payable','debit',v_total,'credit',0,'description','Aplicación de nota de crédito'));
    if v_withholding>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','withholdings','debit',v_withholding,'credit',0,'description','Reversa de retención'));end if;
    select * into v_origin from public.supplier_invoices where id=new.original_invoice_id;
    if found and v_origin.source_kind='expense' then
      v_lines:=v_lines||public.build_expense_accounting_lines(v_origin.id,v_net,'credit');
    else
      v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','supplier_credit_note_offset','debit',0,'credit',v_net,'description','Nota de crédito'));
    end if;
    if v_tax>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','vat_pending','debit',0,'credit',v_tax,'description','IVA de nota de crédito'));end if;
    perform public.capture_accounting_event(new.company_id,'supplier_credit_note_confirmed','supplier_invoice',new.id,1,new.issued_date,new.confirmed_at,v_lines,jsonb_build_object('description','Nota de crédito confirmada','folio',new.folio,'classification_source_invoice_id',new.original_invoice_id));
    return new;
  end if;
  v_lines:='[]'::jsonb;
  if new.source_kind='receipt' then
    select round(coalesce(sum(line.quantity*line.received_unit_cost),0)*new.exchange_rate,6) into v_received from public.supplier_invoice_lines line where line.supplier_invoice_id=new.id;
    v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','goods_received_not_invoiced','debit',v_received,'credit',0,'description','Recepciones facturadas'));
    v_variance:=round(v_net-v_received,6);
    if v_variance>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','purchase_variance','debit',v_variance,'credit',0,'description','Variación de compra'));
    elsif v_variance<0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','purchase_variance','debit',0,'credit',abs(v_variance),'description','Variación de compra'));end if;
  else
    if new.confirm_request_id is null and not exists(
      select 1 from public.supplier_invoice_expense_lines where supplier_invoice_id=new.id
    ) then
      -- Compatibilidad exclusiva para documentos históricos insertados antes del flujo
      -- transaccional. Toda confirmación RPC nueva lleva confirm_request_id y exige categoría.
      v_lines:=v_lines||jsonb_build_array(jsonb_build_object(
        'role','supplier_expense','debit',v_net,'credit',0,
        'description','Gasto histórico previo a M4D2'
      ));
    else
      v_lines:=v_lines||public.build_expense_accounting_lines(new.id,v_net,'debit');
    end if;
  end if;
  if v_tax>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','vat_pending','debit',v_tax,'credit',0,'description','IVA pendiente de pago'));end if;
  if v_withholding>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','withholdings','debit',0,'credit',v_withholding,'description','Retenciones por pagar'));end if;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('role','accounts_payable','debit',0,'credit',v_total,'description','Cuenta por pagar'));
  perform public.capture_accounting_event(new.company_id,'supplier_invoice_confirmed','supplier_invoice',new.id,1,new.issued_date,new.confirmed_at,v_lines,jsonb_build_object(
    'description','Factura de proveedor confirmada','folio',new.folio,'source_kind',new.source_kind,
    'classification',case when new.source_kind='expense' and new.confirm_request_id is null and not exists(
      select 1 from public.supplier_invoice_expense_lines where supplier_invoice_id=new.id
    ) then 'legacy_pre_m4d2' else 'explicit_expense_category' end
  ));
  return new;
end $$;

alter table public.accounting_expense_category_versions enable row level security;
create policy accounting_expense_categories_read on public.accounting_expense_category_versions
for select to authenticated using(
  public.has_company_permission(company_id,'view_accounting') or
  public.has_company_permission(company_id,'view_supplier_invoices')
);
revoke all on public.accounting_expense_category_versions from anon,authenticated;
grant select on public.accounting_expense_category_versions to authenticated;

revoke all on function public.save_accounting_expense_category(uuid,uuid,text,text,uuid,text,date,text,uuid),
  public.bulk_assign_expense_category(uuid,uuid,uuid,text,uuid[],integer,uuid),
  public.list_expense_classification_work(uuid,integer,integer),
  public.build_expense_accounting_lines(uuid,numeric,text) from public,anon;
grant execute on function public.save_accounting_expense_category(uuid,uuid,text,text,uuid,text,date,text,uuid),
  public.bulk_assign_expense_category(uuid,uuid,uuid,text,uuid[],integer,uuid),
  public.list_expense_classification_work(uuid,integer,integer) to authenticated;
revoke all on function public.build_expense_accounting_lines(uuid,numeric,text) from authenticated;

commit;
