-- Satrapy · M3E2: pagos confirmados y aplicaciones contra CxP.
-- El pago nace de una propuesta aprobada. Confirmar reduce únicamente CxP;
-- revertir restaura exactamente esas aplicaciones. No crea REP ni conciliación.

insert into public.permissions(code,description) values
  ('manage_supplier_paying_accounts','Administrar cuentas bancarias pagadoras sin credenciales.'),
  ('view_supplier_payments','Consultar pagos y aplicaciones a proveedores.'),
  ('confirm_supplier_payments','Confirmar pagos desde propuestas aprobadas.'),
  ('reverse_supplier_payments','Revertir pagos a proveedores con motivo auditado.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'manage_supplier_paying_accounts','view_supplier_payments','confirm_supplier_payments','reverse_supplier_payments'
) on conflict do nothing;

create table public.supplier_paying_accounts(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  bank_name text not null check(nullif(trim(bank_name),'') is not null),
  alias text not null check(nullif(trim(alias),'') is not null),
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  account_last4 text not null check(account_last4~'^[0-9A-Z]{4}$'),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index supplier_paying_accounts_alias_uidx on public.supplier_paying_accounts(company_id,lower(alias));
create index supplier_paying_accounts_catalog_idx on public.supplier_paying_accounts(company_id,is_active,currency_code,alias);
create trigger supplier_paying_accounts_updated_at before update on public.supplier_paying_accounts for each row execute function public.set_updated_at();

create table public.supplier_payments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  proposal_id uuid not null unique references public.supplier_payment_proposals(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  paying_account_id uuid not null references public.supplier_paying_accounts(id) on delete restrict,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  effective_date date not null,
  payment_method text not null check(nullif(trim(payment_method),'') is not null),
  reference text not null check(nullif(trim(reference),'') is not null),
  total_amount numeric(18,6) not null check(total_amount>0),
  status text not null default 'confirmed' check(status in ('confirmed','reversed')),
  reconciliation_status text not null default 'unreconciled' check(reconciliation_status='unreconciled'),
  confirmed_at timestamptz not null default now(),
  confirmed_by uuid references auth.users(id) on delete set null default auth.uid(),
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversal_reason text,
  created_at timestamptz not null default now(),
  check((status='reversed')=(reversed_at is not null)),
  check(status<>'reversed' or nullif(trim(coalesce(reversal_reason,'')),'') is not null)
);
create index supplier_payments_inbox_idx on public.supplier_payments(company_id,status,effective_date desc,id desc);
create index supplier_payments_supplier_idx on public.supplier_payments(company_id,supplier_id,currency_code,effective_date desc,id desc);

create table public.supplier_payment_applications(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  payment_id uuid not null references public.supplier_payments(id) on delete restrict,
  accounts_payable_id uuid not null references public.accounts_payable(id) on delete restrict,
  supplier_invoice_id uuid not null references public.supplier_invoices(id) on delete restrict,
  amount numeric(18,6) not null check(amount>0),
  balance_before numeric(18,6) not null check(balance_before>=amount),
  balance_after numeric(18,6) not null check(balance_after=round(balance_before-amount,6)),
  applied_at timestamptz not null default now(),
  unique(payment_id,accounts_payable_id)
);
create index supplier_payment_applications_payable_idx on public.supplier_payment_applications(company_id,accounts_payable_id,payment_id);

create table public.supplier_payment_requests(
  company_id uuid not null references public.companies(id) on delete cascade,
  request_id uuid not null,
  payment_id uuid not null references public.supplier_payments(id) on delete restrict,
  operation text not null check(operation in ('confirm','reverse')),
  result jsonb not null,
  actor_id uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  primary key(company_id,request_id)
);

create or replace function public.guard_supplier_payment_application_immutable()
returns trigger language plpgsql set search_path=public as $$
begin
  raise exception 'Las aplicaciones confirmadas son inmutables.';
end $$;
create trigger supplier_payment_applications_immutable before update or delete on public.supplier_payment_applications for each row execute function public.guard_supplier_payment_application_immutable();

alter table public.supplier_paying_accounts enable row level security;
alter table public.supplier_payments enable row level security;
alter table public.supplier_payment_applications enable row level security;
alter table public.supplier_payment_requests enable row level security;

create policy supplier_paying_accounts_read on public.supplier_paying_accounts for select to authenticated using(
  public.has_company_permission(company_id,'manage_supplier_paying_accounts') or public.has_company_permission(company_id,'confirm_supplier_payments')
);
create policy supplier_payments_read on public.supplier_payments for select to authenticated using(public.has_company_permission(company_id,'view_supplier_payments'));
create policy supplier_payment_applications_read on public.supplier_payment_applications for select to authenticated using(public.has_company_permission(company_id,'view_supplier_payments'));
-- Escrituras e idempotencia quedan exclusivamente detrás de RPC security definer.

create or replace function public.save_supplier_paying_account(
  p_company_id uuid,p_account_id uuid,p_bank_name text,p_alias text,p_currency_code text,p_account_last4 text,p_is_active boolean default true
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_account public.supplier_paying_accounts%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_paying_accounts') then raise exception 'No autorizado para administrar cuentas pagadoras.';end if;
  if nullif(trim(coalesce(p_bank_name,'')),'') is null or nullif(trim(coalesce(p_alias,'')),'') is null then raise exception 'Banco y alias son obligatorios.';end if;
  if upper(trim(coalesce(p_currency_code,'')))!~'^[A-Z]{3}$' then raise exception 'Moneda inválida.';end if;
  if upper(trim(coalesce(p_account_last4,'')))!~'^[0-9A-Z]{4}$' then raise exception 'Captura únicamente los últimos cuatro caracteres de la cuenta.';end if;
  if p_account_id is null then
    insert into public.supplier_paying_accounts(company_id,bank_name,alias,currency_code,account_last4,is_active)
    values(p_company_id,trim(p_bank_name),trim(p_alias),upper(trim(p_currency_code)),upper(trim(p_account_last4)),coalesce(p_is_active,true)) returning * into v_account;
  else
    update public.supplier_paying_accounts set bank_name=trim(p_bank_name),alias=trim(p_alias),currency_code=upper(trim(p_currency_code)),account_last4=upper(trim(p_account_last4)),is_active=coalesce(p_is_active,true),updated_by=auth.uid()
    where id=p_account_id and company_id=p_company_id returning * into v_account;
    if not found then raise exception 'Cuenta pagadora no disponible.';end if;
  end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),case when p_account_id is null then 'supplier_paying_account.created' else 'supplier_paying_account.updated' end,'supplier_paying_account',v_account.id,jsonb_build_object('bank_name',v_account.bank_name,'alias',v_account.alias,'currency_code',v_account.currency_code,'account_last4',v_account.account_last4,'is_active',v_account.is_active));
  return to_jsonb(v_account)||jsonb_build_object('masked_ending','•••• '||v_account.account_last4);
