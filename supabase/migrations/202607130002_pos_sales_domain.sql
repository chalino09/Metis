-- Satrapy · Module 2: POS, sales, customers, credit, cash and operational inventory.
-- All monetary values are stored in the company's sale currency and rounded to two
-- decimal places when a commercial document is completed. Alpha remains import-only.

insert into public.permissions (code, description) values
  ('use_pos', 'Operar el punto de venta en ubicaciones autorizadas.'),
  ('view_sales', 'Consultar ventas y tickets de la empresa.'),
  ('sell_cash', 'Completar ventas de contado.'),
  ('sell_credit', 'Completar ventas a crédito dentro del límite autorizado.'),
  ('manage_customers', 'Crear y actualizar clientes.'),
  ('view_customer_credit', 'Consultar saldos y condiciones de crédito.'),
  ('apply_discount', 'Solicitar o aplicar descuentos dentro de su límite.'),
  ('approve_discount', 'Aprobar descuentos que exceden el límite del solicitante.'),
  ('open_cash_session', 'Abrir una sesión de caja.'),
  ('close_own_cash_session', 'Cerrar su propia sesión de caja.'),
  ('approve_cash_variance', 'Aprobar arqueos con diferencia.'),
  ('record_cash_movement', 'Registrar entradas o salidas justificadas de efectivo.'),
  ('view_cash_reports', 'Consultar caja, arqueos y movimientos.'),
  ('record_receivable_payment', 'Registrar abonos simples a cuentas por cobrar.'),
  ('manage_payment_methods', 'Configurar medios de pago.'),
  ('manage_discount_policies', 'Configurar límites de descuento por rol.'),
  ('view_sales_audit', 'Consultar auditoría comercial.')
on conflict (code) do update set description = excluded.description;

insert into public.role_permissions (role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code in (
  'use_pos','view_sales','sell_cash','sell_credit','manage_customers',
  'view_customer_credit','apply_discount','approve_discount','open_cash_session',
  'close_own_cash_session','approve_cash_variance','record_cash_movement',
  'view_cash_reports','record_receivable_payment','manage_payment_methods',
  'manage_discount_policies','view_sales_audit'
)
where role_data.code in ('super_admin', 'direccion_admin')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_id)
select role_data.id, permission_data.id
from public.roles role_data
join public.permissions permission_data on permission_data.code in (
  'use_pos','view_sales','sell_cash','manage_customers','view_customer_credit',
  'apply_discount','open_cash_session','close_own_cash_session','record_cash_movement',
  'view_cash_reports','record_receivable_payment'
)
where role_data.code in ('sucursal', 'punto_venta')
on conflict do nothing;

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null check (length(trim(code)) > 0),
  display_name text not null check (length(trim(display_name)) > 0),
  tax_id text,
  email text,
  phone text,
  price_list_id uuid references public.price_lists(id) on delete set null,
  credit_enabled boolean not null default false,
  credit_limit numeric(18,2) not null default 0 check (credit_limit >= 0),
  credit_term_days integer not null default 0 check (credit_term_days >= 0 and credit_term_days <= 3650),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, code)
);
create unique index customers_company_tax_id_key on public.customers(company_id, lower(tax_id)) where tax_id is not null;
create index customers_search_idx on public.customers using gin (lower(display_name) extensions.gin_trgm_ops);

alter table public.locations add column if not exists default_price_list_id uuid references public.price_lists(id) on delete set null;

create table public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  code text not null check (length(trim(code)) > 0),
  display_name text not null check (length(trim(display_name)) > 0),
  settlement_kind text not null check (settlement_kind in ('cash_drawer', 'external')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, code)
);

create table public.cash_registers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  code text not null check (length(trim(code)) > 0),
  display_name text not null check (length(trim(display_name)) > 0),
  currency_code text not null default 'MXN' check (length(trim(currency_code)) = 3),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, code)
);
create index cash_registers_location_idx on public.cash_registers(location_id) where is_active;

create table public.cash_denominations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  currency_code text not null check (length(trim(currency_code)) = 3),
  value numeric(18,2) not null check (value > 0),
  display_name text not null check (length(trim(display_name)) > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, currency_code, value)
);

