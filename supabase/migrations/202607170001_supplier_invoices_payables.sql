-- Satrapy · Módulo 3D: factura de proveedor y cuentas por pagar.
-- Sólo las recepciones operativas confirmadas sustentan facturas. Este módulo no crea pagos
-- y ninguna de sus operaciones modifica inventario, movimientos o costos.

insert into public.permissions(code,description) values
  ('view_supplier_invoices','Consultar facturas de proveedor.'),
  ('manage_supplier_invoice_drafts','Crear y editar borradores de factura de proveedor.'),
  ('confirm_supplier_invoices','Confirmar facturas de proveedor y crear CxP.'),
  ('authorize_supplier_invoice_differences','Autorizar diferencias documentales con motivo auditado.'),
  ('reverse_supplier_invoices','Revertir facturas de proveedor con motivo auditado.'),
  ('manage_supplier_credit_notes','Crear y confirmar notas de crédito ligadas a una factura.'),
  ('view_accounts_payable','Consultar cuentas por pagar.')
on conflict(code) do update set description=excluded.description;

insert into public.role_permissions(role_id,permission_id)
select r.id,p.id from public.roles r cross join public.permissions p
where r.code in ('super_admin','direccion_admin') and p.code in (
  'view_supplier_invoices','manage_supplier_invoice_drafts','confirm_supplier_invoices',
  'authorize_supplier_invoice_differences','reverse_supplier_invoices',
  'manage_supplier_credit_notes','view_accounts_payable'
) on conflict do nothing;

create table public.supplier_invoices(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  purchase_order_id uuid references public.purchase_orders(id) on delete restrict,
  document_type text not null default 'invoice' check(document_type in ('invoice','credit_note')),
  original_invoice_id uuid references public.supplier_invoices(id) on delete restrict,
  status text not null default 'draft' check(status in ('draft','confirmed','reversed')),
  series text,
  folio text not null check(length(trim(folio))>0),
  fiscal_uuid text,
  issued_date date not null,
  due_date date not null,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  supplier_reference text,
  subtotal numeric(18,6) not null default 0 check(subtotal>=0),
  discount_total numeric(18,6) not null default 0 check(discount_total>=0),
  tax_total numeric(18,6) not null default 0 check(tax_total>=0),
  total numeric(18,6) not null default 0 check(total>=0),
  differences jsonb not null default '[]'::jsonb check(jsonb_typeof(differences)='array'),
  differences_authorized_at timestamptz,
  differences_authorized_by uuid references auth.users(id) on delete set null,
  differences_authorization_reason text,
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users(id) on delete set null,
  confirm_request_id uuid,
  reversed_at timestamptz,
  reversed_by uuid references auth.users(id) on delete set null,
  reversal_reason text,
  reverse_request_id uuid,
  credit_request_id uuid,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(due_date>=issued_date),
  check((document_type='invoice' and original_invoice_id is null and purchase_order_id is not null)
     or (document_type='credit_note' and original_invoice_id is not null)),
  check((status='confirmed')=(confirmed_at is not null) or status='reversed'),
  check((status='reversed')=(reversed_at is not null)),
  unique(company_id,confirm_request_id),
  unique(company_id,reverse_request_id),
  unique(company_id,credit_request_id)
);
create unique index supplier_invoices_fiscal_uuid_uidx on public.supplier_invoices(company_id,supplier_id,lower(fiscal_uuid)) where fiscal_uuid is not null and document_type='invoice';
create unique index supplier_invoices_fallback_uidx on public.supplier_invoices(company_id,supplier_id,lower(coalesce(series,'')),lower(folio),issued_date,total) where fiscal_uuid is null and document_type='invoice';
create index supplier_invoices_catalog_idx on public.supplier_invoices(company_id,document_type,status,issued_date desc,id desc);
create index supplier_invoices_order_idx on public.supplier_invoices(company_id,purchase_order_id,status);
create trigger supplier_invoices_updated_at before update on public.supplier_invoices for each row execute function public.set_updated_at();