exception when unique_violation then raise exception 'Ya existe una cuenta pagadora con ese alias.';
end $$;

create or replace function public.search_supplier_paying_accounts(p_company_id uuid,p_currency_code text default null,p_active_only boolean default false)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_items jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'manage_supplier_paying_accounts') or public.has_company_permission(p_company_id,'confirm_supplier_payments')) then raise exception 'No autorizado para consultar cuentas pagadoras.';end if;
  select coalesce(jsonb_agg(to_jsonb(a)||jsonb_build_object('masked_ending','•••• '||a.account_last4) order by a.is_active desc,a.alias,a.id),'[]'::jsonb) into v_items
  from public.supplier_paying_accounts a where a.company_id=p_company_id and (p_currency_code is null or a.currency_code=upper(trim(p_currency_code))) and (not coalesce(p_active_only,false) or a.is_active);
  return jsonb_build_object('items',v_items);
end $$;

create or replace function public.confirm_supplier_payment(
  p_company_id uuid,p_proposal_id uuid,p_paying_account_id uuid,p_effective_date date,p_payment_method text,p_reference text,p_client_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.supplier_payment_requests%rowtype;v_proposal public.supplier_payment_proposals%rowtype;v_account public.supplier_paying_accounts%rowtype;v_payment uuid;v_line record;v_total numeric:=0;v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_supplier_payments') then raise exception 'No autorizado para confirmar pagos.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  if p_effective_date is null or nullif(trim(coalesce(p_payment_method,'')),'') is null or nullif(trim(coalesce(p_reference,'')),'') is null then raise exception 'Fecha efectiva, forma de pago y referencia son obligatorias.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then
    if v_existing.operation<>'confirm' then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;
    return v_existing.result||jsonb_build_object('idempotent',true);
  end if;
  select * into v_proposal from public.supplier_payment_proposals where id=p_proposal_id and company_id=p_company_id for update;
  if not found or v_proposal.status<>'approved' then raise exception 'Sólo una propuesta aprobada puede convertirse en pago.';end if;
  if exists(select 1 from public.supplier_payments where proposal_id=p_proposal_id) then raise exception 'La propuesta ya tiene un pago registrado.';end if;
  select * into v_account from public.supplier_paying_accounts where id=p_paying_account_id and company_id=p_company_id for update;
  if not found or not v_account.is_active then raise exception 'Cuenta pagadora activa no disponible.';end if;
  if v_account.currency_code<>v_proposal.currency_code then raise exception 'La cuenta pagadora y la propuesta deben tener la misma moneda.';end if;
  v_payment:=gen_random_uuid();
  insert into public.supplier_payments(id,company_id,proposal_id,supplier_id,paying_account_id,currency_code,effective_date,payment_method,reference,total_amount)
  values(v_payment,p_company_id,p_proposal_id,v_proposal.supplier_id,v_account.id,v_proposal.currency_code,p_effective_date,trim(p_payment_method),trim(p_reference),v_proposal.total_proposed);
  for v_line in
    select l.accounts_payable_id,l.proposed_amount,ap.supplier_invoice_id,ap.company_id,ap.supplier_id,ap.currency_code,ap.outstanding_amount,ap.reversed_at
    from public.supplier_payment_proposal_lines l join public.accounts_payable ap on ap.id=l.accounts_payable_id
    where l.proposal_id=p_proposal_id order by ap.id for update of ap
  loop
    if v_line.company_id<>p_company_id or v_line.supplier_id<>v_proposal.supplier_id or v_line.currency_code<>v_proposal.currency_code then raise exception 'Todas las aplicaciones deben conservar empresa, proveedor y moneda.';end if;
    if v_line.reversed_at is not null then raise exception 'No se puede aplicar contra una CxP revertida.';end if;
    if v_line.outstanding_amount<v_line.proposed_amount then raise exception 'El pago excede el saldo actual de una CxP.';end if;
    insert into public.supplier_payment_applications(company_id,payment_id,accounts_payable_id,supplier_invoice_id,amount,balance_before,balance_after)
    values(p_company_id,v_payment,v_line.accounts_payable_id,v_line.supplier_invoice_id,v_line.proposed_amount,v_line.outstanding_amount,round(v_line.outstanding_amount-v_line.proposed_amount,6));
    update public.accounts_payable set outstanding_amount=round(outstanding_amount-v_line.proposed_amount,6) where id=v_line.accounts_payable_id;
    v_total:=v_total+v_line.proposed_amount;
  end loop;
  if v_total<=0 or round(v_total,6)<>round(v_proposal.total_proposed,6) then raise exception 'Las aplicaciones no concilian con la propuesta aprobada.';end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'supplier_payment.confirmed','supplier_payment',v_payment,jsonb_build_object('proposal_id',p_proposal_id,'supplier_id',v_proposal.supplier_id,'currency_code',v_proposal.currency_code,'total_amount',v_total,'effective_date',p_effective_date,'paying_account_id',v_account.id,'reference',trim(p_reference),'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',v_payment,'proposal_id',p_proposal_id,'status','confirmed','reconciliation_status','unreconciled','total_amount',round(v_total,6),'idempotent',false);
  insert into public.supplier_payment_requests(company_id,request_id,payment_id,operation,result) values(p_company_id,p_client_request_id,v_payment,'confirm',v_result);
  return v_result;
end $$;

create or replace function public.reverse_supplier_payment(p_company_id uuid,p_payment_id uuid,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_existing public.supplier_payment_requests%rowtype;v_payment public.supplier_payments%rowtype;v_application record;v_result jsonb;v_now timestamptz:=clock_timestamp();
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'reverse_supplier_payments') then raise exception 'No autorizado para revertir pagos.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La reversa requiere motivo.';end if;
  if p_client_request_id is null then raise exception 'La operación requiere llave de idempotencia.';end if;
  perform pg_advisory_xact_lock(hashtextextended(p_company_id::text||p_client_request_id::text,0));
  select * into v_existing from public.supplier_payment_requests where company_id=p_company_id and request_id=p_client_request_id;
  if found then
    if v_existing.operation<>'reverse' or v_existing.payment_id<>p_payment_id then raise exception 'La llave de idempotencia pertenece a otra operación.';end if;
    return v_existing.result||jsonb_build_object('idempotent',true);
  end if;
  select * into v_payment from public.supplier_payments where id=p_payment_id and company_id=p_company_id for update;
  if not found or v_payment.status<>'confirmed' then raise exception 'Pago confirmado no disponible para reversa.';end if;
  for v_application in
    select a.accounts_payable_id,a.amount,ap.original_amount,ap.outstanding_amount,ap.reversed_at
    from public.supplier_payment_applications a join public.accounts_payable ap on ap.id=a.accounts_payable_id
    where a.payment_id=p_payment_id order by ap.id for update of ap
  loop
    if v_application.reversed_at is not null then raise exception 'No se puede restaurar una CxP revertida.';end if;
    if round(v_application.outstanding_amount+v_application.amount,6)>v_application.original_amount then raise exception 'La reversa excedería el saldo original de una CxP.';end if;
    update public.accounts_payable set outstanding_amount=round(outstanding_amount+v_application.amount,6) where id=v_application.accounts_payable_id;
  end loop;
  update public.supplier_payments set status='reversed',reversed_at=v_now,reversed_by=auth.uid(),reversal_reason=trim(p_reason) where id=p_payment_id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata)
  values(p_company_id,auth.uid(),'supplier_payment.reversed','supplier_payment',p_payment_id,jsonb_build_object('reason',trim(p_reason),'total_amount',v_payment.total_amount,'client_request_id',p_client_request_id));
  v_result:=jsonb_build_object('id',p_payment_id,'status','reversed','restored_amount',v_payment.total_amount,'idempotent',false);
  insert into public.supplier_payment_requests(company_id,request_id,payment_id,operation,result) values(p_company_id,p_client_request_id,p_payment_id,'reverse',v_result);
  return v_result;