create table public.cash_sessions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  cash_register_id uuid not null references public.cash_registers(id) on delete restrict,
  location_id uuid not null references public.locations(id) on delete restrict,
  opened_by uuid not null references auth.users(id) on delete restrict,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  status text not null default 'open' check (status in ('open','pending_variance_approval','closed')),
  opening_amount numeric(18,2) not null default 0 check (opening_amount >= 0),
  expected_closing_amount numeric(18,2),
  counted_closing_amount numeric(18,2),
  variance_amount numeric(18,2),
  close_requested_by uuid references auth.users(id) on delete set null,
  variance_reason text,
  variance_approved_by uuid references auth.users(id) on delete set null,
  variance_approved_at timestamptz,
  open_request_id uuid not null default gen_random_uuid(),
  close_request_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((status = 'open' and closed_at is null) or (status <> 'open' and expected_closing_amount is not null and counted_closing_amount is not null)),
  check ((status <> 'pending_variance_approval') or variance_amount is distinct from 0),
  check ((status <> 'closed' or variance_amount = 0 or variance_approved_by is not null))
);
create unique index cash_sessions_one_open_register_idx on public.cash_sessions(cash_register_id) where status in ('open','pending_variance_approval');
create unique index cash_sessions_open_request_idx on public.cash_sessions(company_id, open_request_id);
create unique index cash_sessions_close_request_idx on public.cash_sessions(company_id, close_request_id) where close_request_id is not null;
create index cash_sessions_location_opened_idx on public.cash_sessions(location_id, opened_at desc);

create table public.cash_counts (
  id uuid primary key default gen_random_uuid(),
  cash_session_id uuid not null references public.cash_sessions(id) on delete restrict,
  count_type text not null check (count_type in ('opening','closing')),
  total_amount numeric(18,2) not null check (total_amount >= 0),
  counted_by uuid not null references auth.users(id) on delete restrict,
  counted_at timestamptz not null default now(),
  unique (cash_session_id, count_type)
);

create table public.cash_count_lines (
  cash_count_id uuid not null references public.cash_counts(id) on delete cascade,
  denomination_id uuid not null references public.cash_denominations(id) on delete restrict,
  denomination_value numeric(18,2) not null check (denomination_value > 0),
  quantity integer not null check (quantity >= 0),
  primary key (cash_count_id, denomination_id)
);

create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  cash_session_id uuid not null references public.cash_sessions(id) on delete restrict,
  movement_type text not null check (movement_type in ('opening','cash_sale','receivable_payment','paid_in','paid_out')),
  amount numeric(18,2) not null check (amount <> 0),
  occurred_at timestamptz not null default now(),
  actor_id uuid not null references auth.users(id) on delete restrict,
  reason text,
  source_entity_type text,
  source_entity_id uuid,
  created_at timestamptz not null default now()
);
create index cash_movements_session_occurred_idx on public.cash_movements(cash_session_id, occurred_at);
create unique index cash_movements_source_unique_idx on public.cash_movements(movement_type, source_entity_type, source_entity_id)
  where source_entity_id is not null;

create table public.discount_role_limits (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete cascade,
  scope text not null check (scope in ('line','sale')),
  max_percent numeric(5,2) not null check (max_percent >= 0 and max_percent <= 100),
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  unique (company_id, role_id, scope, valid_from)
);