create table public.supplier_invoice_lines(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_invoice_id uuid not null references public.supplier_invoices(id) on delete cascade,
  purchase_order_line_id uuid not null references public.purchase_order_lines(id) on delete restrict,
  purchase_receipt_line_id uuid not null references public.purchase_receipt_lines(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(18,6) not null check(quantity>0),
  ordered_quantity numeric(18,6) not null check(ordered_quantity>0),
  received_quantity numeric(18,6) not null check(received_quantity>0),
  order_unit_cost numeric(18,6) not null check(order_unit_cost>=0),
  received_unit_cost numeric(18,6) not null check(received_unit_cost>=0),
  invoiced_unit_price numeric(18,6) not null check(invoiced_unit_price>=0),
  order_discount_percent_1 numeric(9,4) not null default 0,
  order_discount_percent_2 numeric(9,4) not null default 0,
  order_discount_percent numeric(9,4) not null default 0,
  invoice_discount_amount numeric(18,6) not null default 0 check(invoice_discount_amount>=0),
  invoice_tax_amount numeric(18,6) not null default 0 check(invoice_tax_amount>=0),
  line_subtotal numeric(18,6) generated always as (round(quantity*invoiced_unit_price,6)) stored,
  line_total numeric(18,6) generated always as (round(quantity*invoiced_unit_price-invoice_discount_amount+invoice_tax_amount,6)) stored,
  differences jsonb not null default '[]'::jsonb check(jsonb_typeof(differences)='array'),
  created_at timestamptz not null default now(),
  unique(supplier_invoice_id,purchase_receipt_line_id)
);
create index supplier_invoice_lines_receipt_idx on public.supplier_invoice_lines(purchase_receipt_line_id,supplier_invoice_id);

create table public.supplier_invoice_receipts(
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_invoice_id uuid not null references public.supplier_invoices(id) on delete cascade,
  purchase_receipt_id uuid not null references public.purchase_receipts(id) on delete restrict,
  primary key(supplier_invoice_id,purchase_receipt_id)
);

create table public.supplier_invoice_exceptions(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  supplier_invoice_id uuid references public.supplier_invoices(id) on delete cascade,
  kind text not null check(kind in ('duplicate_uuid','duplicate_identity','three_way_difference')),
  status text not null default 'pending' check(status in ('pending','resolved')),
  evidence jsonb not null default '{}'::jsonb,
  detected_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users(id) on delete set null,
  resolution_reason text
);
create index supplier_invoice_exceptions_inbox_idx on public.supplier_invoice_exceptions(company_id,status,detected_at desc,id desc);

create table public.accounts_payable(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  supplier_invoice_id uuid not null unique references public.supplier_invoices(id) on delete restrict,
  currency_code text not null check(currency_code~'^[A-Z]{3}$'),
  original_amount numeric(18,6) not null check(original_amount>=0),
  outstanding_amount numeric(18,6) not null check(outstanding_amount>=0),
  issued_date date not null,
  due_date date not null,
  reversed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index accounts_payable_catalog_idx on public.accounts_payable(company_id,due_date,id);
create index accounts_payable_supplier_idx on public.accounts_payable(company_id,supplier_id,due_date,id);
create trigger accounts_payable_updated_at before update on public.accounts_payable for each row execute function public.set_updated_at();

create table public.accounts_payable_adjustments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  accounts_payable_id uuid not null references public.accounts_payable(id) on delete restrict,
  supplier_invoice_id uuid not null unique references public.supplier_invoices(id) on delete restrict,
  adjustment_type text not null check(adjustment_type in ('credit_note','invoice_reversal')),
  amount numeric(18,6) not null check(amount>0),
  reason text,
  actor_id uuid references auth.users(id) on delete set null default auth.uid(),
  occurred_at timestamptz not null default now()
);

create or replace function public.guard_supplier_invoice_mutation()
returns trigger language plpgsql set search_path=public as $$
begin
  if tg_op='DELETE' and old.status<>'draft' then raise exception 'Una factura confirmada no puede eliminarse.';end if;
  if tg_op='UPDATE' and old.status<>'draft' then
    if new.status=old.status or new.status<>'reversed' then raise exception 'Una factura confirmada es inmutable; utilice reversa auditada.';end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end $$;
create trigger guard_supplier_invoice_mutation before update or delete on public.supplier_invoices for each row execute function public.guard_supplier_invoice_mutation();

create or replace function public.guard_supplier_invoice_line_mutation()
returns trigger language plpgsql set search_path=public as $$
declare v_status text;
begin
  select status into v_status from public.supplier_invoices where id=coalesce(new.supplier_invoice_id,old.supplier_invoice_id);
  if v_status is distinct from 'draft' then raise exception 'Las partidas de una factura confirmada son inmutables.';end if;
  return case when tg_op='DELETE' then old else new end;
end $$;
create trigger guard_supplier_invoice_line_mutation before insert or update or delete on public.supplier_invoice_lines for each row execute function public.guard_supplier_invoice_line_mutation();

create or replace function public.block_invoiced_receipt_reversal()
returns trigger language plpgsql set search_path=public as $$
begin
  if old.status='confirmed' and new.status='reversed' and exists(
    select 1 from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id
    join public.purchase_receipt_lines prl on prl.id=sil.purchase_receipt_line_id
    where prl.purchase_receipt_id=old.id and si.status='confirmed'
  ) then raise exception 'La recepción tiene cantidades facturadas; revierta primero la factura.';end if;
  return new;
end $$;
create trigger block_invoiced_receipt_reversal before update of status on public.purchase_receipts for each row execute function public.block_invoiced_receipt_reversal();

alter table public.supplier_invoices enable row level security;
alter table public.supplier_invoice_lines enable row level security;
alter table public.supplier_invoice_receipts enable row level security;
alter table public.supplier_invoice_exceptions enable row level security;
alter table public.accounts_payable enable row level security;
alter table public.accounts_payable_adjustments enable row level security;
create policy supplier_invoices_read on public.supplier_invoices for select to authenticated using(public.has_company_permission(company_id,'view_supplier_invoices'));
create policy supplier_invoice_lines_read on public.supplier_invoice_lines for select to authenticated using(public.has_company_permission(company_id,'view_supplier_invoices'));
create policy supplier_invoice_receipts_read on public.supplier_invoice_receipts for select to authenticated using(public.has_company_permission(company_id,'view_supplier_invoices'));
create policy supplier_invoice_exceptions_read on public.supplier_invoice_exceptions for select to authenticated using(public.has_company_permission(company_id,'view_supplier_invoices'));
create policy accounts_payable_read on public.accounts_payable for select to authenticated using(public.has_company_permission(company_id,'view_accounts_payable'));
create policy accounts_payable_adjustments_read on public.accounts_payable_adjustments for select to authenticated using(public.has_company_permission(company_id,'view_accounts_payable'));

create or replace function public.invoice_line_differences(p_received_cost numeric,p_invoice_price numeric,p_discount numeric,p_tax numeric,p_currency text,p_order_currency text)
returns jsonb language sql immutable as $$
  select coalesce(jsonb_agg(x),'[]'::jsonb) from (
    select jsonb_build_object('kind','unit_price','received',p_received_cost,'invoice',p_invoice_price) x where p_invoice_price<>p_received_cost
    union all select jsonb_build_object('kind','discount','received',0,'invoice',p_discount) where p_discount<>0
    union all select jsonb_build_object('kind','tax','received',0,'invoice',p_tax) where p_tax<>0
    union all select jsonb_build_object('kind','currency','order',p_order_currency,'invoice',p_currency) where p_currency<>p_order_currency
  ) d
$$;

create or replace function public.save_supplier_invoice(
  p_company_id uuid,p_invoice_id uuid,p_supplier_id uuid,p_purchase_order_id uuid,p_series text,p_folio text,
  p_fiscal_uuid text,p_issued_date date,p_due_date date,p_currency_code text,p_supplier_reference text,
  p_lines jsonb,p_client_request_id uuid default null,p_expected_updated_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_invoice public.supplier_invoices%rowtype;v_order public.purchase_orders%rowtype;v_line jsonb;v_prl record;v_id uuid;v_qty numeric;v_price numeric;v_discount numeric;v_tax numeric;v_diffs jsonb:='[]'::jsonb;v_line_diffs jsonb;v_subtotal numeric:=0;v_discount_total numeric:=0;v_tax_total numeric:=0;v_total numeric:=0;v_duplicate uuid;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_invoice_drafts') then raise exception 'No autorizado para administrar borradores de factura.';end if;
  if nullif(trim(coalesce(p_folio,'')),'') is null or p_issued_date is null or p_due_date is null or p_due_date<p_issued_date or coalesce(p_currency_code,'')!~'^[A-Z]{3}$' then raise exception 'Identidad, fechas o moneda inválidas.';end if;
  if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'La factura requiere partidas recibidas.';end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id for update;
  if not found or v_order.supplier_id<>p_supplier_id or v_order.status<>'approved' or v_order.origin<>'operational' then raise exception 'Sólo una OC operativa aprobada del proveedor puede facturarse.';end if;
  if p_invoice_id is not null then
    select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
    if not found or v_invoice.status<>'draft' or v_invoice.document_type<>'invoice' then raise exception 'Borrador de factura no disponible.';end if;
    if p_expected_updated_at is not null and v_invoice.updated_at<>p_expected_updated_at then raise exception 'El borrador cambió; recargue antes de guardar.';end if;
    v_id:=v_invoice.id;
  else v_id:=gen_random_uuid();end if;
  if nullif(trim(coalesce(p_fiscal_uuid,'')),'') is not null then
    select id into v_duplicate from public.supplier_invoices where company_id=p_company_id and supplier_id=p_supplier_id and document_type='invoice' and id<>v_id and lower(fiscal_uuid)=lower(trim(p_fiscal_uuid)) limit 1;
    if v_duplicate is not null then
      insert into public.supplier_invoice_exceptions(company_id,supplier_id,kind,evidence) values(p_company_id,p_supplier_id,'duplicate_uuid',jsonb_build_object('candidate_invoice_id',v_duplicate,'series',p_series,'folio',p_folio,'fiscal_uuid',p_fiscal_uuid));
      insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.duplicate_blocked','supplier_invoice_exception',v_duplicate,jsonb_build_object('series',p_series,'folio',p_folio,'fiscal_uuid',p_fiscal_uuid));
      return jsonb_build_object('status','exception','kind','duplicate_uuid','duplicate_invoice_id',v_duplicate);
    end if;
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty:=(v_line->>'quantity')::numeric;v_price:=(v_line->>'unit_price')::numeric;v_discount:=coalesce((v_line->>'discount_amount')::numeric,0);v_tax:=coalesce((v_line->>'tax_amount')::numeric,0);
    if v_qty<=0 or v_price<0 or v_discount<0 or v_tax<0 or v_discount>round(v_qty*v_price,6) then raise exception 'Cantidad o importes de factura inválidos.';end if;
    select prl.*,pr.id purchase_receipt_id,pr.status receipt_status,pr.supplier_id receipt_supplier_id,pr.purchase_order_id receipt_order_id,pol.quantity ordered_quantity,pol.unit_cost order_unit_cost,pol.discount_percent_1,pol.discount_percent_2
      into v_prl from public.purchase_receipt_lines prl join public.purchase_receipts pr on pr.id=prl.purchase_receipt_id join public.purchase_order_lines pol on pol.id=prl.purchase_order_line_id
      where prl.id=(v_line->>'purchase_receipt_line_id')::uuid and pr.company_id=p_company_id for update of prl;
    if not found or v_prl.receipt_status<>'confirmed' or v_prl.receipt_supplier_id<>p_supplier_id or v_prl.receipt_order_id<>p_purchase_order_id then raise exception 'Partida ajena o recepción no confirmada.';end if;
    if v_qty>v_prl.quantity-coalesce((select sum(sil.quantity) from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id where sil.purchase_receipt_line_id=v_prl.id and si.status='confirmed'),0) then raise exception 'La cantidad facturada supera lo recibido pendiente de facturar.';end if;
    v_line_diffs:=public.invoice_line_differences(v_prl.unit_cost,v_price,v_discount,v_tax,p_currency_code,v_order.currency_code);
    if jsonb_array_length(v_line_diffs)>0 then v_diffs:=v_diffs||jsonb_build_array(jsonb_build_object('purchase_receipt_line_id',v_prl.id,'differences',v_line_diffs));end if;
    v_subtotal:=v_subtotal+round(v_qty*v_price,6);v_discount_total:=v_discount_total+v_discount;v_tax_total:=v_tax_total+v_tax;v_total:=v_total+round(v_qty*v_price-v_discount+v_tax,6);
  end loop;
  select id into v_duplicate from public.supplier_invoices where company_id=p_company_id and supplier_id=p_supplier_id and document_type='invoice' and id<>v_id and ((p_fiscal_uuid is not null and lower(fiscal_uuid)=lower(trim(p_fiscal_uuid))) or (p_fiscal_uuid is null and fiscal_uuid is null and lower(coalesce(series,''))=lower(coalesce(trim(p_series),'')) and lower(folio)=lower(trim(p_folio)) and issued_date=p_issued_date and total=v_total)) limit 1;
  if v_duplicate is not null then
    insert into public.supplier_invoice_exceptions(company_id,supplier_id,kind,evidence) values(p_company_id,p_supplier_id,case when p_fiscal_uuid is null then 'duplicate_identity' else 'duplicate_uuid' end,jsonb_build_object('candidate_invoice_id',v_duplicate,'series',p_series,'folio',p_folio,'fiscal_uuid',p_fiscal_uuid,'issued_date',p_issued_date,'total',v_total));
    insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.duplicate_blocked','supplier_invoice_exception',v_duplicate,jsonb_build_object('series',p_series,'folio',p_folio,'fiscal_uuid',p_fiscal_uuid,'total',v_total));
    return jsonb_build_object('status','exception','kind',case when p_fiscal_uuid is null then 'duplicate_identity' else 'duplicate_uuid' end,'duplicate_invoice_id',v_duplicate);
  end if;
  if p_invoice_id is null then
    insert into public.supplier_invoices(id,company_id,supplier_id,purchase_order_id,series,folio,fiscal_uuid,issued_date,due_date,currency_code,supplier_reference,subtotal,discount_total,tax_total,total,differences)
    values(v_id,p_company_id,p_supplier_id,p_purchase_order_id,nullif(trim(p_series),''),trim(p_folio),nullif(lower(trim(p_fiscal_uuid)),''),p_issued_date,p_due_date,p_currency_code,nullif(trim(p_supplier_reference),''),v_subtotal,v_discount_total,v_tax_total,v_total,v_diffs);
  else
    delete from public.supplier_invoice_receipts where supplier_invoice_id=v_id;delete from public.supplier_invoice_lines where supplier_invoice_id=v_id;
    update public.supplier_invoices set supplier_id=p_supplier_id,purchase_order_id=p_purchase_order_id,series=nullif(trim(p_series),''),folio=trim(p_folio),fiscal_uuid=nullif(lower(trim(p_fiscal_uuid)),''),issued_date=p_issued_date,due_date=p_due_date,currency_code=p_currency_code,supplier_reference=nullif(trim(p_supplier_reference),''),subtotal=v_subtotal,discount_total=v_discount_total,tax_total=v_tax_total,total=v_total,differences=v_diffs,differences_authorized_at=null,differences_authorized_by=null,differences_authorization_reason=null,updated_by=auth.uid() where id=v_id;
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    select prl.*,pol.quantity ordered_quantity,pol.unit_cost order_unit_cost,pol.discount_percent_1,pol.discount_percent_2
      into v_prl from public.purchase_receipt_lines prl join public.purchase_order_lines pol on pol.id=prl.purchase_order_line_id
      where prl.id=(v_line->>'purchase_receipt_line_id')::uuid;
    v_qty:=(v_line->>'quantity')::numeric;v_price:=(v_line->>'unit_price')::numeric;v_discount:=coalesce((v_line->>'discount_amount')::numeric,0);v_tax:=coalesce((v_line->>'tax_amount')::numeric,0);
    v_line_diffs:=public.invoice_line_differences(v_prl.unit_cost,v_price,v_discount,v_tax,p_currency_code,v_order.currency_code);
    insert into public.supplier_invoice_lines(company_id,supplier_invoice_id,purchase_order_line_id,purchase_receipt_line_id,product_id,quantity,ordered_quantity,received_quantity,order_unit_cost,received_unit_cost,invoiced_unit_price,order_discount_percent_1,order_discount_percent_2,order_discount_percent,invoice_discount_amount,invoice_tax_amount,differences)
    values(p_company_id,v_id,v_prl.purchase_order_line_id,v_prl.id,v_prl.product_id,v_qty,v_prl.ordered_quantity,v_prl.quantity,v_prl.order_unit_cost,v_prl.unit_cost,v_price,v_prl.discount_percent_1,v_prl.discount_percent_2,v_order.order_discount_percent,v_discount,v_tax,v_line_diffs);
    insert into public.supplier_invoice_receipts(company_id,supplier_invoice_id,purchase_receipt_id) values(p_company_id,v_id,v_prl.purchase_receipt_id) on conflict do nothing;
  end loop;
  if jsonb_array_length(v_diffs)>0 then insert into public.supplier_invoice_exceptions(company_id,supplier_id,supplier_invoice_id,kind,evidence) values(p_company_id,p_supplier_id,v_id,'three_way_difference',jsonb_build_object('differences',v_diffs));end if;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),case when p_invoice_id is null then 'supplier_invoice.draft_created' else 'supplier_invoice.draft_updated' end,'supplier_invoice',v_id,jsonb_build_object('purchase_order_id',p_purchase_order_id,'line_count',jsonb_array_length(p_lines),'total',v_total,'client_request_id',v_request));
  return jsonb_build_object('id',v_id,'status','draft','total',v_total,'differences',v_diffs,'updated_at',(select updated_at from public.supplier_invoices where id=v_id));