end $$;

create or replace function public.search_supplier_payments(
  p_company_id uuid,p_query text default null,p_status text default null,p_supplier_id uuid default null,p_currency_code text default null,p_page integer default 1,p_page_size integer default 25
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_payments') then raise exception 'No autorizado para consultar pagos.';end if;
  if p_status is not null and p_status not in ('confirmed','reversed') then raise exception 'Estado de pago inválido.';end if;
  select count(*) into v_total from public.supplier_payments p join public.suppliers s on s.id=p.supplier_id where p.company_id=p_company_id and (p_status is null or p.status=p_status) and (p_supplier_id is null or p.supplier_id=p_supplier_id) and (p_currency_code is null or p.currency_code=upper(trim(p_currency_code))) and (v_query='' or lower(p.reference) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%');
  select coalesce(jsonb_agg(to_jsonb(x) order by x.effective_date desc,x.id desc),'[]'::jsonb) into v_items from (
    select p.id,p.proposal_id,p.supplier_id,s.code supplier_code,s.display_name supplier_name,p.currency_code,p.effective_date,p.payment_method,p.reference,p.total_amount,p.status,p.reconciliation_status,p.confirmed_at,p.reversed_at,a.alias account_alias,a.bank_name,'•••• '||a.account_last4 masked_ending,count(pa.id) application_count
    from public.supplier_payments p join public.suppliers s on s.id=p.supplier_id join public.supplier_paying_accounts a on a.id=p.paying_account_id left join public.supplier_payment_applications pa on pa.payment_id=p.id
    where p.company_id=p_company_id and (p_status is null or p.status=p_status) and (p_supplier_id is null or p.supplier_id=p_supplier_id) and (p_currency_code is null or p.currency_code=upper(trim(p_currency_code))) and (v_query='' or lower(p.reference) like '%'||v_query||'%' or lower(s.code) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%')
    group by p.id,s.id,a.id order by p.effective_date desc,p.id desc limit v_size offset(v_page-1)*v_size
  )x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.get_supplier_payment_detail(p_company_id uuid,p_payment_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_payments') then raise exception 'No autorizado para consultar pagos.';end if;
  select to_jsonb(p)||jsonb_build_object(
    'supplier',jsonb_build_object('id',s.id,'code',s.code,'display_name',s.display_name),
    'paying_account',jsonb_build_object('id',a.id,'bank_name',a.bank_name,'alias',a.alias,'currency_code',a.currency_code,'masked_ending','•••• '||a.account_last4),
    'applications',(select coalesce(jsonb_agg(to_jsonb(pa)||jsonb_build_object('invoice_number',concat_ws('-',si.series,si.folio),'due_date',ap.due_date,'current_balance',ap.outstanding_amount) order by ap.due_date,pa.id),'[]'::jsonb) from public.supplier_payment_applications pa join public.accounts_payable ap on ap.id=pa.accounts_payable_id join public.supplier_invoices si on si.id=pa.supplier_invoice_id where pa.payment_id=p.id),
    'audit',(select coalesce(jsonb_agg(to_jsonb(al) order by al.created_at,al.id),'[]'::jsonb) from public.audit_log al where al.company_id=p_company_id and al.entity_type='supplier_payment' and al.entity_id=p.id)
  ) into v_result from public.supplier_payments p join public.suppliers s on s.id=p.supplier_id join public.supplier_paying_accounts a on a.id=p.paying_account_id where p.id=p_payment_id and p.company_id=p_company_id;
  if v_result is null then raise exception 'Pago no encontrado.';end if;
  return v_result;
end $$;

create or replace function public.get_supplier_payment_by_proposal(p_company_id uuid,p_proposal_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_payment uuid;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_payments') then raise exception 'No autorizado para consultar pagos.';end if;
  select id into v_payment from public.supplier_payments where company_id=p_company_id and proposal_id=p_proposal_id;
  if v_payment is null then return null;end if;
  return public.get_supplier_payment_detail(p_company_id,v_payment);
end $$;

revoke all on table public.supplier_paying_accounts,public.supplier_payments,public.supplier_payment_applications,public.supplier_payment_requests from anon,authenticated;
grant select on table public.supplier_paying_accounts,public.supplier_payments,public.supplier_payment_applications to authenticated;
revoke all on function public.save_supplier_paying_account(uuid,uuid,text,text,text,text,boolean) from public;
revoke all on function public.search_supplier_paying_accounts(uuid,text,boolean) from public;
revoke all on function public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid) from public;
revoke all on function public.reverse_supplier_payment(uuid,uuid,text,uuid) from public;
revoke all on function public.search_supplier_payments(uuid,text,text,uuid,text,integer,integer) from public;
revoke all on function public.get_supplier_payment_detail(uuid,uuid) from public;
revoke all on function public.get_supplier_payment_by_proposal(uuid,uuid) from public;
grant execute on function public.save_supplier_paying_account(uuid,uuid,text,text,text,text,boolean) to authenticated;
grant execute on function public.search_supplier_paying_accounts(uuid,text,boolean) to authenticated;
grant execute on function public.confirm_supplier_payment(uuid,uuid,uuid,date,text,text,uuid) to authenticated;
grant execute on function public.reverse_supplier_payment(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.search_supplier_payments(uuid,text,text,uuid,text,integer,integer) to authenticated;
grant execute on function public.get_supplier_payment_detail(uuid,uuid) to authenticated;
grant execute on function public.get_supplier_payment_by_proposal(uuid,uuid) to authenticated;