create table public.sale_carts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  cash_register_id uuid not null references public.cash_registers(id) on delete restrict,
  cash_session_id uuid not null references public.cash_sessions(id) on delete restrict,
  cashier_id uuid not null references auth.users(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete restrict,
  sale_discount_percent numeric(5,2) not null default 0 check (sale_discount_percent >= 0 and sale_discount_percent <= 100),
  sale_discount_reason text,
  sale_discount_status text not null default 'none' check (sale_discount_status in ('none','approved','pending')),
  sale_discount_approved_by uuid references auth.users(id) on delete set null,
  sale_discount_approved_at timestamptz,
  revision integer not null default 1 check (revision > 0),
  status text not null default 'active' check (status in ('active','converted')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index sale_carts_active_session_cashier_idx on public.sale_carts(cash_session_id, cashier_id) where status = 'active';

create table public.sale_cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.sale_carts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity numeric(18,6) not null check (quantity > 0),
  discount_percent numeric(5,2) not null default 0 check (discount_percent >= 0 and discount_percent <= 100),
  discount_reason text,
  discount_status text not null default 'none' check (discount_status in ('none','approved','pending')),
  discount_approved_by uuid references auth.users(id) on delete set null,
  discount_approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (cart_id, product_id)
);

create table public.discount_approvals (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  cart_id uuid not null references public.sale_carts(id) on delete cascade,
  cart_item_id uuid references public.sale_cart_items(id) on delete cascade,
  scope text not null check (scope in ('line','sale')),
  requested_percent numeric(5,2) not null check (requested_percent > 0 and requested_percent <= 100),
  requester_id uuid not null references auth.users(id) on delete restrict,
  requested_reason text not null check (length(trim(requested_reason)) > 0),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  decision_reason text,
  created_at timestamptz not null default now(),
  check ((scope = 'sale' and cart_item_id is null) or (scope = 'line' and cart_item_id is not null))
);
create unique index discount_approvals_one_pending_idx on public.discount_approvals(cart_id, coalesce(cart_item_id, '00000000-0000-0000-0000-000000000000'::uuid)) where status = 'pending';

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  cash_register_id uuid not null references public.cash_registers(id) on delete restrict,
  cash_session_id uuid not null references public.cash_sessions(id) on delete restrict,
  cashier_id uuid not null references auth.users(id) on delete restrict,
  customer_id uuid references public.customers(id) on delete restrict,
  sale_type text not null check (sale_type in ('cash','credit')),
  status text not null default 'completed' check (status = 'completed'),
  currency_code text not null check (length(trim(currency_code)) = 3),
  subtotal_amount numeric(18,2) not null check (subtotal_amount >= 0),
  discount_amount numeric(18,2) not null check (discount_amount >= 0),
  tax_amount numeric(18,2) not null check (tax_amount >= 0),
  total_amount numeric(18,2) not null check (total_amount >= 0),
  due_date date,
  client_request_id uuid not null,
  completed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (company_id, client_request_id),
  check ((sale_type = 'cash' and due_date is null) or (sale_type = 'credit' and customer_id is not null and due_date is not null))
);
create index sales_company_completed_idx on public.sales(company_id, completed_at desc);
create index sales_location_completed_idx on public.sales(location_id, completed_at desc);
create index sales_customer_completed_idx on public.sales(customer_id, completed_at desc) where customer_id is not null;

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  product_code text not null,
  product_name text not null,
  unit_name text,
  quantity numeric(18,6) not null check (quantity > 0),
  price_list_id uuid references public.price_lists(id) on delete restrict,
  unit_price_amount numeric(18,2) not null check (unit_price_amount >= 0),
  gross_amount numeric(18,2) not null check (gross_amount >= 0),
  discount_percent numeric(5,2) not null check (discount_percent >= 0 and discount_percent <= 100),
  discount_amount numeric(18,2) not null check (discount_amount >= 0),
  taxable_amount numeric(18,2) not null check (taxable_amount >= 0),
  tax_amount numeric(18,2) not null check (tax_amount >= 0),
  total_amount numeric(18,2) not null check (total_amount >= 0),
  created_at timestamptz not null default now()
);
create index sale_items_sale_idx on public.sale_items(sale_id);

create table public.sale_item_taxes (
  id uuid primary key default gen_random_uuid(),
  sale_item_id uuid not null references public.sale_items(id) on delete restrict,
  tax_category_id uuid references public.tax_categories(id) on delete restrict,
  tax_category_code text,
  rate numeric(9,6) not null check (rate >= 0 and rate <= 1),
  tax_amount numeric(18,2) not null check (tax_amount >= 0),
  created_at timestamptz not null default now(),
  unique (sale_item_id, tax_category_code)
);