end $$;

create or replace function public.authorize_supplier_invoice_differences(p_company_id uuid,p_invoice_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_invoice public.supplier_invoices%rowtype;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'authorize_supplier_invoice_differences') then raise exception 'No autorizado para aceptar diferencias.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La autorización requiere motivo.';end if;
  select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
  if not found or v_invoice.status<>'draft' or jsonb_array_length(v_invoice.differences)=0 then raise exception 'Factura sin diferencias autorizables.';end if;
  update public.supplier_invoices set differences_authorized_at=clock_timestamp(),differences_authorized_by=auth.uid(),differences_authorization_reason=trim(p_reason),updated_by=auth.uid() where id=p_invoice_id;
  update public.supplier_invoice_exceptions set status='resolved',resolved_at=clock_timestamp(),resolved_by=auth.uid(),resolution_reason=trim(p_reason) where supplier_invoice_id=p_invoice_id and kind='three_way_difference' and status='pending';
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.differences_authorized','supplier_invoice',p_invoice_id,jsonb_build_object('reason',trim(p_reason),'differences',v_invoice.differences));
  return jsonb_build_object('invoice_id',p_invoice_id,'status','authorized');
end $$;

create or replace function public.confirm_supplier_invoice(p_company_id uuid,p_invoice_id uuid,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_invoice public.supplier_invoices%rowtype;v_order public.purchase_orders%rowtype;v_line record;v_available numeric;v_payable uuid;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_now timestamptz:=clock_timestamp();
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'confirm_supplier_invoices') then raise exception 'No autorizado para confirmar facturas.';end if;
  select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
  if not found then raise exception 'Factura no encontrada.';end if;
  if v_invoice.status='confirmed' and v_invoice.confirm_request_id=v_request then return jsonb_build_object('invoice_id',v_invoice.id,'payable_id',(select id from public.accounts_payable where supplier_invoice_id=v_invoice.id),'status','confirmed','idempotent',true);end if;
  if v_invoice.status<>'draft' then raise exception 'La factura ya fue confirmada o revertida.';end if;
  if jsonb_array_length(v_invoice.differences)>0 and v_invoice.differences_authorized_at is null then raise exception 'Las diferencias requieren autorización explícita y motivo.';end if;
  select * into v_order from public.purchase_orders where id=v_invoice.purchase_order_id and company_id=p_company_id for update;
  if not found or v_order.status<>'approved' or v_order.origin<>'operational' or v_order.supplier_id<>v_invoice.supplier_id or v_order.currency_code<>v_invoice.currency_code and not exists(select 1 from jsonb_array_elements(v_invoice.differences) d where d::text like '%currency%') then raise exception 'La OC ya no es facturable.';end if;
  for v_line in select sil.*,pr.status receipt_status,pr.supplier_id receipt_supplier_id,pr.purchase_order_id receipt_order_id from public.supplier_invoice_lines sil join public.purchase_receipt_lines prl on prl.id=sil.purchase_receipt_line_id join public.purchase_receipts pr on pr.id=prl.purchase_receipt_id where sil.supplier_invoice_id=v_invoice.id order by sil.purchase_receipt_line_id for update of prl loop
    if v_line.receipt_status<>'confirmed' or v_line.receipt_supplier_id<>v_invoice.supplier_id or v_line.receipt_order_id<>v_invoice.purchase_order_id then raise exception 'Recepción no confirmada o ajena a la factura.';end if;
    select v_line.received_quantity-coalesce(sum(sil.quantity),0) into v_available from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id where sil.purchase_receipt_line_id=v_line.purchase_receipt_line_id and si.status='confirmed';
    if v_line.quantity>v_available then raise exception 'La cantidad facturada supera lo recibido pendiente de facturar.';end if;
  end loop;
  update public.supplier_invoices set status='confirmed',confirmed_at=v_now,confirmed_by=auth.uid(),confirm_request_id=v_request,updated_by=auth.uid() where id=v_invoice.id;
  insert into public.accounts_payable(company_id,supplier_id,supplier_invoice_id,currency_code,original_amount,outstanding_amount,issued_date,due_date) values(p_company_id,v_invoice.supplier_id,v_invoice.id,v_invoice.currency_code,v_invoice.total,v_invoice.total,v_invoice.issued_date,v_invoice.due_date) returning id into v_payable;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.confirmed','supplier_invoice',v_invoice.id,jsonb_build_object('purchase_order_id',v_invoice.purchase_order_id,'payable_id',v_payable,'total',v_invoice.total,'client_request_id',v_request));
  return jsonb_build_object('invoice_id',v_invoice.id,'payable_id',v_payable,'status','confirmed','idempotent',false);
