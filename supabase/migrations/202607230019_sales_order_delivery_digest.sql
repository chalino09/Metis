-- Allow the delivery transaction to create the immutable ticket hash.
-- Supabase installs pgcrypto in `extensions`; no business data or rules change.

alter function public.deliver_sales_deposit_order(uuid, uuid, uuid, uuid)
  set search_path to public, extensions;
