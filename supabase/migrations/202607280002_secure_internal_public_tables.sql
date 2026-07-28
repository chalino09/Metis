-- Satrapy · Cierra tablas internas detectadas por el Security Advisor.
-- Ambas se consumen exclusivamente desde RPC security definer autorizadas;
-- no forman parte del contrato de acceso directo del cliente.

alter table public.receivable_receipt_sequences enable row level security;
revoke all on table public.receivable_receipt_sequences from public, anon, authenticated;

alter table public.collaborator_positions enable row level security;
revoke all on table public.collaborator_positions from public, anon, authenticated;