end $$;

create or replace function public.reverse_supplier_invoice(p_company_id uuid,p_invoice_id uuid,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_invoice public.supplier_invoices%rowtype;v_payable public.accounts_payable%rowtype;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_now timestamptz:=clock_timestamp();
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'reverse_supplier_invoices') then raise exception 'No autorizado para revertir facturas.';end if;
  if nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'La reversa requiere motivo.';end if;
  select * into v_invoice from public.supplier_invoices where id=p_invoice_id and company_id=p_company_id for update;
  if not found then raise exception 'Factura no encontrada.';end if;
  if v_invoice.status='reversed' and v_invoice.reverse_request_id=v_request then return jsonb_build_object('invoice_id',v_invoice.id,'status','reversed','idempotent',true);end if;
  if v_invoice.status<>'confirmed' or v_invoice.document_type<>'invoice' then raise exception 'Sólo una factura confirmada puede revertirse.';end if;
  select * into v_payable from public.accounts_payable where supplier_invoice_id=v_invoice.id for update;
  if v_payable.outstanding_amount<>v_payable.original_amount then raise exception 'La factura tiene notas de crédito; no puede revertirse directamente.';end if;
  update public.accounts_payable set outstanding_amount=0,reversed_at=v_now where id=v_payable.id;
  insert into public.accounts_payable_adjustments(company_id,accounts_payable_id,supplier_invoice_id,adjustment_type,amount,reason) values(p_company_id,v_payable.id,v_invoice.id,'invoice_reversal',v_invoice.total,trim(p_reason));
  update public.supplier_invoices set status='reversed',reversed_at=v_now,reversed_by=auth.uid(),reversal_reason=trim(p_reason),reverse_request_id=v_request,updated_by=auth.uid() where id=v_invoice.id;
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_invoice.reversed','supplier_invoice',v_invoice.id,jsonb_build_object('payable_id',v_payable.id,'reason',trim(p_reason),'client_request_id',v_request));
  return jsonb_build_object('invoice_id',v_invoice.id,'status','reversed','idempotent',false);
