-- The four-argument overload became ambiguous after priority sorting added a
-- fifth argument with a default. All callers use the current five-argument RPC.
drop function if exists public.list_receivable_customers(uuid,text,integer,integer);

revoke all on function public.list_receivable_customers(uuid,text,integer,integer,text)
  from public,anon;
grant execute on function public.list_receivable_customers(uuid,text,integer,integer,text)
  to authenticated;
