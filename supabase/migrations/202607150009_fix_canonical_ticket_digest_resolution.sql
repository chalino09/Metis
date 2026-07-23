-- pgcrypto is installed in Supabase's extensions schema. Keep the hardened
-- explicit search path while allowing canonical ticket hashing to resolve.
alter function public.complete_sale(uuid,integer,text,uuid,numeric,uuid)
  set search_path to public,extensions;