end $$;

create or replace function public.create_supplier_credit_note(p_company_id uuid,p_original_invoice_id uuid,p_series text,p_folio text,p_fiscal_uuid text,p_issued_date date,p_amount numeric,p_reason text,p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_origin public.supplier_invoices%rowtype;v_payable public.accounts_payable%rowtype;v_id uuid;v_request uuid:=coalesce(p_client_request_id,gen_random_uuid());v_now timestamptz:=clock_timestamp();
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'manage_supplier_credit_notes') then raise exception 'No autorizado para crear notas de crédito.';end if;
  if nullif(trim(coalesce(p_folio,'')),'') is null or nullif(trim(coalesce(p_reason,'')),'') is null or coalesce(p_amount,0)<=0 then raise exception 'Folio, importe y motivo son obligatorios.';end if;
  select * into v_origin from public.supplier_invoices where id=p_original_invoice_id and company_id=p_company_id for update;
  if not found or v_origin.status<>'confirmed' or v_origin.document_type<>'invoice' then raise exception 'La nota requiere una factura confirmada como origen.';end if;
  select * into v_payable from public.accounts_payable where supplier_invoice_id=v_origin.id for update;
  if p_amount>v_payable.outstanding_amount then raise exception 'La nota de crédito generaría saldo contrario; requiere otra clasificación.';end if;
  select id into v_id from public.supplier_invoices where company_id=p_company_id and credit_request_id=v_request;
  if v_id is not null then return jsonb_build_object('credit_note_id',v_id,'payable_id',v_payable.id,'status','confirmed','idempotent',true);end if;
  insert into public.supplier_invoices(company_id,supplier_id,document_type,original_invoice_id,status,series,folio,fiscal_uuid,issued_date,due_date,currency_code,supplier_reference,subtotal,total,confirmed_at,confirmed_by,credit_request_id)
  values(p_company_id,v_origin.supplier_id,'credit_note',v_origin.id,'confirmed',nullif(trim(p_series),''),trim(p_folio),nullif(lower(trim(p_fiscal_uuid)),''),p_issued_date,p_issued_date,v_origin.currency_code,trim(p_reason),p_amount,p_amount,v_now,auth.uid(),v_request) returning id into v_id;
  update public.accounts_payable set outstanding_amount=outstanding_amount-p_amount where id=v_payable.id;
  insert into public.accounts_payable_adjustments(company_id,accounts_payable_id,supplier_invoice_id,adjustment_type,amount,reason) values(p_company_id,v_payable.id,v_id,'credit_note',p_amount,trim(p_reason));
  insert into public.audit_log(company_id,actor_id,action,entity_type,entity_id,metadata) values(p_company_id,auth.uid(),'supplier_credit_note.confirmed','supplier_invoice',v_id,jsonb_build_object('original_invoice_id',v_origin.id,'payable_id',v_payable.id,'amount',p_amount,'reason',trim(p_reason),'client_request_id',v_request));
  return jsonb_build_object('credit_note_id',v_id,'payable_id',v_payable.id,'status','confirmed','idempotent',false);