create table public.sale_payments (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null unique references public.sales(id) on delete restrict,
  payment_method_id uuid not null references public.payment_methods(id) on delete restrict,
  payment_method_code text not null,
  settlement_kind text not null check (settlement_kind in ('cash_drawer','external')),
  received_amount numeric(18,2) not null check (received_amount >= 0),
  change_amount numeric(18,2) not null default 0 check (change_amount >= 0),
  applied_amount numeric(18,2) not null check (applied_amount >= 0),
  created_at timestamptz not null default now()
);

create table public.customer_receivables (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete restrict,
  sale_id uuid not null unique references public.sales(id) on delete restrict,
  issued_at timestamptz not null default now(),
  due_date date not null,
  original_amount numeric(18,2) not null check (original_amount > 0),
  outstanding_amount numeric(18,2) not null check (outstanding_amount >= 0),
  created_at timestamptz not null default now()
);
create index customer_receivables_open_idx on public.customer_receivables(customer_id, due_date, issued_at) where outstanding_amount > 0;

create table public.receivable_payments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete restrict,
  payment_method_id uuid not null references public.payment_methods(id) on delete restrict,
  payment_method_code text not null,
  settlement_kind text not null check (settlement_kind in ('cash_drawer','external')),
  cash_session_id uuid references public.cash_sessions(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  client_request_id uuid not null,
  received_by uuid not null references auth.users(id) on delete restrict,
  received_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (company_id, client_request_id),
  check ((settlement_kind = 'cash_drawer' and cash_session_id is not null) or (settlement_kind = 'external' and cash_session_id is null))
);