end $$;

create or replace function public.search_invoiceable_receipts(p_company_id uuid,p_query text default null,p_supplier_id uuid default null,p_purchase_order_id uuid default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'view_supplier_invoices') or public.has_company_permission(p_company_id,'manage_supplier_invoice_drafts')) then raise exception 'No autorizado para consultar recepciones facturables.';end if;
  with candidates as (select pr.id,pr.folio receipt_folio,pr.receipt_date,po.id purchase_order_id,po.folio purchase_order_folio,po.currency_code,s.id supplier_id,s.code supplier_code,s.display_name supplier_name from public.purchase_receipts pr join public.purchase_orders po on po.id=pr.purchase_order_id join public.suppliers s on s.id=pr.supplier_id where pr.company_id=p_company_id and pr.status='confirmed' and po.status='approved' and po.origin='operational' and (p_supplier_id is null or s.id=p_supplier_id) and (p_purchase_order_id is null or po.id=p_purchase_order_id) and (v_query='' or lower(pr.folio) like '%'||v_query||'%' or lower(po.folio) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%') and exists(select 1 from public.purchase_receipt_lines prl where prl.purchase_receipt_id=pr.id and prl.quantity>coalesce((select sum(sil.quantity) from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id where sil.purchase_receipt_line_id=prl.id and si.status='confirmed'),0))) select count(*) into v_total from candidates;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.receipt_date,x.id),'[]'::jsonb) into v_items from (select pr.id,pr.folio receipt_folio,pr.receipt_date,po.id purchase_order_id,po.folio purchase_order_folio,po.currency_code,s.id supplier_id,s.code supplier_code,s.display_name supplier_name from public.purchase_receipts pr join public.purchase_orders po on po.id=pr.purchase_order_id join public.suppliers s on s.id=pr.supplier_id where pr.company_id=p_company_id and pr.status='confirmed' and po.status='approved' and po.origin='operational' and (p_supplier_id is null or s.id=p_supplier_id) and (p_purchase_order_id is null or po.id=p_purchase_order_id) and (v_query='' or lower(pr.folio) like '%'||v_query||'%' or lower(po.folio) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%') and exists(select 1 from public.purchase_receipt_lines prl where prl.purchase_receipt_id=pr.id and prl.quantity>coalesce((select sum(sil.quantity) from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id where sil.purchase_receipt_line_id=prl.id and si.status='confirmed'),0)) order by pr.receipt_date,pr.id limit v_size offset (v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.get_invoiceable_purchase_order(p_company_id uuid,p_purchase_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_order public.purchase_orders%rowtype;
begin
  if auth.uid() is null or not (public.has_company_permission(p_company_id,'view_supplier_invoices') or public.has_company_permission(p_company_id,'manage_supplier_invoice_drafts')) then raise exception 'No autorizado para consultar partidas facturables.';end if;
  select * into v_order from public.purchase_orders where id=p_purchase_order_id and company_id=p_company_id and status='approved' and origin='operational';if not found then raise exception 'OC operativa aprobada no encontrada.';end if;
  return jsonb_build_object('purchase_order_id',v_order.id,'folio',v_order.folio,'supplier_id',v_order.supplier_id,'currency_code',v_order.currency_code,'lines',(select coalesce(jsonb_agg(jsonb_build_object('purchase_receipt_line_id',prl.id,'purchase_receipt_id',pr.id,'purchase_receipt_folio',pr.folio,'purchase_order_line_id',pol.id,'line_number',pol.line_number,'product_id',prl.product_id,'description',pol.description,'ordered_quantity',pol.quantity,'received_quantity',prl.quantity,'previously_invoiced',coalesce(x.invoiced,0),'available_quantity',prl.quantity-coalesce(x.invoiced,0),'order_unit_cost',round(pol.unit_cost*(1-pol.discount_percent_1/100)*(1-pol.discount_percent_2/100)*(1-v_order.order_discount_percent/100),6),'received_unit_cost',prl.unit_cost) order by pol.line_number,pr.receipt_date,pr.id),'[]'::jsonb) from public.purchase_receipt_lines prl join public.purchase_receipts pr on pr.id=prl.purchase_receipt_id join public.purchase_order_lines pol on pol.id=prl.purchase_order_line_id left join lateral(select sum(sil.quantity) invoiced from public.supplier_invoice_lines sil join public.supplier_invoices si on si.id=sil.supplier_invoice_id where sil.purchase_receipt_line_id=prl.id and si.status='confirmed')x on true where pr.purchase_order_id=v_order.id and pr.status='confirmed' and prl.quantity>coalesce(x.invoiced,0)));
end $$;

create or replace function public.search_supplier_invoices(p_company_id uuid,p_query text default null,p_status text default null,p_supplier_id uuid default null,p_purchase_order_id uuid default null,p_receipt_id uuid default null,p_date_from date default null,p_date_to date default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_invoices') then raise exception 'No autorizado para consultar facturas.';end if;
  select count(*) into v_total from public.supplier_invoices si join public.suppliers s on s.id=si.supplier_id left join public.purchase_orders po on po.id=si.purchase_order_id where si.company_id=p_company_id and si.document_type='invoice' and (p_status is null or si.status=p_status) and (p_supplier_id is null or si.supplier_id=p_supplier_id) and (p_purchase_order_id is null or si.purchase_order_id=p_purchase_order_id) and (p_receipt_id is null or exists(select 1 from public.supplier_invoice_receipts sir where sir.supplier_invoice_id=si.id and sir.purchase_receipt_id=p_receipt_id)) and (p_date_from is null or si.issued_date>=p_date_from) and (p_date_to is null or si.issued_date<=p_date_to) and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(coalesce(si.fiscal_uuid,'')) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(coalesce(po.folio,'')) like '%'||v_query||'%');
  select coalesce(jsonb_agg(to_jsonb(x) order by x.issued_date desc,x.id desc),'[]'::jsonb) into v_items from (select si.id,si.series,si.folio,si.fiscal_uuid,si.status,si.issued_date,si.due_date,si.currency_code,si.total,si.differences,si.supplier_id,s.display_name supplier_name,si.purchase_order_id,po.folio purchase_order_folio,ap.id payable_id,ap.outstanding_amount from public.supplier_invoices si join public.suppliers s on s.id=si.supplier_id left join public.purchase_orders po on po.id=si.purchase_order_id left join public.accounts_payable ap on ap.supplier_invoice_id=si.id where si.company_id=p_company_id and si.document_type='invoice' and (p_status is null or si.status=p_status) and (p_supplier_id is null or si.supplier_id=p_supplier_id) and (p_purchase_order_id is null or si.purchase_order_id=p_purchase_order_id) and (p_receipt_id is null or exists(select 1 from public.supplier_invoice_receipts sir where sir.supplier_invoice_id=si.id and sir.purchase_receipt_id=p_receipt_id)) and (p_date_from is null or si.issued_date>=p_date_from) and (p_date_to is null or si.issued_date<=p_date_to) and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(coalesce(si.fiscal_uuid,'')) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(coalesce(po.folio,'')) like '%'||v_query||'%') order by si.issued_date desc,si.id desc limit v_size offset (v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.get_supplier_invoice_detail(p_company_id uuid,p_invoice_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_result jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_invoices') then raise exception 'No autorizado para consultar facturas.';end if;
  select to_jsonb(si)||jsonb_build_object('supplier',jsonb_build_object('id',s.id,'code',s.code,'display_name',s.display_name),'purchase_order',case when po.id is null then null else jsonb_build_object('id',po.id,'folio',po.folio,'status',po.status) end,'receipts',(select coalesce(jsonb_agg(jsonb_build_object('id',pr.id,'folio',pr.folio,'status',pr.status,'receipt_date',pr.receipt_date) order by pr.receipt_date,pr.id),'[]'::jsonb) from public.supplier_invoice_receipts sir join public.purchase_receipts pr on pr.id=sir.purchase_receipt_id where sir.supplier_invoice_id=si.id),'lines',(select coalesce(jsonb_agg(to_jsonb(sil)||jsonb_build_object('purchase_receipt_folio',pr.folio,'line_number',pol.line_number,'description',pol.description,'previously_invoiced',coalesce((select sum(x.quantity) from public.supplier_invoice_lines x join public.supplier_invoices xi on xi.id=x.supplier_invoice_id where x.purchase_receipt_line_id=sil.purchase_receipt_line_id and xi.status='confirmed' and xi.id<>si.id),0),'available_quantity',sil.received_quantity-coalesce((select sum(x.quantity) from public.supplier_invoice_lines x join public.supplier_invoices xi on xi.id=x.supplier_invoice_id where x.purchase_receipt_line_id=sil.purchase_receipt_line_id and xi.status='confirmed'),0)) order by pol.line_number,pr.id),'[]'::jsonb) from public.supplier_invoice_lines sil join public.purchase_receipt_lines prl on prl.id=sil.purchase_receipt_line_id join public.purchase_receipts pr on pr.id=prl.purchase_receipt_id join public.purchase_order_lines pol on pol.id=sil.purchase_order_line_id where sil.supplier_invoice_id=si.id),'payable',(select to_jsonb(ap)||jsonb_build_object('is_overdue',ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date<current_date,'condition',case when ap.reversed_at is not null then 'reversed' when ap.outstanding_amount=0 then 'settled' when ap.due_date<current_date then 'overdue' else 'not_due' end,'adjustments',(select coalesce(jsonb_agg(to_jsonb(a) order by a.occurred_at,a.id),'[]'::jsonb) from public.accounts_payable_adjustments a where a.accounts_payable_id=ap.id)) from public.accounts_payable ap where ap.supplier_invoice_id=si.id),'audit',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at,a.id),'[]'::jsonb) from public.audit_log a where a.company_id=p_company_id and (a.entity_id=si.id or a.metadata->>'original_invoice_id'=si.id::text))) into v_result from public.supplier_invoices si join public.suppliers s on s.id=si.supplier_id left join public.purchase_orders po on po.id=si.purchase_order_id where si.id=p_invoice_id and si.company_id=p_company_id;
  if v_result is null then raise exception 'Factura no encontrada.';end if;return v_result;
end $$;

create or replace function public.search_accounts_payable(p_company_id uuid,p_query text default null,p_supplier_id uuid default null,p_purchase_order_id uuid default null,p_receipt_id uuid default null,p_due_condition text default null,p_date_from date default null,p_date_to date default null,p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_query text:=lower(trim(coalesce(p_query,'')));v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_accounts_payable') then raise exception 'No autorizado para consultar CxP.';end if;
  select count(*) into v_total from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id join public.suppliers s on s.id=ap.supplier_id join public.purchase_orders po on po.id=si.purchase_order_id where ap.company_id=p_company_id and (p_supplier_id is null or ap.supplier_id=p_supplier_id) and (p_purchase_order_id is null or si.purchase_order_id=p_purchase_order_id) and (p_receipt_id is null or exists(select 1 from public.supplier_invoice_receipts sir where sir.supplier_invoice_id=si.id and sir.purchase_receipt_id=p_receipt_id)) and (p_date_from is null or ap.issued_date>=p_date_from) and (p_date_to is null or ap.issued_date<=p_date_to) and (p_due_condition is null or p_due_condition='overdue' and ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date<current_date or p_due_condition='not_due' and ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date>=current_date) and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(po.folio) like '%'||v_query||'%');
  select coalesce(jsonb_agg(to_jsonb(x) order by x.due_date,x.id),'[]'::jsonb) into v_items from (select ap.id,ap.supplier_id,s.display_name supplier_name,ap.supplier_invoice_id,concat_ws('-',si.series,si.folio) invoice_number,si.purchase_order_id,po.folio purchase_order_folio,ap.currency_code,ap.original_amount,ap.outstanding_amount,ap.issued_date,ap.due_date,ap.reversed_at,(ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date<current_date) is_overdue,case when ap.reversed_at is not null then 'reversed' when ap.outstanding_amount=0 then 'settled' when ap.due_date<current_date then 'overdue' else 'not_due' end condition from public.accounts_payable ap join public.supplier_invoices si on si.id=ap.supplier_invoice_id join public.suppliers s on s.id=ap.supplier_id join public.purchase_orders po on po.id=si.purchase_order_id where ap.company_id=p_company_id and (p_supplier_id is null or ap.supplier_id=p_supplier_id) and (p_purchase_order_id is null or si.purchase_order_id=p_purchase_order_id) and (p_receipt_id is null or exists(select 1 from public.supplier_invoice_receipts sir where sir.supplier_invoice_id=si.id and sir.purchase_receipt_id=p_receipt_id)) and (p_date_from is null or ap.issued_date>=p_date_from) and (p_date_to is null or ap.issued_date<=p_date_to) and (p_due_condition is null or p_due_condition='overdue' and ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date<current_date or p_due_condition='not_due' and ap.reversed_at is null and ap.outstanding_amount>0 and ap.due_date>=current_date) and (v_query='' or lower(si.folio) like '%'||v_query||'%' or lower(coalesce(si.series,'')) like '%'||v_query||'%' or lower(s.display_name) like '%'||v_query||'%' or lower(po.folio) like '%'||v_query||'%') order by ap.due_date,ap.id limit v_size offset (v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

create or replace function public.list_supplier_invoice_exceptions(p_company_id uuid,p_status text default 'pending',p_page integer default 1,p_page_size integer default 25)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,25),1),100);v_total bigint;v_items jsonb;
begin
  if auth.uid() is null or not public.has_company_permission(p_company_id,'view_supplier_invoices') then raise exception 'No autorizado para consultar excepciones.';end if;
  select count(*) into v_total from public.supplier_invoice_exceptions where company_id=p_company_id and (p_status is null or status=p_status);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.detected_at desc,x.id desc),'[]'::jsonb) into v_items from (select e.*,s.display_name supplier_name,si.folio invoice_folio from public.supplier_invoice_exceptions e join public.suppliers s on s.id=e.supplier_id left join public.supplier_invoices si on si.id=e.supplier_invoice_id where e.company_id=p_company_id and (p_status is null or e.status=p_status) order by e.detected_at desc,e.id desc limit v_size offset (v_page-1)*v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'page_size',v_size,'total',v_total));
end $$;

revoke all on function public.invoice_line_differences(numeric,numeric,numeric,numeric,text,text) from public;
revoke all on function public.save_supplier_invoice(uuid,uuid,uuid,uuid,text,text,text,date,date,text,text,jsonb,uuid,timestamptz) from public;
revoke all on function public.authorize_supplier_invoice_differences(uuid,uuid,text) from public;
revoke all on function public.confirm_supplier_invoice(uuid,uuid,uuid) from public;
revoke all on function public.reverse_supplier_invoice(uuid,uuid,text,uuid) from public;
revoke all on function public.create_supplier_credit_note(uuid,uuid,text,text,text,date,numeric,text,uuid) from public;
revoke all on function public.search_invoiceable_receipts(uuid,text,uuid,uuid,integer,integer) from public;
revoke all on function public.get_invoiceable_purchase_order(uuid,uuid) from public;
revoke all on function public.search_supplier_invoices(uuid,text,text,uuid,uuid,uuid,date,date,integer,integer) from public;
revoke all on function public.get_supplier_invoice_detail(uuid,uuid) from public;
revoke all on function public.search_accounts_payable(uuid,text,uuid,uuid,uuid,text,date,date,integer,integer) from public;
revoke all on function public.list_supplier_invoice_exceptions(uuid,text,integer,integer) from public;
grant execute on function public.save_supplier_invoice(uuid,uuid,uuid,uuid,text,text,text,date,date,text,text,jsonb,uuid,timestamptz) to authenticated;
grant execute on function public.authorize_supplier_invoice_differences(uuid,uuid,text) to authenticated;
grant execute on function public.confirm_supplier_invoice(uuid,uuid,uuid) to authenticated;
grant execute on function public.reverse_supplier_invoice(uuid,uuid,text,uuid) to authenticated;
grant execute on function public.create_supplier_credit_note(uuid,uuid,text,text,text,date,numeric,text,uuid) to authenticated;
grant execute on function public.search_invoiceable_receipts(uuid,text,uuid,uuid,integer,integer) to authenticated;
grant execute on function public.get_invoiceable_purchase_order(uuid,uuid) to authenticated;
grant execute on function public.search_supplier_invoices(uuid,text,text,uuid,uuid,uuid,date,date,integer,integer) to authenticated;
grant execute on function public.get_supplier_invoice_detail(uuid,uuid) to authenticated;
grant execute on function public.search_accounts_payable(uuid,text,uuid,uuid,uuid,text,date,date,integer,integer) to authenticated;
grant execute on function public.list_supplier_invoice_exceptions(uuid,text,integer,integer) to authenticated;