create table public.receivable_payment_applications (
  receivable_payment_id uuid not null references public.receivable_payments(id) on delete restrict,
  receivable_id uuid not null references public.customer_receivables(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  created_at timestamptz not null default now(),
  primary key (receivable_payment_id, receivable_id)
);

create table public.inventory_balances (
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity_on_hand numeric(18,6) not null default 0 check (quantity_on_hand >= 0),
  updated_at timestamptz not null default now(),
  primary key (location_id, product_id)
);
create index inventory_balances_company_product_idx on public.inventory_balances(company_id, product_id);

create table public.inventory_ledger (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  quantity_delta numeric(18,6) not null check (quantity_delta <> 0),
  balance_after numeric(18,6) not null check (balance_after >= 0),
  movement_type text not null check (movement_type in ('opening_snapshot','sale','controlled_adjustment')),
  source_snapshot_item_id uuid references public.inventory_snapshot_items(id) on delete restrict,
  sale_item_id uuid references public.sale_items(id) on delete restrict,
  occurred_at timestamptz not null default now(),
  actor_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check ((movement_type = 'opening_snapshot' and source_snapshot_item_id is not null and sale_item_id is null)
    or (movement_type = 'sale' and sale_item_id is not null and source_snapshot_item_id is null)
    or movement_type = 'controlled_adjustment')
);
create unique index inventory_ledger_snapshot_once_idx on public.inventory_ledger(source_snapshot_item_id) where source_snapshot_item_id is not null;
create unique index inventory_ledger_sale_once_idx on public.inventory_ledger(sale_item_id) where sale_item_id is not null;
create index inventory_ledger_balance_idx on public.inventory_ledger(location_id, product_id, occurred_at desc);

create table public.ticket_sequences (
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  next_number bigint not null default 1 check (next_number > 0),
  primary key (company_id, location_id)
);

create table public.canonical_tickets (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null unique references public.sales(id) on delete restrict,
  company_id uuid not null references public.companies(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  folio text not null,
  schema_version integer not null default 1,
  payload jsonb not null,
  content_sha256 text not null,
  issued_at timestamptz not null default now(),
  unique (company_id, location_id, folio)
);

create table public.ticket_print_outbox (
  id uuid primary key default gen_random_uuid(),
  canonical_ticket_id uuid not null unique references public.canonical_tickets(id) on delete restrict,
  event_type text not null default 'ticket.ready' check (event_type = 'ticket.ready'),
  payload_version integer not null,
  deduplication_key text not null unique,
  available_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create or replace function public.assert_pos_company_integrity()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_company_id uuid;
begin
  if tg_table_name = 'customers' and (to_jsonb(new) ->> 'price_list_id') is not null then
    select company_id into v_company_id from public.price_lists where id = (to_jsonb(new) ->> 'price_list_id')::uuid;
    if v_company_id is distinct from new.company_id then raise exception 'La lista de precio del cliente debe pertenecer a su empresa.'; end if;
  elsif tg_table_name = 'locations' and (to_jsonb(new) ->> 'default_price_list_id') is not null then
    select company_id into v_company_id from public.price_lists where id = (to_jsonb(new) ->> 'default_price_list_id')::uuid;
    if v_company_id is distinct from new.company_id then raise exception 'La lista de precio de la ubicación debe pertenecer a su empresa.'; end if;
  elsif tg_table_name = 'cash_registers' then
    select company_id into v_company_id from public.locations where id = new.location_id;
    if v_company_id is distinct from new.company_id then raise exception 'La caja debe pertenecer a la misma empresa que su ubicación.'; end if;
  end if;
  return new;
end $$;

create trigger customers_company_integrity before insert or update on public.customers for each row execute function public.assert_pos_company_integrity();
create trigger locations_price_list_company_integrity before insert or update of default_price_list_id, company_id on public.locations for each row execute function public.assert_pos_company_integrity();
create trigger cash_registers_company_integrity before insert or update on public.cash_registers for each row execute function public.assert_pos_company_integrity();

create or replace function public.prevent_pos_document_mutation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  raise exception 'Los documentos POS confirmados son inmutables.';
end $$;

create trigger sales_immutable before update or delete on public.sales for each row execute function public.prevent_pos_document_mutation();
create trigger sale_items_immutable before update or delete on public.sale_items for each row execute function public.prevent_pos_document_mutation();
create trigger sale_item_taxes_immutable before update or delete on public.sale_item_taxes for each row execute function public.prevent_pos_document_mutation();
create trigger sale_payments_immutable before update or delete on public.sale_payments for each row execute function public.prevent_pos_document_mutation();
create trigger receivable_payments_immutable before update or delete on public.receivable_payments for each row execute function public.prevent_pos_document_mutation();
create trigger receivable_payment_applications_immutable before update or delete on public.receivable_payment_applications for each row execute function public.prevent_pos_document_mutation();
create trigger inventory_ledger_immutable before update or delete on public.inventory_ledger for each row execute function public.prevent_pos_document_mutation();
create trigger cash_movements_immutable before update or delete on public.cash_movements for each row execute function public.prevent_pos_document_mutation();
create trigger canonical_tickets_immutable before update or delete on public.canonical_tickets for each row execute function public.prevent_pos_document_mutation();
create trigger ticket_print_outbox_immutable before update or delete on public.ticket_print_outbox for each row execute function public.prevent_pos_document_mutation();

create or replace function public.prevent_receivable_document_mutation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'El documento por cobrar es inmutable; solo su saldo puede cambiar mediante un abono.';
  end if;
  if new.company_id is distinct from old.company_id
    or new.customer_id is distinct from old.customer_id
    or new.sale_id is distinct from old.sale_id
    or new.issued_at is distinct from old.issued_at
    or new.due_date is distinct from old.due_date
    or new.original_amount is distinct from old.original_amount
    or new.created_at is distinct from old.created_at then
    raise exception 'El documento por cobrar es inmutable; solo su saldo puede cambiar mediante un abono.';
  end if;
  return new;
end $$;
create trigger customer_receivables_document_immutable before update or delete on public.customer_receivables for each row execute function public.prevent_receivable_document_mutation();

create trigger customers_set_updated_at before update on public.customers for each row execute procedure public.set_updated_at();
create trigger payment_methods_set_updated_at before update on public.payment_methods for each row execute procedure public.set_updated_at();
create trigger cash_registers_set_updated_at before update on public.cash_registers for each row execute procedure public.set_updated_at();
create trigger cash_denominations_set_updated_at before update on public.cash_denominations for each row execute procedure public.set_updated_at();
create trigger cash_sessions_set_updated_at before update on public.cash_sessions for each row execute procedure public.set_updated_at();
create trigger discount_role_limits_set_updated_at before update on public.discount_role_limits for each row execute procedure public.set_updated_at();
create trigger sale_carts_set_updated_at before update on public.sale_carts for each row execute procedure public.set_updated_at();
create trigger sale_cart_items_set_updated_at before update on public.sale_cart_items for each row execute procedure public.set_updated_at();

alter table public.customers enable row level security;
alter table public.payment_methods enable row level security;
alter table public.cash_registers enable row level security;
alter table public.cash_denominations enable row level security;
alter table public.cash_sessions enable row level security;
alter table public.cash_counts enable row level security;
alter table public.cash_count_lines enable row level security;
alter table public.cash_movements enable row level security;
alter table public.discount_role_limits enable row level security;
alter table public.sale_carts enable row level security;
alter table public.sale_cart_items enable row level security;
alter table public.discount_approvals enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.sale_item_taxes enable row level security;
alter table public.sale_payments enable row level security;
alter table public.customer_receivables enable row level security;
alter table public.receivable_payments enable row level security;
alter table public.receivable_payment_applications enable row level security;
alter table public.inventory_balances enable row level security;
alter table public.inventory_ledger enable row level security;
alter table public.ticket_sequences enable row level security;
alter table public.canonical_tickets enable row level security;
alter table public.ticket_print_outbox enable row level security;

create policy customers_read on public.customers for select to authenticated using (public.has_company_permission(company_id, 'use_pos') or public.has_company_permission(company_id, 'manage_customers'));
create policy payment_methods_read on public.payment_methods for select to authenticated using (public.has_company_permission(company_id, 'use_pos') or public.has_company_permission(company_id, 'manage_payment_methods'));
create policy cash_registers_read on public.cash_registers for select to authenticated using (public.can_access_location(location_id));
create policy cash_denominations_read on public.cash_denominations for select to authenticated using (public.has_company_permission(company_id, 'use_pos') or public.has_company_permission(company_id, 'view_cash_reports'));
create policy cash_sessions_read on public.cash_sessions for select to authenticated using (public.can_access_location(location_id) and (opened_by = auth.uid() or public.has_company_permission(company_id, 'view_cash_reports')));
create policy cash_counts_read on public.cash_counts for select to authenticated using (exists (select 1 from public.cash_sessions s where s.id = cash_session_id and public.can_access_location(s.location_id) and (s.opened_by = auth.uid() or public.has_company_permission(s.company_id, 'view_cash_reports'))));
create policy cash_count_lines_read on public.cash_count_lines for select to authenticated using (exists (select 1 from public.cash_counts c join public.cash_sessions s on s.id = c.cash_session_id where c.id = cash_count_id and public.can_access_location(s.location_id) and (s.opened_by = auth.uid() or public.has_company_permission(s.company_id, 'view_cash_reports'))));
create policy cash_movements_read on public.cash_movements for select to authenticated using (public.can_access_location((select s.location_id from public.cash_sessions s where s.id = cash_session_id)) and public.has_company_permission(company_id, 'view_cash_reports'));
create policy discount_role_limits_read on public.discount_role_limits for select to authenticated using (public.has_company_permission(company_id, 'use_pos') or public.has_company_permission(company_id, 'manage_discount_policies'));
create policy carts_read on public.sale_carts for select to authenticated using (cashier_id = auth.uid() or public.has_company_permission(company_id, 'view_sales'));
create policy cart_items_read on public.sale_cart_items for select to authenticated using (exists (select 1 from public.sale_carts c where c.id = cart_id and (c.cashier_id = auth.uid() or public.has_company_permission(c.company_id, 'view_sales'))));
create policy discount_approvals_read on public.discount_approvals for select to authenticated using (requester_id = auth.uid() or public.has_company_permission(company_id, 'approve_discount'));
create policy sales_read on public.sales for select to authenticated using (public.can_access_location(location_id) and public.has_company_permission(company_id, 'view_sales'));
create policy sale_items_read on public.sale_items for select to authenticated using (exists (select 1 from public.sales s where s.id = sale_id and public.can_access_location(s.location_id) and public.has_company_permission(s.company_id, 'view_sales')));
create policy sale_item_taxes_read on public.sale_item_taxes for select to authenticated using (exists (select 1 from public.sale_items i join public.sales s on s.id = i.sale_id where i.id = sale_item_id and public.can_access_location(s.location_id) and public.has_company_permission(s.company_id, 'view_sales')));
create policy sale_payments_read on public.sale_payments for select to authenticated using (exists (select 1 from public.sales s where s.id = sale_id and public.can_access_location(s.location_id) and public.has_company_permission(s.company_id, 'view_sales')));
create policy receivables_read on public.customer_receivables for select to authenticated using (public.has_company_permission(company_id, 'view_customer_credit'));
create policy receivable_payments_read on public.receivable_payments for select to authenticated using (public.has_company_permission(company_id, 'view_customer_credit'));
create policy receivable_payment_applications_read on public.receivable_payment_applications for select to authenticated using (exists (select 1 from public.receivable_payments p where p.id = receivable_payment_id and public.has_company_permission(p.company_id, 'view_customer_credit')));
create policy inventory_balances_read on public.inventory_balances for select to authenticated using (public.can_access_location(location_id));
create policy inventory_ledger_read on public.inventory_ledger for select to authenticated using (public.can_access_location(location_id) and public.has_company_permission(company_id, 'view_sales'));
create policy canonical_tickets_read on public.canonical_tickets for select to authenticated using (exists (select 1 from public.sales s where s.id = sale_id and public.can_access_location(s.location_id) and public.has_company_permission(s.company_id, 'view_sales')));

drop policy if exists audit_read on public.audit_log;
drop policy if exists audit_write on public.audit_log;
create policy audit_read on public.audit_log for select to authenticated using (public.has_company_permission(company_id, 'view_import_audit') or public.has_company_permission(company_id, 'view_sales_audit'));
create policy audit_write on public.audit_log for insert to authenticated with check (public.has_company_permission(company_id, 'import_data') or public.has_company_permission(company_id, 'view_sales_audit'));

-- Direct mutations are intentionally absent. RPCs in the next migration own all
-- multi-table state transitions, including customer management.
grant select on public.customers, public.payment_methods, public.cash_registers, public.cash_denominations,
  public.cash_sessions, public.cash_counts, public.cash_count_lines, public.cash_movements,
  public.discount_role_limits, public.sale_carts, public.sale_cart_items, public.discount_approvals,
  public.sales, public.sale_items, public.sale_item_taxes, public.sale_payments,
  public.customer_receivables, public.receivable_payments, public.receivable_payment_applications,
  public.inventory_balances, public.inventory_ledger, public.canonical_tickets to authenticated;

revoke all on public.customers, public.payment_methods, public.cash_registers, public.cash_denominations,
  public.cash_sessions, public.cash_counts, public.cash_count_lines, public.cash_movements,
  public.discount_role_limits, public.sale_carts, public.sale_cart_items, public.discount_approvals,
  public.sales, public.sale_items, public.sale_item_taxes, public.sale_payments,
  public.customer_receivables, public.receivable_payments, public.receivable_payment_applications,
  public.inventory_balances, public.inventory_ledger, public.ticket_sequences, public.canonical_tickets,
  public.ticket_print_outbox from authenticated;
grant select on public.customers, public.payment_methods, public.cash_registers, public.cash_denominations,
  public.cash_sessions, public.cash_counts, public.cash_count_lines, public.cash_movements,
  public.discount_role_limits, public.sale_carts, public.sale_cart_items, public.discount_approvals,
  public.sales, public.sale_items, public.sale_item_taxes, public.sale_payments,
  public.customer_receivables, public.receivable_payments, public.receivable_payment_applications,
  public.inventory_balances, public.inventory_ledger, public.canonical_tickets to authenticated;
